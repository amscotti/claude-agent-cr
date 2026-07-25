require "json"
require "./types/messages"
require "./types/options"
require "./errors"

module ClaudeAgent
  class CLIClient
    # Forward-compatible option flags that the SDK may append but that older
    # Claude Code CLI releases do not understand. When a capability probe
    # confirms the CLI advertises none of these, they are silently stripped
    # from argv so the subprocess does not abort with
    # `error: unknown option '--<flag>'` before the handshake. Core flags
    # (e.g., `--model`, `--output-format`) are never filtered.
    OPTIONAL_CLI_FLAGS = [
      "--task-budget",
      "--thinking",
      "--system-prompt-file",
    ]

    # Cache of parsed `claude --help` flag sets keyed by resolved cli_path,
    # so repeated client starts (common in long-running applications) only
    # probe once per binary.
    @@capability_cache = {} of String => Set(String)
    @@capability_mutex = Mutex.new

    # Test-only: clear the capability cache so a spec can inject its own
    # probe result or re-exercise the probe path.
    def self.clear_capability_cache : Nil
      @@capability_mutex.synchronize { @@capability_cache.clear }
    end

    # Test-only: seed the cache with a known set of supported flags for a
    # given cli_path so specs can exercise the argv filter without spawning
    # a real subprocess.
    def self.seed_capability_cache(cli_path : String, flags : Enumerable(String)) : Nil
      @@capability_mutex.synchronize { @@capability_cache[cli_path] = flags.to_set }
    end

    @process : Process?
    @input : IO?
    @output : IO?
    @error : IO?
    @running : Bool = false
    @session_id : String?
    @sdk_mcp_servers : Hash(String, SDKMCPServer)
    @stderr_tail : Array(String) = [] of String
    @stderr_mutex : Mutex = Mutex.new

    def initialize(@options : AgentOptions? = nil)
      @sdk_mcp_servers = extract_sdk_servers
    end

    # Replace options after construction (e.g. session_store resume
    # materialization rewrites env/resume). AgentOptions is a struct, so
    # callers must push the updated copy here before `#start`.
    def replace_options(options : AgentOptions?) : Nil
      @options = options
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

      # Advisory only: emit once per connect when can_use_tool is shadowed
      # by whole-tool allowed_tools entries or bypassPermissions.
      emit_can_use_tool_shadowed_warning

      cli_path = find_cli_path
      args = build_cli_args

      # Reset the rolling stderr tail so `detect_unknown_option_error`
      # never surfaces a diagnostic from a previous session.
      @stderr_mutex.synchronize { @stderr_tail.clear }

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
      rescue File::NotFoundError
        raise CLINotFoundError.new("Claude Code CLI not found at '#{cli_path}'", cli_path)
      end
    end

    # Emit CanUseToolShadowedWarning via the caller-supplied stderr callback
    # (or STDERR) when options shadow `can_use_tool`. Non-fatal.
    private def emit_can_use_tool_shadowed_warning : Nil
      message = @options.try(&.can_use_tool_shadowed_warning)
      return unless message

      log_message("[claude-agent-cr] #{message}\n")
    end

    private def build_env : Hash(String, String)?
      # options.env overlays onto the parent process environment (Process.new
      # merges when clear_env is false). We start from a copy of options.env
      # so callers can inject/override vars without mutating their hash.
      base_env = @options.try(&.env).try(&.dup) || {} of String => String

      # SDK entrypoint identifier used by Claude Code to distinguish clients.
      base_env["CLAUDE_CODE_ENTRYPOINT"] = "sdk-cr"

      # Always stamp the SDK version for User-Agent / telemetry unless the
      # caller already set it in options.env. Matches the TS SDK: the version
      # is never dropped when a custom env map is supplied.
      unless base_env.has_key?("CLAUDE_AGENT_SDK_VERSION")
        base_env["CLAUDE_AGENT_SDK_VERSION"] = VERSION
      end

      if @options.try(&.include_partial_messages?)
        base_env["CLAUDE_CODE_ENABLE_FINE_GRAINED_TOOL_STREAMING"] = "1"
      end

      if @options.try(&.enable_file_checkpointing?)
        base_env["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] = "true"
      end

      # AskUserQuestion preview format (TS toolConfig.askUserQuestion.previewFormat).
      # The CLI reads this via CLAUDE_CODE_QUESTION_PREVIEW_FORMAT, not settings.
      if format = @options.try(&.tool_config).try(&.ask_user_question).try(&.preview_format)
        base_env["CLAUDE_CODE_QUESTION_PREVIEW_FORMAT"] = format
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

    # Stop the CLI subprocess with a three-stage cascade:
    #   1. Close stdin so a well-behaved CLI sees EOF and exits.
    #   2. Wait up to 5 seconds for graceful exit.
    #   3. Send SIGTERM; wait another 5 seconds.
    #   4. SIGKILL as a last resort.
    # A subprocess that's alive but unresponsive (stuck MCP handler,
    # deadlocked writer) used to hang `stop` forever. Each stage has a
    # bounded wait, so `stop` always returns within ~10 seconds.
    def stop
      return unless @running
      @running = false

      @input.try(&.close)

      if process = @process
        unless wait_for_exit(process, 5.seconds)
          begin
            process.terminate
          rescue IO::Error
          rescue RuntimeError
          end

          unless wait_for_exit(process, 5.seconds)
            begin
              process.terminate(graceful: false)
            rescue IO::Error
            rescue RuntimeError
            end
            wait_for_exit(process, 2.seconds)
          end
        end
      end

      @error.try(&.close) rescue nil
      @output.try(&.close) rescue nil
    end

    # Block up to `span` seconds waiting for the process to exit.
    # Returns true if it exited, false on timeout.
    private def wait_for_exit(process : Process, span : Time::Span) : Bool
      done = Channel(Bool).new(1)
      spawn do
        process.wait
        done.send(true)
      rescue
        done.send(false)
      end

      select
      when outcome = done.receive
        outcome
      when timeout(span)
        false
      end
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
      message = Hash(String, String | Hash(String, String) | Bool?).new
      message["type"] = "user"
      message["message"] = {"role" => "user", "content" => prompt}
      message["parent_tool_use_id"] = parent_tool_use_id if parent_tool_use_id
      message["uuid"] = uuid if uuid
      # Wire name is camelCase per the stream-json contract (matches the
      # TypeScript SDK's `SDKUserMessage.shouldQuery` field).
      message["shouldQuery"] = false unless should_query

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
            # Log the offending line (truncated) so users can debug
            # malformed output without digging through stderr manually.
            truncated = line.size > 500 ? "#{line[0, 500]}…" : line
            decode_error = JSONDecodeError.new(
              "Failed to parse CLI stream-json line: #{ex.message}",
              truncated,
            )
            log_message("[claude-agent-cr] #{decode_error.message}\n  raw: #{decode_error.raw_data}\n")
          rescue ex : Exception
            log_message("[claude-agent-cr] CLI message handling error: #{ex.class}: #{ex.message}\n")
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
            @stderr_mutex.synchronize do
              @stderr_tail << line
              # Keep a bounded tail (~512 lines) so we can surface
              # "unknown option" errors in `stop` without holding onto
              # arbitrarily large output.
              while @stderr_tail.size > 512
                @stderr_tail.shift
              end
            end
            if cb = stderr_callback
              cb.call(line)
            end
          end
        rescue IO::Error
        end
      end
    end

    # Run `claude --help` once per cli_path and return the set of long
    # option flags it advertises (e.g., `--title`). Returns nil when
    # probing is disabled or the probe fails for any reason.
    #
    # IMPORTANT: this is now a DIAGNOSTIC-ONLY helper. The SDK no longer
    # pre-emptively strips flags based on the probe, because the Claude
    # Code CLI hides several real flags from its `--help` output
    # (`--task-budget`, `--thinking`, `--system-prompt-file`, etc.) and the
    # regex-based parser would otherwise strip them invisibly. Stripping a
    # safety cap like `task_budget` silently is worse than letting the
    # subprocess fail with an actionable `UnsupportedOptionError`.
    private def probe_cli_capabilities(cli_path : String) : Set(String)?
      opts = @options
      return if opts && !opts.probe_cli_capabilities?

      if cached = @@capability_mutex.synchronize { @@capability_cache[cli_path]? }
        return cached
      end

      flags = run_cli_help_probe(cli_path)
      if flags
        @@capability_mutex.synchronize { @@capability_cache[cli_path] = flags }
      end
      flags
    end

    # Exposed for testing; overridden by a TestableCLIClient subclass.
    # Bounded by a 5-second timeout so a hung `claude --help` (e.g., CLI
    # waiting on a TTY auth prompt) can't freeze `start`.
    protected def run_cli_help_probe(cli_path : String) : Set(String)?
      output = IO::Memory.new
      done = Channel(Bool).new(1)

      process = Process.new(
        command: cli_path,
        args: ["--help"],
        input: Process::Redirect::Close,
        output: output,
        error: Process::Redirect::Close,
      )

      spawn do
        process.wait
        done.send(true)
      rescue
        done.send(false)
      end

      select
      when outcome = done.receive
        outcome ? self.class.parse_long_flags(output.to_s) : nil
      when timeout(5.seconds)
        begin
          process.terminate rescue nil
          spawn do
            sleep 500.milliseconds
            process.terminate(graceful: false) rescue nil
          end
        end
        nil
      end
    rescue File::NotFoundError
      nil
    rescue IO::Error
      nil
    end

    # Extract every long-form option flag from `claude --help` output.
    # Matches names made of lowercase letters, digits, and hyphens starting
    # with a letter (e.g., `--task-budget`, `--max-thinking-tokens`).
    def self.parse_long_flags(help_text : String) : Set(String)
      flags = Set(String).new
      help_text.scan(/--([a-z][a-z0-9-]*)/) do |match|
        flags << "--#{match[1]}"
      end
      flags
    end

    # Drop optional flags the CLI does not advertise from an already-built
    # argv. Both `--flag value` pairs and `--flag=value` forms are removed.
    # Passes through unchanged when capabilities is nil.
    def filter_unsupported_flags(
      args : Array(String),
      capabilities : Set(String)?,
    ) : Array(String)
      return args unless capabilities

      filtered = [] of String
      i = 0
      while i < args.size
        token = args[i]
        flag_base = token.starts_with?("--") ? token.split('=', 2).first : nil

        if flag_base && OPTIONAL_CLI_FLAGS.includes?(flag_base) && !capabilities.includes?(flag_base)
          warn_dropped_flag(flag_base)
          if token.includes?('=') || i + 1 >= args.size
            i += 1
          else
            # Also skip the next token which is this flag's value.
            i += 2
          end
        else
          filtered << token
          i += 1
        end
      end
      filtered
    end

    private def warn_dropped_flag(flag : String)
      callback = @options.try(&.stderr)
      message = "claude-agent-cr: dropping unsupported CLI flag '#{flag}'; " \
                "install a newer Claude Code CLI to use it\n"
      if callback
        callback.call(message)
      else
        STDERR.puts(message)
      end
    end

    # Inspect recent stderr lines for an "unknown option '--xxx'" message
    # emitted by Claude Code's argv parser, and return the offending flag
    # name when one is found. Helps translate opaque connection failures
    # into `UnsupportedOptionError` with actionable guidance.
    def detect_unknown_option_error : String?
      lines = @stderr_mutex.synchronize { @stderr_tail.dup }
      lines.reverse_each do |line|
        if match = line.match(/unknown option ['"`]?(--[a-z][a-z0-9-]*)['"`]?/)
          return match[1]
        end
      end
      nil
    end

    # Copy of the buffered stderr tail for diagnostics; intentionally
    # returns a snapshot so callers never mutate the internal buffer.
    def stderr_tail : Array(String)
      @stderr_mutex.synchronize { @stderr_tail.dup }
    end

    # Test-only: append a synthetic stderr line to the rolling buffer so
    # specs can exercise `detect_unknown_option_error` without spawning
    # a real subprocess.
    def record_stderr_for_test(line : String) : Nil
      @stderr_mutex.synchronize { @stderr_tail << line }
    end

    # Route a diagnostic line to the caller-supplied `stderr` callback
    # when present, falling back to STDERR. Keeps parse/MCP/hook errors
    # observable from application code without racing STDERR writes.
    private def log_message(line : String) : Nil
      if callback = @options.try(&.stderr)
        callback.call(line)
      else
        STDERR.puts(line.chomp)
      end
    end

    # Test-only: inject an IO as the subprocess input, so specs can inspect
    # what `send_prompt` / `send_json` actually writes without spawning a
    # real subprocess.
    # ameba:disable Naming/AccessorMethodName
    def set_input_for_test(io : IO) : Nil
      @input = io
    end

    # Test-only: inject an IO as the subprocess output, so specs can feed
    # canned stream-json lines through `each_message` without spawning a
    # real CLI. This is the Crystal analogue of Python's
    # `test_subprocess_buffering.py` mock-stream pattern.
    # ameba:disable Naming/AccessorMethodName
    def set_output_for_test(io : IO) : Nil
      @output = io
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
        add_extra_args(args, opts)
      end

      args
    end

    # Escape-hatch for CLI flags that aren't modeled as typed options (yet).
    # Added last so a caller can override behavior or forward newly-added
    # Claude Code CLI flags without waiting for an SDK release.
    #
    # When a value starts with `-`, emit a single `--flag=value` token so a
    # dash-leading value is never misparsed as a separate CLI flag (matches
    # Python 0.2.121+ / TS 0.3.208+).
    private def add_extra_args(args : Array(String), opts : AgentOptions)
      extra = opts.extra_args
      return unless extra

      extra.each do |key, value|
        flag = key.starts_with?("--") ? key : "--#{key}"
        if value.nil?
          args << flag
        elsif value.starts_with?("-")
          args << "#{flag}=#{value}"
        else
          args << flag << value
        end
      end
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
      # NOTE: `opts.title` is a post-hoc session metadata mutation, not a CLI
      # argument. The Claude Code CLI does not accept a `--title` flag; the
      # SDK applies the title by writing a `custom-title` entry to the
      # session JSONL (see `ClaudeAgent.rename_session` / the
      # `generate_session_title` control request). We intentionally do not
      # append anything to argv for `opts.title` here.
      # `--betas <betas...>` is variadic: each beta must be its own argv
      # token or the CLI parses the whole joined string as a single beta
      # name (e.g. "context-1m-2025-08-07,other" would be rejected as one
      # unknown beta). Emitting them as separate tokens is the only form
      # that works for multi-beta configurations.
      opts.betas.try do |betas|
        unless betas.empty?
          args << "--betas"
          betas.each { |beta| args << beta }
        end
      end

      add_debug_args(args, opts)
    end

    # `--debug-file` takes precedence over `--debug` (the file form also
    # enables debug mode). Matches the TS SDK's `debug` / `debugFile`
    # options (0.2.30+). Dash-leading paths use equals form so they are
    # not misparsed as a separate CLI flag.
    private def add_debug_args(args : Array(String), opts : AgentOptions)
      if path = opts.debug_file
        if path.starts_with?("-")
          args << "--debug-file=#{path}"
        else
          args << "--debug-file" << path
        end
      elsif opts.debug?
        args << "--debug"
      end
    end

    # SDK convention: when no system prompt is supplied, emit `--system-prompt ""`
    # so the subprocess does NOT load the CLI's default Claude Code system
    # prompt. Programmatic SDK callers want a vanilla agent by default; the
    # interactive CLI behavior (claude_code preset) is opt-in via
    # `SystemPromptPreset.claude_code`.
    private def add_system_prompt_args(args : Array(String), opts : AgentOptions)
      case system_prompt = opts.system_prompt
      when String
        args << "--system-prompt" << system_prompt
      when SystemPromptPreset
        # Preset is implicit when only append is set. `exclude_dynamic_sections`
        # is communicated via the initialize control request (as
        # `excludeDynamicSections`), not via argv.
        system_prompt.append.try { |append| args << "--append-system-prompt" << append }
      when SystemPromptFile
        args << "--system-prompt-file" << system_prompt.path
      when Nil
        args << "--system-prompt" << ""
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
          if display = thinking.display
            args << "--thinking-display" << display
          end
        when ThinkingConfigEnabled
          args << "--max-thinking-tokens" << thinking.budget_tokens.to_s
          if display = thinking.display
            args << "--thinking-display" << display
          end
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
      # CLI accepts both comma- and space-separated forms; we emit comma for
      # consistency with the rest of the flag surface and to avoid any chance
      # of the shell splitting the argument unexpectedly.
      args << "--allowedTools" << effective_allowed.join(",") unless effective_allowed.empty?
      opts.disallowed_tools.try { |tools| args << "--disallowedTools" << tools.join(",") }

      add_tools_option_args(args, opts)

      opts.add_dirs.try(&.each { |dir| args << "--add-dir" << dir })
      opts.plugins.try(&.each do |plugin|
        case plugin
        when String
          args << "--plugin-dir" << plugin
        when PluginConfig
          # `skip_mcp_discovery` selects the flag itself: the CLI loads
          # `--plugin-dir-no-mcp` plugins without reading their .mcp.json.
          # Matches the TS SDK's argv emission (0.3.172).
          flag = plugin.skip_mcp_discovery? ? "--plugin-dir-no-mcp" : "--plugin-dir"
          args << flag << plugin.path
        end
      end)

      add_mcp_args(args, opts)

      args << "--strict-mcp-config" if opts.strict_mcp_config?

      # NOTE: `opts.agents` is NOT forwarded as the `--agents` CLI flag.
      # Agent definitions flow via the `initialize` control request (see
      # `AgentClient#populate_initialize_agents`), matching the Python and
      # TypeScript SDKs. Double-delivery used to risk redundant argv
      # length and race-condition ambiguity.
      opts.agent.try { |agent| args << "--agent" << agent }
    end

    # Compute effective allowed_tools/setting_sources from `skills`.
    # Injects `Skill` or `Skill(name)` entries into allowed_tools and defaults
    # setting_sources to ["user","project"] ONLY when the caller enabled
    # skills via a non-empty configuration. Returns copies; does not
    # mutate `opts`.
    protected def apply_skills_defaults(opts : AgentOptions) : {Array(String), Array(String)?}
      allowed = opts.allowed_tools.try(&.dup) || [] of String
      sources = opts.setting_sources.try(&.dup)

      case skills = opts.skills
      when Nil
        # No-op. CLI defaults still apply.
      when String
        case skills
        when "all"
          allowed << "Skill" unless allowed.includes?("Skill")
          sources ||= ["user", "project"]
        else
          # Any string other than "all" is invalid. Surface it rather
          # than silently no-op-ing; users typing "none" / "off" /
          # "<skill>" get immediate feedback instead of debugging why
          # their skill configuration is being ignored.
          raise ConfigurationError.new(
            "AgentOptions#skills must be \"all\", an Array(String) of skill names, " \
            "or nil. Got: #{skills.inspect}",
          )
        end
      when Array(String)
        # Empty array is an explicit no-op: the caller wants to opt *out*
        # of skill injection entirely, so we must not mutate
        # `setting_sources` as a side effect.
        unless skills.empty?
          skills.each do |name|
            pattern = "Skill(#{name})"
            allowed << pattern unless allowed.includes?(pattern)
          end
          sources ||= ["user", "project"]
        end
      end

      {allowed, sources}
    end

    private def add_tools_option_args(args : Array(String), opts : AgentOptions)
      case tools = opts.tools
      when Array(String)
        # `--tools ""` explicitly disables all tools. `--tools "A,B,C"` is the
        # comma-separated allowlist the CLI expects.
        args << "--tools" << tools.join(",")
      when ToolsPreset
        # The CLI recognises the preset value "default" (all tools). The
        # legacy preset name "claude_code" is an SDK alias that maps to
        # the canonical "default" so older CLIs don't reject it.
        preset_value = tools.preset == "claude_code" ? "default" : tools.preset
        args << "--tools" << preset_value
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
        # SDK MCP servers still need to be declared to the CLI via
        # `--mcp-config` so the CLI knows to route tool calls back as
        # `mcp_message` control requests. The `instance` itself stays
        # in the SDK; only the declaration metadata crosses the wire.
        sdk_config = {} of String => JSON::Any
        sdk_config["type"] = JSON::Any.new("sdk")
        sdk_config["name"] = JSON::Any.new(config.name)
        sdk_config["version"] = JSON::Any.new(config.version)
        sdk_config
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

      # Pass --resume / --session-id / --resume-session-at as single
      # `--flag=value` tokens. The CLI declares some of these with optional
      # values, so in the two-token form a dash-leading value is not bound to
      # the flag and is instead parsed as a separate CLI flag — letting an
      # untrusted value inject arbitrary flags. The equals form always binds.
      # Matches Python 0.2.121–0.2.124 / TS 0.3.208–0.3.212.
      opts.resume.try { |id| args << "--resume=#{id}" }

      if uuid = opts.resume_session_at
        # CLI rejects `--resume-session-at` when `--resume` isn't present.
        # Validate here so callers get an actionable error pointing at the
        # specific option, rather than an opaque subprocess failure.
        unless opts.resume
          raise ConfigurationError.new(
            "AgentOptions#resume_session_at requires AgentOptions#resume to " \
            "be set to the session ID to resume.",
          )
        end
        args << "--resume-session-at=#{uuid}"
      end

      args << "--fork-session" if opts.fork_session?
      opts.session_id.try { |id| args << "--session-id=#{id}" }

      # Disable session persistence
      args << "--no-session-persistence" if opts.no_session_persistence?
    end

    private def add_session_settings_args(args : Array(String), opts : AgentOptions)
      # --setting-sources takes comma-separated values. Always emitted as
      # a single `--setting-sources=<csv>` token (matching the canonical
      # Python SDK shape). The empty case becomes `--setting-sources=`,
      # which disables all filesystem settings without the CLI consuming
      # the next flag as its value.
      _, effective_sources = apply_skills_defaults(opts)
      effective_sources.try do |sources|
        args << "--setting-sources=#{sources.join(",")}"
      end

      # --settings takes a path or JSON string
      # If sandbox settings are provided without a settings_path, serialize them
      settings_json = build_settings_json(opts)
      if settings_json
        args << "--settings" << settings_json
      elsif path = opts.settings_path
        args << "--settings" << path
      end

      # Policy-tier settings honored below IT-controlled managed sources.
      # Emitted as `--managed-settings <json>` — a real CLI flag that is
      # hidden from `claude --help` (the TS SDK emits it the same way).
      # Matches the TS SDK's `managedSettings` (0.2.118).
      opts.managed_settings.try { |managed| args << "--managed-settings" << managed.to_json }
    end

    private def build_settings_json(opts : AgentOptions) : String?
      settings = {} of String => JSON::Any

      if sandbox = opts.sandbox
        # Build sandbox settings object
        sandbox_obj = {} of String => JSON::Any
        sandbox_obj["enabled"] = JSON::Any.new(sandbox.enabled?) if sandbox.enabled?
        sandbox_obj["autoAllowBashIfSandboxed"] = JSON::Any.new(sandbox.auto_allow_bash_if_sandboxed?) if sandbox.auto_allow_bash_if_sandboxed?
        sandbox_obj["allowUnsandboxedCommands"] = JSON::Any.new(sandbox.allow_unsandboxed_commands?) if sandbox.allow_unsandboxed_commands?
        sandbox_obj["enableWeakerNestedSandbox"] = JSON::Any.new(sandbox.enable_weaker_nested_sandbox?) if sandbox.enable_weaker_nested_sandbox?
        # Always emit failIfUnavailable explicitly when the sandbox is enabled
        # so callers who rely on the default (fail fast) behavior get it even
        # on CLIs that historically defaulted to silent fallback.
        if sandbox.enabled?
          sandbox_obj["failIfUnavailable"] = JSON::Any.new(sandbox.fail_if_unavailable?)
        end

        sandbox.excluded_commands.try do |cmds|
          sandbox_obj["excludedCommands"] = JSON::Any.new(cmds.map { |cmd| JSON::Any.new(cmd) })
        end

        sandbox.network.try do |net|
          net_obj = build_sandbox_network_json(net)
          sandbox_obj["network"] = JSON::Any.new(net_obj) unless net_obj.empty?
        end

        sandbox.ignore_violations.try do |ignore|
          ignore_obj = {} of String => JSON::Any
          ignore.file.try { |files| ignore_obj["file"] = JSON::Any.new(files.map { |path| JSON::Any.new(path) }) }
          ignore.network.try { |networks| ignore_obj["network"] = JSON::Any.new(networks.map { |pattern| JSON::Any.new(pattern) }) }
          sandbox_obj["ignoreViolations"] = JSON::Any.new(ignore_obj) unless ignore_obj.empty?
        end

        sandbox.credentials.try do |creds|
          # The structs carry the wire-format keys (path/mode, name/mode/
          # injectHosts, allowPlaintextInject) via JSON::Serializable, so a
          # serialize round-trip is the least error-prone way to attach them.
          sandbox_obj["credentials"] = JSON.parse(creds.to_json)
        end

        settings["sandbox"] = JSON::Any.new(sandbox_obj) unless sandbox_obj.empty?
      end

      # Top-level settings key for the advisory Dynamic workflow size guideline
      # (TS SDK 0.3.219). Emitted even when sandbox is unset.
      opts.workflow_size_guideline.try do |guideline|
        settings["workflowSizeGuideline"] = JSON::Any.new(guideline)
      end

      return if settings.empty?
      settings.to_json
    end

    private def build_sandbox_network_json(net : SandboxNetworkSettings) : Hash(String, JSON::Any)
      net_obj = {} of String => JSON::Any
      net_obj["allowLocalBinding"] = JSON::Any.new(net.allow_local_binding?) if net.allow_local_binding?
      net_obj["allowAllUnixSockets"] = JSON::Any.new(net.allow_all_unix_sockets?) if net.allow_all_unix_sockets?
      net.allow_unix_sockets.try do |sockets|
        net_obj["allowUnixSockets"] = JSON::Any.new(sockets.map { |sock| JSON::Any.new(sock) })
      end
      net.http_proxy_port.try { |port| net_obj["httpProxyPort"] = JSON::Any.new(port.to_i64) }
      net.socks_proxy_port.try { |port| net_obj["socksProxyPort"] = JSON::Any.new(port.to_i64) }
      net.allowed_domains.try do |domains|
        net_obj["allowedDomains"] = JSON::Any.new(domains.map { |domain| JSON::Any.new(domain) })
      end
      net.denied_domains.try do |domains|
        net_obj["deniedDomains"] = JSON::Any.new(domains.map { |domain| JSON::Any.new(domain) })
      end
      if (managed_only = net.allow_managed_domains_only?).is_a?(Bool)
        net_obj["allowManagedDomainsOnly"] = JSON::Any.new(managed_only)
      end
      net.allow_mach_lookup.try do |names|
        net_obj["allowMachLookup"] = JSON::Any.new(names.map { |name| JSON::Any.new(name) })
      end
      # Emit strictAllowlist whenever explicitly set (true or false).
      if (strict = net.strict_allowlist?).is_a?(Bool)
        net_obj["strictAllowlist"] = JSON::Any.new(strict)
      end
      net_obj
    end

    private def add_session_streaming_args(args : Array(String), opts : AgentOptions)
      # Streaming options
      args << "--include-partial-messages" if opts.include_partial_messages?
      args << "--include-hook-events" if opts.include_hook_events?
      args << "--replay-user-messages" if opts.replay_user_messages?
      # SessionStore live mirror: CLI emits transcript_mirror frames that the
      # SDK peels off and appends to the adapter (Python/TS --session-mirror).
      args << "--session-mirror" if opts.session_store
      # NOTE: `forward_subagent_text` is NOT a CLI argv flag — it flows
      # through the `initialize` control request as `forwardSubagentText`
      # (see AgentClient#populate_initialize_flags), matching the TS SDK.
      # NOTE: file checkpointing is enabled via the
      # `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=true` environment variable
      # (see `#build_env`), NOT a CLI flag. The CLI does not accept any
      # `--enable-file-checkpointing` flag and will abort argv parsing if
      # one is passed.
      opts.permission_prompt_tool_name.try { |name| args << "--permission-prompt-tool" << name }

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
