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
      rescue ex : File::NotFoundError
        raise CLINotFoundError.new("Claude Code CLI not found at '#{cli_path}'", cli_path)
      end
    end

    private def build_env : Hash(String, String)?
      base_env = @options.try(&.env) || {} of String => String
      # Set SDK entrypoint identifier (matches official SDK behavior)
      base_env["CLAUDE_CODE_ENTRYPOINT"] = "sdk-cr"

      # Max thinking tokens is set via environment variable
      # See: https://github.com/anthropics/claude-code/issues/5257
      if max_thinking = @options.try(&.max_thinking_tokens)
        base_env["MAX_THINKING_TOKENS"] = max_thinking.to_s
      end

      # User identifier for tracking (Python SDK feature)
      if user = @options.try(&.user)
        base_env["CLAUDE_CODE_USER"] = user
      end

      base_env
    end

    def stop
      return unless @running

      @input.try(&.close)
      @process.try(&.wait)
      @running = false
    end

    def send_prompt(prompt : String, parent_tool_use_id : String? = nil)
      message = Hash(String, String | Hash(String, String) | Nil).new
      message["type"] = "user"
      message["message"] = {"role" => "user", "content" => prompt}
      message["parent_tool_use_id"] = parent_tool_use_id

      send_json(message)
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

      args << "--permission-mode" << permission_mode_value(opts.permission_mode)
      args << "--allow-dangerously-skip-permissions" if opts.allow_dangerously_skip_permissions?

      add_system_prompt_args(args, opts)

      opts.max_budget_usd.try { |budget| args << "--max-budget-usd" << budget.to_s }
      opts.betas.try { |betas| args << "--betas" << betas.join(" ") }
    end

    private def add_system_prompt_args(args : Array(String), opts : AgentOptions)
      case system_prompt = opts.system_prompt
      when String
        args << "--system-prompt" << system_prompt
      when SystemPromptPreset
        args << "--system-prompt" << system_prompt.preset
        system_prompt.append.try { |append| args << "--append-system-prompt" << append }
      end

      opts.append_system_prompt.try { |append| args << "--append-system-prompt" << append }
    end

    private def permission_mode_value(mode : PermissionMode) : String
      case mode
      when PermissionMode::Default           then "default"
      when PermissionMode::AcceptEdits       then "acceptEdits"
      when PermissionMode::Plan              then "plan"
      when PermissionMode::BypassPermissions then "bypassPermissions"
      else                                        "default"
      end
    end

    private def add_tool_args(args : Array(String), opts : AgentOptions)
      opts.allowed_tools.try { |tools| args << "--allowedTools" << tools.join(" ") }
      opts.disallowed_tools.try { |tools| args << "--disallowedTools" << tools.join(" ") }

      add_tools_option_args(args, opts)

      opts.add_dirs.try(&.each { |dir| args << "--add-dir" << dir })
      opts.plugins.try(&.each { |plugin| args << "--plugin-dir" << plugin })

      add_mcp_args(args, opts)

      args << "--strict-mcp-config" if opts.strict_mcp_config?

      opts.agents.try { |agents| args << "--agents" << build_agents_json(agents) }
      opts.agent.try { |agent| args << "--agent" << agent }
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
        defn.model.try { |model| agent_obj["model"] = JSON::Any.new(model) }
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
      args << "--fork-session" if opts.fork_session?
      opts.session_id.try { |id| args << "--session-id" << id }

      # Disable session persistence
      args << "--no-session-persistence" if opts.no_session_persistence?
    end

    private def add_session_settings_args(args : Array(String), opts : AgentOptions)
      # --setting-sources takes comma-separated values
      opts.setting_sources.try { |sources| args << "--setting-sources" << sources.join(",") }

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
