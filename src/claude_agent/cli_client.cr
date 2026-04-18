require "json"
require "./types/messages"
require "./types/options"
require "./errors"

module ClaudeAgent
  class CLIClient
    @process : Process?
    @input : IO?
    @output : IO?
    @error : IO?
    @running : Bool = false
    @session_id : String?
    @sdk_mcp_servers : Hash(String, SDKMCPServer)

    def initialize(@options : AgentOptions? = nil)
      @sdk_mcp_servers = extract_sdk_servers
    end

    # Get SDK MCP server by name (for routing control requests)
    def get_sdk_server(name : String) : SDKMCPServer?
      @sdk_mcp_servers[name]?
    end

    # Get all SDK MCP server names
    def sdk_server_names : Array(String)
      @sdk_mcp_servers.keys
    end

    # Check if there are any SDK MCP servers configured
    def has_sdk_servers? : Bool
      !@sdk_mcp_servers.empty?
    end

    private def extract_sdk_servers : Hash(String, SDKMCPServer)
      servers = {} of String => SDKMCPServer
      mcp_servers = @options.try(&.mcp_servers)
      return servers unless mcp_servers

      mcp_servers.each do |name, config|
        if config.is_a?(SDKMCPServer)
          servers[name] = config
        end
      end

      servers
    end

    def session_id : String?
      @session_id
    end

    def start
      return if @running

      cli_path = find_cli_path
      args = build_cli_args

      cwd = @options.try(&.cwd)
      env = build_env

      begin
        process = Process.new(
          command: cli_path,
          args: args,
          env: env,
          input: Process::Redirect::Pipe,
          output: Process::Redirect::Pipe,
          error: Process::Redirect::Pipe,
          chdir: cwd
        )
        @process = process

        @input = process.input
        @output = process.output
        @error = process.error
        @running = true
        start_stderr_drain
      rescue ex : File::NotFoundError
        raise CLINotFoundError.new("Claude Code CLI not found at '#{cli_path}'", cli_path)
      end
    end

    private def build_env : Hash(String, String)?
      base_env = @options.try(&.env).try(&.dup) || {} of String => String

      # SDK entrypoint identifier used by Claude Code to distinguish clients.
      base_env["CLAUDE_CODE_ENTRYPOINT"] = "sdk-cr"

      if @options.try(&.include_partial_messages?)
        base_env["CLAUDE_CODE_ENABLE_FINE_GRAINED_TOOL_STREAMING"] = "1"
      end

      # User identifier for tracking
      if user = @options.try(&.user)
        base_env["CLAUDE_CODE_USER"] = user
      end

      # Propagate W3C trace context to the subprocess when the caller has
      # already populated it in their environment, so CLI spans parent
      # under the caller's distributed trace. Explicit values in
      # options.env always win.
      %w[TRACEPARENT TRACESTATE].each do |key|
        next if base_env.has_key?(key)
        if value = ENV[key]?
          base_env[key] = value
        end
      end

      base_env
    end

    def stop
      return unless @running

      @input.try(&.close)
      @process.try(&.wait)
      @running = false
    end

    # Send a user prompt. When `should_query` is false the message is
    # appended to the transcript without triggering an assistant turn.
    def send_prompt(
      prompt : String,
      parent_tool_use_id : String? = nil,
      *,
      uuid : String? = nil,
      should_query : Bool = true,
    )
      message = Hash(String, String | Hash(String, String) | Bool | Nil).new
      message["type"] = "user"
      message["message"] = {"role" => "user", "content" => prompt}
      message["parent_tool_use_id"] = parent_tool_use_id if parent_tool_use_id
      message["uuid"] = uuid if uuid
      message["should_query"] = false unless should_query

      send_json(message)
    end

    def send_user_message(
      content : String,
      parent_tool_use_id : String? = nil,
      *,
      uuid : String? = nil,
      should_query : Bool = true,
    )
      send_prompt(content, parent_tool_use_id, uuid: uuid, should_query: should_query)
    end

    def send_json(message)
      @input.try do |input|
        input.puts(message.to_json)
        input.flush
      end
    rescue ex : IO::Error
      raise ConnectionError.new("Failed to send message to CLI: #{ex.message}")
    end

    def send_message(message : Hash)
      @input.try do |input|
        input.puts(message.to_json)
        input.flush
      end
    rescue ex : IO::Error
      raise ConnectionError.new("Failed to send message to CLI: #{ex.message}")
    end

    # Send a control response back to the CLI
    def send_control_response(response : ControlResponse)
      send_json({"type" => response.type, "response" => response.response})
    end

    # Send SDK MCP server initialization to CLI
    # This registers the SDK servers with the CLI so it knows to route
    # tool calls back to the SDK via control_request messages
    def send_sdk_init
      return unless has_sdk_servers?

      # Build initialization request
      init_request = {
        "type"    => "control_request",
        "request" => {
          "subtype"       => "initialize",
          "sdkMcpServers" => sdk_server_names,
        },
      }
      send_json(init_request)
    end

    def each_message(&)
      @output.try do |output|
        output.each_line do |line|
          next if line.strip.empty?

          begin
            message = Message.parse(line)

            # Capture session_id from messages
            case message
            when SystemMessage
              @session_id = message.session_id
            when AssistantMessage
              @session_id ||= message.session_id
            when ResultMessage
              @session_id ||= message.session_id
            end

            yield message
          rescue ex : JSON::ParseException
            STDERR.puts "[CLI JSON Error] #{ex.message}"
          rescue ex : Exception
            STDERR.puts "[CLI Error] #{ex.message}"
          end
        end
      end
    end

    private def start_stderr_drain
      stderr = @error
      return unless stderr

      stderr_callback = @options.try(&.stderr)

      spawn do
        begin
          stderr.each_line do |line|
            if cb = stderr_callback
              cb.call(line)
            end
          end
        rescue IO::Error
        end
      end
    end

    private def find_cli_path : String
      @options.try(&.cli_path) || "claude"
    end

    private def build_cli_args : Array(String)
      # Flag order matters! --verbose must come before --output-format
      # See: https://github.com/anthropics/claude-agent-sdk-typescript/issues/60
      args = ["--verbose", "--print", "--output-format", "stream-json", "--input-format", "stream-json"]

      if opts = @options
        add_core_args(args, opts)
        add_tool_args(args, opts)
        add_session_args(args, opts)
      end

      args
    end

    private def add_core_args(args : Array(String), opts : AgentOptions)
      opts.model.try { |model| args << "--model" << model }
      opts.fallback_model.try { |model| args << "--fallback-model" << model }

      args << "--permission-mode" << opts.permission_mode.to_cli_value
      args << "--allow-dangerously-skip-permissions" if opts.allow_dangerously_skip_permissions?

      add_system_prompt_args(args, opts)
      add_thinking_args(args, opts)

      opts.max_turns.try { |turns| args << "--max-turns" << turns.to_s }
      opts.max_budget_usd.try { |budget| args << "--max-budget-usd" << budget.to_s }
      opts.task_budget.try { |budget| args << "--task-budget" << budget.total.to_s }
      opts.title.try { |title| args << "--title" << title }
      opts.betas.try { |betas| args << "--betas" << betas.join(" ") }
    end

    private def add_system_prompt_args(args : Array(String), opts : AgentOptions)
      case system_prompt = opts.system_prompt
      when String
        args << "--system-prompt" << system_prompt
      when SystemPromptPreset
        # Preset is implicit when only append/exclude_dynamic_sections are set;
        # only the `append` portion is a direct CLI arg.
        system_prompt.append.try { |append| args << "--append-system-prompt" << append }
        args << "--exclude-dynamic-sections" if system_prompt.exclude_dynamic_sections?
      when SystemPromptFile
        args << "--system-prompt-file" << system_prompt.path
      end

      opts.append_system_prompt.try { |append| args << "--append-system-prompt" << append }
    end

    # Delegated to PermissionMode#to_cli_value for shared use
    private def permission_mode_value(mode : PermissionMode) : String
      mode.to_cli_value
    end

    private def effort_value(effort : Effort) : String
      case effort
      when Effort::Low    then "low"
      when Effort::Medium then "medium"
      when Effort::High   then "high"
      when Effort::Xhigh  then "xhigh"
      when Effort::Max    then "max"
      else                     "medium"
      end
    end

    # `thinking` takes precedence over the deprecated `max_thinking_tokens`.
    # Adaptive/disabled modes emit `--thinking <mode>`; enabled mode emits
    # `--max-thinking-tokens <budget>`.
    private def add_thinking_args(args : Array(String), opts : AgentOptions)
      if thinking = opts.thinking
        case thinking
        when ThinkingConfigAdaptive
          args << "--thinking" << "adaptive"
        when ThinkingConfigEnabled
          args << "--max-thinking-tokens" << thinking.budget_tokens.to_s
        when ThinkingConfigDisabled
          args << "--thinking" << "disabled"
        end
      elsif tokens = opts.max_thinking_tokens
        args << "--max-thinking-tokens" << tokens.to_s
      end

      opts.effort.try do |effort|
        args << "--effort" << effort_value(effort)
      end
    end

    private def add_tool_args(args : Array(String), opts : AgentOptions)
      effective_allowed, _ = apply_skills_defaults(opts)
      args << "--allowedTools" << effective_allowed.join(" ") unless effective_allowed.empty?
      opts.disallowed_tools.try { |tools| args << "--disallowedTools" << tools.join(" ") }

      add_tools_option_args(args, opts)

      opts.add_dirs.try(&.each { |dir| args << "--add-dir" << dir })
      opts.plugins.try(&.each { |plugin| args << "--plugin-dir" << plugin })

      add_mcp_args(args, opts)

      args << "--strict-mcp-config" if opts.strict_mcp_config?

      opts.agents.try { |agents| args << "--agents" << build_agents_json(agents) }
      opts.agent.try { |agent| args << "--agent" << agent }
    end

    # Compute effective allowed_tools/setting_sources from `skills`.
    # Injects `Skill` or `Skill(name)` entries into allowed_tools and defaults
    # setting_sources to ["user","project"] when unset. Returns copies; does
    # not mutate `opts`.
    protected def apply_skills_defaults(opts : AgentOptions) : {Array(String), Array(String)?}
      allowed = opts.allowed_tools.try(&.dup) || [] of String
      sources = opts.setting_sources.try(&.dup)

      case skills = opts.skills
      when Nil
        # No-op. CLI defaults still apply.
      when String
        if skills == "all"
          allowed << "Skill" unless allowed.includes?("Skill")
          sources ||= ["user", "project"]
        end
      when Array(String)
        skills.each do |name|
          pattern = "Skill(#{name})"
          allowed << pattern unless allowed.includes?(pattern)
        end
        sources ||= ["user", "project"]
      end

      {allowed, sources}
    end

    private def add_tools_option_args(args : Array(String), opts : AgentOptions)
      case tools = opts.tools
      when Array(String)
        args << "--tools" << tools.join(",")
      when ToolsPreset
        args << "--tools" << tools.preset
      end
    end

    private def add_mcp_args(args : Array(String), opts : AgentOptions)
      mcp_servers = opts.mcp_servers
      return unless mcp_servers

      mcp_json = build_mcp_servers_json(mcp_servers)
      args << "--mcp-config" << mcp_json unless mcp_json.empty?
    end

    private def build_agents_json(agents : Hash(String, AgentDefinition)) : String
      result = {} of String => JSON::Any
      agents.each do |name, defn|
        agent_obj = {} of String => JSON::Any
        agent_obj["description"] = JSON::Any.new(defn.description)
        agent_obj["prompt"] = JSON::Any.new(defn.prompt)
        defn.tools.try { |tools| agent_obj["tools"] = JSON::Any.new(tools.map { |tool| JSON::Any.new(tool) }) }
        defn.disallowed_tools.try do |tools|
          agent_obj["disallowedTools"] = JSON::Any.new(tools.map { |tool| JSON::Any.new(tool) })
        end
        defn.model.try { |model| agent_obj["model"] = JSON::Any.new(model) }
        defn.skills.try do |skills|
          agent_obj["skills"] = JSON::Any.new(skills.map { |skill| JSON::Any.new(skill) })
        end
        defn.memory.try { |memory| agent_obj["memory"] = JSON::Any.new(memory) }
        defn.mcp_servers.try { |servers| agent_obj["mcpServers"] = JSON::Any.new(servers) }
        defn.initial_prompt.try { |prompt| agent_obj["initialPrompt"] = JSON::Any.new(prompt) }
        defn.max_turns.try { |turns| agent_obj["maxTurns"] = JSON::Any.new(turns.to_i64) }
        defn.background?.try { |background| agent_obj["background"] = JSON::Any.new(background) }
        defn.effort.try { |effort| agent_obj["effort"] = effort }
        defn.permission_mode.try { |mode| agent_obj["permissionMode"] = JSON::Any.new(mode) }
        result[name] = JSON::Any.new(agent_obj)
      end
      result.to_json
    end

    private def build_mcp_servers_json(servers : Hash(String, MCPServerConfig)) : String
      mcp_servers = {} of String => JSON::Any

      servers.each do |name, config|
        server_config = build_server_config(config)
        next unless server_config
        mcp_servers[name] = JSON::Any.new(server_config)
      end

      return "" if mcp_servers.empty?

      # Wrap in {"mcpServers": {...}} format required by CLI
      {"mcpServers" => JSON::Any.new(mcp_servers)}.to_json
    end

    private def build_server_config(config : MCPServerConfig) : Hash(String, JSON::Any)?
      case config
      when ExternalMCPServerConfig
        server_config = {} of String => JSON::Any

        config.type.try { |v| server_config["type"] = JSON::Any.new(v) }
        config.command.try { |v| server_config["command"] = JSON::Any.new(v) }
        config.args.try { |v| server_config["args"] = JSON::Any.new(v.map { |arg| JSON::Any.new(arg) }) }
        config.url.try { |v| server_config["url"] = JSON::Any.new(v) }

        if env = config.env
          env_any = {} of String => JSON::Any
          env.each { |k, v| env_any[k] = JSON::Any.new(v) }
          server_config["env"] = JSON::Any.new(env_any)
        end

        if headers = config.headers
          headers_any = {} of String => JSON::Any
          headers.each { |k, v| headers_any[k] = JSON::Any.new(v) }
          server_config["headers"] = JSON::Any.new(headers_any)
        end

        server_config
      when SDKMCPServer
        # SDK MCP servers are handled differently (in-process)
        nil
      else
        nil
      end
    end

    private def add_session_args(args : Array(String), opts : AgentOptions)
      add_session_resume_args(args, opts)
      add_session_settings_args(args, opts)
      add_session_streaming_args(args, opts)
    end

    private def add_session_resume_args(args : Array(String), opts : AgentOptions)
      # --continue to continue most recent conversation
      args << "--continue" if opts.continue_conversation?

      # --resume takes a session ID, not just a flag
      opts.resume.try { |id| args << "--resume" << id }
      opts.resume_session_at.try { |uuid| args << "--resume-session-at" << uuid }
      args << "--fork-session" if opts.fork_session?
      opts.session_id.try { |id| args << "--session-id" << id }

      # Disable session persistence
      args << "--no-session-persistence" if opts.no_session_persistence?
    end

    private def add_session_settings_args(args : Array(String), opts : AgentOptions)
      # --setting-sources takes comma-separated values. An empty array disables
      # all filesystem settings; it must be passed as a single `--setting-sources=`
      # token so the CLI does not consume the next flag as its value.
      _, effective_sources = apply_skills_defaults(opts)
      effective_sources.try do |sources|
        if sources.empty?
          args << "--setting-sources="
        else
          args << "--setting-sources" << sources.join(",")
        end
      end

      # --settings takes a path or JSON string
      # If sandbox settings are provided without a settings_path, serialize them
      settings_json = build_settings_json(opts)
      if settings_json
        args << "--settings" << settings_json
      elsif path = opts.settings_path
        args << "--settings" << path
      end
    end

    private def build_settings_json(opts : AgentOptions) : String?
      sandbox = opts.sandbox
      return nil unless sandbox

      settings = {} of String => JSON::Any

      # Build sandbox settings object
      sandbox_obj = {} of String => JSON::Any
      sandbox_obj["enabled"] = JSON::Any.new(sandbox.enabled?) if sandbox.enabled?
      sandbox_obj["autoAllowBashIfSandboxed"] = JSON::Any.new(sandbox.auto_allow_bash_if_sandboxed?) if sandbox.auto_allow_bash_if_sandboxed?
      sandbox_obj["allowUnsandboxedCommands"] = JSON::Any.new(sandbox.allow_unsandboxed_commands?) if sandbox.allow_unsandboxed_commands?
      sandbox_obj["enableWeakerNestedSandbox"] = JSON::Any.new(sandbox.enable_weaker_nested_sandbox?) if sandbox.enable_weaker_nested_sandbox?

      sandbox.excluded_commands.try do |cmds|
        sandbox_obj["excludedCommands"] = JSON::Any.new(cmds.map { |cmd| JSON::Any.new(cmd) })
      end

      sandbox.network.try do |net|
        net_obj = {} of String => JSON::Any
        net_obj["allowLocalBinding"] = JSON::Any.new(net.allow_local_binding?) if net.allow_local_binding?
        net_obj["allowAllUnixSockets"] = JSON::Any.new(net.allow_all_unix_sockets?) if net.allow_all_unix_sockets?
        net.allow_unix_sockets.try { |sockets| net_obj["allowUnixSockets"] = JSON::Any.new(sockets.map { |sock| JSON::Any.new(sock) }) }
        net.http_proxy_port.try { |port| net_obj["httpProxyPort"] = JSON::Any.new(port.to_i64) }
        net.socks_proxy_port.try { |port| net_obj["socksProxyPort"] = JSON::Any.new(port.to_i64) }
        sandbox_obj["network"] = JSON::Any.new(net_obj) unless net_obj.empty?
      end

      sandbox.ignore_violations.try do |ignore|
        ignore_obj = {} of String => JSON::Any
        ignore.file.try { |files| ignore_obj["file"] = JSON::Any.new(files.map { |path| JSON::Any.new(path) }) }
        ignore.network.try { |networks| ignore_obj["network"] = JSON::Any.new(networks.map { |pattern| JSON::Any.new(pattern) }) }
        sandbox_obj["ignoreViolations"] = JSON::Any.new(ignore_obj) unless ignore_obj.empty?
      end

      settings["sandbox"] = JSON::Any.new(sandbox_obj) unless sandbox_obj.empty?

      return nil if settings.empty?
      settings.to_json
    end

    private def add_session_streaming_args(args : Array(String), opts : AgentOptions)
      # Streaming options
      args << "--include-partial-messages" if opts.include_partial_messages?
      args << "--replay-user-messages" if opts.replay_user_messages?
      args << "--enable-file-checkpointing" if opts.enable_file_checkpointing?
      opts.permission_prompt_tool_name.try { |name| args << "--permission-prompt-tool-name" << name }

      # Structured output via JSON schema
      add_output_format_args(args, opts)
    end

    private def add_output_format_args(args : Array(String), opts : AgentOptions)
      output_format = opts.output_format
      return unless output_format && output_format.type == "json_schema"

      output_format.schema.try do |schema|
        # Build schema with optional name (title) and description
        final_schema = schema.dup
        output_format.name.try { |name| final_schema["title"] = JSON::Any.new(name) }
        output_format.description.try { |desc| final_schema["description"] = JSON::Any.new(desc) }
        args << "--json-schema" << final_schema.to_json
      end
    end
  end
end
