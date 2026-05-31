require "set"
require "./cli_client"
require "./hooks"
require "./types/control_messages"

module ClaudeAgent
  class AgentClient
    private alias ControlRequestResult = Hash(String, JSON::Any) | Exception
    private HOOK_NAME_ALIASES = {
      "PreToolUse"            => "pre_tool_use",
      "pre_tool_use"          => "pre_tool_use",
      "PostToolUse"           => "post_tool_use",
      "post_tool_use"         => "post_tool_use",
      "PostToolUseFailure"    => "post_tool_use_failure",
      "post_tool_use_failure" => "post_tool_use_failure",
      "PermissionRequest"     => "permission_request",
      "permission_request"    => "permission_request",
      "Elicitation"           => "elicitation",
      "elicitation"           => "elicitation",
      "ElicitationResult"     => "elicitation_result",
      "elicitation_result"    => "elicitation_result",
      "Notification"          => "notification",
      "notification"          => "notification",
      "PreCompact"            => "pre_compact",
      "pre_compact"           => "pre_compact",
      "SubagentStart"         => "subagent_start",
      "subagent_start"        => "subagent_start",
      "SubagentStop"          => "subagent_stop",
      "subagent_stop"         => "subagent_stop",
      "SessionStart"          => "session_start",
      "session_start"         => "session_start",
      "SessionEnd"            => "session_end",
      "session_end"           => "session_end",
      "UserPromptSubmit"      => "user_prompt_submit",
      "user_prompt_submit"    => "user_prompt_submit",
      "Stop"                  => "stop",
      "stop"                  => "stop",
      "TeammateIdle"          => "teammate_idle",
      "teammate_idle"         => "teammate_idle",
      "TaskCompleted"         => "task_completed",
      "task_completed"        => "task_completed",
      "ConfigChange"          => "config_change",
      "config_change"         => "config_change",
    }

    private struct HookCallbackRegistration
      getter hook_name : String
      getter callback : HookCallback

      def initialize(@hook_name : String, @callback : HookCallback)
      end
    end

    @cli_client : CLIClient
    @message_channel : Channel(Message)
    @response_fiber : Fiber?
    @pending_control_requests : Hash(String, Channel(ControlRequestResult))
    @control_request_mutex : Mutex
    @registered_hook_callbacks : Hash(String, HookCallbackRegistration)
    @registered_control_hook_events : Set(String)
    @hook_callback_counter : Int64 = 0
    @request_counter : Int64 = 0
    @interrupted : Bool = false
    @sdk_init_sent : Bool = false
    @started : Bool = false
    @server_info : ServerInfo? = nil
    @state_mutex : Mutex = Mutex.new

    def initialize(@options : AgentOptions? = nil, cli_client : CLIClient? = nil)
      @cli_client = cli_client || CLIClient.new(@options)
      @message_channel = Channel(Message).new(100)
      @pending_control_requests = {} of String => Channel(ControlRequestResult)
      @control_request_mutex = Mutex.new
      @registered_hook_callbacks = {} of String => HookCallbackRegistration
      @registered_control_hook_events = Set(String).new
    end

    # Get the current session ID
    def session_id : String?
      @cli_client.session_id
    end

    def started? : Bool
      @state_mutex.synchronize { @started }
    end

    def start
      @cli_client.start
      @state_mutex.synchronize do
        @interrupted = false
        @started = true
      end
      start_response_reader
      begin
        send_sdk_initialization
      rescue ex
        @state_mutex.synchronize { @started = false }
        @cli_client.stop
        @message_channel.close unless @message_channel.closed?
        raise ex
      end
      trigger_hook(:session_start)
    end

    # Send SDK MCP server initialization to CLI
    private def send_sdk_initialization
      return if @sdk_init_sent
      request = {} of String => JSON::Any
      request["subtype"] = JSON::Any.new("initialize")

      populate_initialize_mcp(request)
      populate_initialize_hooks(request)
      populate_initialize_agents(request)
      populate_initialize_flags(request)
      populate_initialize_skills(request)
      populate_initialize_system_prompt(request)

      response = send_control_request(request, 90.seconds)
      @server_info = response.empty? ? nil : ServerInfo.from_data(response)
      @sdk_init_sent = true
    end

    private def populate_initialize_mcp(request : Hash(String, JSON::Any))
      return unless @cli_client.has_sdk_servers?

      request["sdkMcpServers"] = JSON::Any.new(
        @cli_client.sdk_server_names.map { |name| JSON::Any.new(name) }
      )
    end

    private def populate_initialize_hooks(request : Hash(String, JSON::Any))
      if hooks_payload = build_hook_initialize_payload
        request["hooks"] = JSON::Any.new(hooks_payload)
      end
    end

    private def populate_initialize_agents(request : Hash(String, JSON::Any))
      if agents_payload = build_agents_initialize_payload
        request["agents"] = agents_payload
      end
    end

    private def populate_initialize_flags(request : Hash(String, JSON::Any))
      request["promptSuggestions"] = JSON::Any.new(true) if @options.try(&.prompt_suggestions?)
      request["agentProgressSummaries"] = JSON::Any.new(true) if @options.try(&.agent_progress_summaries?)
    end

    # Forward `skills` to the CLI so a supporting CLI can filter which
    # skills are loaded into the system prompt. Older CLIs ignore this.
    #
    # `"all"` and omitted are equivalent at the wire level (no filter),
    # so the `"all"` case is a no-op here; the injection happens in
    # `apply_skills_defaults` via the `Skill` allow-rule instead.
    private def populate_initialize_skills(request : Hash(String, JSON::Any))
      case skills = @options.try(&.skills)
      when Array(String)
        request["skills"] = JSON::Any.new(skills.map { |skill| JSON::Any.new(skill) })
      end
    end

    # `exclude_dynamic_sections` on a `SystemPromptPreset` flows through
    # the initialize request as `excludeDynamicSections`, not a CLI flag.
    # `title` is also forwarded here so the CLI can apply it to the
    # session transcript without us waiting for `session_id` first.
    # Older CLIs silently ignore unknown initialize fields.
    private def populate_initialize_system_prompt(request : Hash(String, JSON::Any))
      preset = @options.try(&.system_prompt).as?(SystemPromptPreset)
      if preset && preset.exclude_dynamic_sections?
        request["excludeDynamicSections"] = JSON::Any.new(true)
      end

      @options.try(&.title).try do |title|
        stripped = title.strip
        request["title"] = JSON::Any.new(stripped) unless stripped.empty?
      end
    end

    def stop
      @state_mutex.synchronize { @started = false }
      trigger_hook(:session_end)
      fail_pending_control_requests(ConnectionError.new("Agent client stopped"))
      # Close the message channel BEFORE stopping the CLI. That way, any
      # fiber blocked inside `each_response` on `@message_channel.receive?`
      # wakes immediately with `nil` and exits cleanly. If the CLI side
      # is stuck, the graceful→TERM→KILL cascade in `CLIClient#stop` then
      # takes over without leaving `each_response` blocked.
      @message_channel.close unless @message_channel.closed?
      @cli_client.stop
    end

    # Send a query and get responses
    def query(prompt : String, *, uuid : String? = nil, should_query : Bool = true)
      trigger_hook(:user_prompt_submit, prompt) if should_query
      @cli_client.send_prompt(prompt, uuid: uuid, should_query: should_query)
    end

    def cancel_async_message(message_uuid : String) : Bool
      response = send_control_request({
        "subtype"      => JSON::Any.new("cancel_async_message"),
        "message_uuid" => JSON::Any.new(message_uuid),
      })

      response["cancelled"]?.try(&.as_bool?) == true
    end

    # Interrupt a streaming query
    def interrupt
      @state_mutex.synchronize do
        return if @interrupted
        @interrupted = true
      end

      @cli_client.send_message({
        "type" => JSON::Any.new("interrupt"),
      })
    end

    # ameba:disable Naming/AccessorMethodName
    def set_permission_mode(mode : PermissionMode)
      set_permission_mode(permission_mode_value(mode))
    end

    # ameba:disable Naming/AccessorMethodName
    def set_permission_mode(mode : String)
      send_control_request({
        "subtype" => JSON::Any.new("set_permission_mode"),
        "mode"    => JSON::Any.new(mode),
      })
    end

    # ameba:disable Naming/AccessorMethodName
    def set_model(model : String? = nil)
      request = {
        "subtype" => JSON::Any.new("set_model"),
      }
      request["model"] = model ? JSON::Any.new(model) : JSON::Any.new(nil)
      send_control_request(request)
    end

    # ameba:disable Naming/AccessorMethodName
    def get_mcp_status : MCPStatusResponse
      response = send_control_request({
        "subtype" => JSON::Any.new("mcp_status"),
      })

      response = response.dup
      response["mcpServers"] ||= JSON::Any.new([] of JSON::Any)
      MCPStatusResponse.from_json(response.to_json)
    end

    # Retrieve a breakdown of context window usage by category.
    # ameba:disable Naming/AccessorMethodName
    def get_context_usage : ContextUsageResponse
      response = send_control_request({
        "subtype" => JSON::Any.new("get_context_usage"),
      })

      ContextUsageResponse.from_json(response.to_json)
    end

    # Reload plugins and receive refreshed commands, agents, and MCP servers.
    # Returns the raw response payload (shape mirrors system/init).
    def reload_plugins : Hash(String, JSON::Any)
      send_control_request({
        "subtype" => JSON::Any.new("reload_plugins"),
      })
    end

    # Request a prompt suggestion based on the current conversation context.
    # Returns the response payload; the suggestion itself is typically
    # delivered as a `prompt_suggestion` SDK message.
    def prompt_suggestion : Hash(String, JSON::Any)
      send_control_request({
        "subtype" => JSON::Any.new("prompt_suggestion"),
      })
    end

    # Replace the active MCP server configuration at runtime.
    # Accepts a hash mirroring the `mcpServers` entries from options.
    # ameba:disable Naming/AccessorMethodName
    def set_mcp_servers(mcp_servers : Hash(String, JSON::Any))
      send_control_request({
        "subtype"    => JSON::Any.new("mcp_set_servers"),
        "mcpServers" => JSON::Any.new(mcp_servers),
      })
    end

    # Activate the tools channel on an MCP server that advertises it
    # lazily. No-op for servers that are already fully connected.
    def enable_mcp_channel(server_name : String)
      send_control_request({
        "subtype"    => JSON::Any.new("mcp_enable_channel"),
        "serverName" => JSON::Any.new(server_name),
      })
    end

    # ameba:disable Naming/AccessorMethodName
    def get_server_info : ServerInfo?
      raise ConnectionError.new("Not connected. Call start() first.") unless started?

      @server_info
    end

    def supported_agents : Array(ServerAgentInfo)
      raise ConnectionError.new("Not connected. Call start() first.") unless started?

      @server_info.try(&.agents) || [] of ServerAgentInfo
    end

    def supported_commands : Array(ServerCommand)
      raise ConnectionError.new("Not connected. Call start() first.") unless started?

      @server_info.try(&.commands) || [] of ServerCommand
    end

    def reconnect_mcp_server(server_name : String)
      send_control_request({
        "subtype"    => JSON::Any.new("mcp_reconnect"),
        "serverName" => JSON::Any.new(server_name),
      })
    end

    def toggle_mcp_server(server_name : String, enabled : Bool)
      send_control_request({
        "subtype"    => JSON::Any.new("mcp_toggle"),
        "serverName" => JSON::Any.new(server_name),
        "enabled"    => JSON::Any.new(enabled),
      })
    end

    def stop_task(task_id : String)
      send_control_request({
        "subtype" => JSON::Any.new("stop_task"),
        "task_id" => JSON::Any.new(task_id),
      })
    end

    def settings : Hash(String, JSON::Any)
      send_control_request({
        "subtype" => JSON::Any.new("get_settings"),
      })
    end

    def apply_flag_settings(flag_settings : Hash(String, JSON::Any))
      send_control_request({
        "subtype"  => JSON::Any.new("apply_flag_settings"),
        "settings" => JSON::Any.new(flag_settings),
      })
    end

    def enable_remote_control(enabled : Bool = true) : Hash(String, JSON::Any)
      send_control_request({
        "subtype" => JSON::Any.new("remote_control"),
        "enabled" => JSON::Any.new(enabled),
      })
    end

    # ameba:disable Naming/AccessorMethodName
    def set_proactive(enabled : Bool)
      send_control_request({
        "subtype" => JSON::Any.new("set_proactive"),
        "enabled" => JSON::Any.new(enabled),
      })
    end

    def generate_session_title(description : String, *, persist : Bool = false) : String?
      response = send_control_request({
        "subtype"     => JSON::Any.new("generate_session_title"),
        "description" => JSON::Any.new(description),
        "persist"     => JSON::Any.new(persist),
      })

      response["title"]?.try(&.as_s?)
    end

    # ameba:enable Naming/AccessorMethodName

    # Rewind files to a checkpoint.
    # Requires enable_file_checkpointing: true and replay_user_messages: true.
    # Sends via the control protocol (matching the TypeScript SDK).
    def rewind_files(user_message_id : String, *, dry_run : Bool = false) : Hash(String, JSON::Any)
      send_control_request({
        "subtype"         => JSON::Any.new("rewind_files"),
        "user_message_id" => JSON::Any.new(user_message_id),
        "dry_run"         => JSON::Any.new(dry_run),
      })
    end

    # Iterate over incoming messages
    def each_response(&block : Message ->)
      result_received = false

      loop do
        message = receive_next_message(result_received)
        break unless message
        next if handle_internal_message(message)

        run_message_hooks(message)
        block.call(message)

        if result_received
          break
        elsif message.is_a?(ResultMessage)
          result_received = true
          break unless @options.try(&.prompt_suggestions?)
        end
      end
    end

    # Send a follow-up message. Pass `should_query: false` to append the
    # message to the transcript without triggering an assistant turn.
    def send_user_message(content : String, *, uuid : String? = nil, should_query : Bool = true)
      trigger_hook(:user_prompt_submit, content) if should_query
      @cli_client.send_user_message(content, uuid: uuid, should_query: should_query)
    end

    # Send permission response
    def grant_permission(tool_use_id : String, allow : Bool, reason : String? = nil)
      message = Hash(String, String | Bool | Nil).new
      message["type"] = "permission_response"
      message["tool_use_id"] = tool_use_id
      message["allow"] = allow
      message["reason"] = reason if reason
      @cli_client.send_json(message)
    end

    # Answer a UserQuestion from the CLI.
    # Note: The wire format for this response has not been confirmed against the
    # official SDK protocol. If Claude Code changes the expected shape, this may
    # need updating.
    def answer_question(uuid : String, answer : String)
      @cli_client.send_message({
        "type"    => "user_response",
        "uuid"    => uuid,
        "message" => answer,
      })
    end

    # Context manager pattern
    def self.open(options : AgentOptions? = nil, &)
      client = new(options)
      begin
        client.start
        yield client
      ensure
        client.stop
      end
    end

    private def start_response_reader
      @response_fiber = spawn do
        begin
          @cli_client.each_message do |message|
            next if @message_channel.closed?

            if message.is_a?(ControlResponseMessage)
              handle_control_response(message)
              next
            end

            @message_channel.send(message)
          end
        rescue Channel::ClosedError
          # Expected during shutdown
        rescue ex
          STDERR.puts "claude-agent-cr: response reader error: #{ex.message}"
        ensure
          fail_pending_control_requests(connection_closed_error)
          @message_channel.close unless @message_channel.closed?
        end
      end
    end

    # Translate an abrupt subprocess exit into a more actionable error when
    # the CLI's stderr contains an "unknown option '--xxx'" message (a
    # signature of forwarding a v0.5+ SDK-only flag to an older CLI).
    # Falls back to a generic ConnectionError otherwise.
    private def connection_closed_error : ClaudeAgent::Error
      if flag = @cli_client.detect_unknown_option_error
        UnsupportedOptionError.new(flag, cli_path: @options.try(&.cli_path))
      else
        ConnectionError.new("Agent client connection closed")
      end
    end

    private def permission_mode_value(mode : PermissionMode) : String
      mode.to_cli_value
    end

    private def receive_post_result_message : Message?
      select
      when message = @message_channel.receive?
        message
      when timeout(2.seconds)
        nil
      end
    end

    private def receive_next_message(result_received : Bool) : Message?
      if result_received && @options.try(&.prompt_suggestions?)
        receive_post_result_message
      else
        @message_channel.receive?
      end
    end

    private def handle_internal_message(message : Message) : Bool
      case message
      when ControlRequest
        handle_control_request(message)
        true
      when ControlResponseMessage
        true
      when PermissionRequest
        handle_permission_request(message)
        @options.try(&.can_use_tool) || has_permission_hooks? ? true : false
      else
        false
      end
    end

    private def run_message_hooks(message : Message)
      case message
      when AssistantMessage
        handle_post_tool_use_hooks(message)
        handle_subagent_hooks(message)
      when ResultMessage
        trigger_stop_hook(message)
      end
    end

    private def has_permission_hooks? : Bool
      hooks = @options.try(&.hooks)
      return false unless hooks

      !hooks.pre_tool_use.nil? || !hooks.permission_request.nil? ||
        control_hook_registered?("PreToolUse") || control_hook_registered?("PermissionRequest")
    end

    private def send_control_request(
      request : Hash(String, JSON::Any),
      timeout : Time::Span = 60.seconds,
    ) : Hash(String, JSON::Any)
      raise ConnectionError.new("Not connected. Call start() first.") unless started?

      response_channel = Channel(ControlRequestResult).new(1)
      request_id = register_pending_control_request(response_channel)

      control_request = {
        "type"       => JSON::Any.new("control_request"),
        "request_id" => JSON::Any.new(request_id),
        "request"    => JSON::Any.new(request),
      }

      @cli_client.send_message(control_request)

      select
      when result = response_channel.receive
        case result
        when Exception
          raise result
        when Hash(String, JSON::Any)
          parse_control_response(result, request)
        else
          {} of String => JSON::Any
        end
      when timeout(timeout)
        unregister_pending_control_request(request_id)
        subtype = request["subtype"]?.try(&.as_s?) || "unknown"
        raise TimeoutError.new("Control request timeout: #{subtype}")
      end
    end

    private def register_pending_control_request(
      response_channel : Channel(ControlRequestResult),
    ) : String
      @control_request_mutex.synchronize do
        @request_counter += 1
        request_id = "req_#{@request_counter}"
        @pending_control_requests[request_id] = response_channel
        request_id
      end
    end

    private def unregister_pending_control_request(
      request_id : String,
    ) : Channel(ControlRequestResult)?
      @control_request_mutex.synchronize do
        @pending_control_requests.delete(request_id)
      end
    end

    private def handle_control_response(message : ControlResponseMessage)
      request_id = message.response["request_id"]?.try(&.as_s?)
      return unless request_id

      response_channel = unregister_pending_control_request(request_id)
      return unless response_channel

      response_channel.send(message.response)
    rescue Channel::ClosedError
    end

    private def parse_control_response(
      response : Hash(String, JSON::Any),
      request : Hash(String, JSON::Any),
    ) : Hash(String, JSON::Any)
      case response["subtype"]?.try(&.as_s?)
      when "error"
        message = response["error"]?.try(&.as_s?) || "Control request failed"
        raise Error.new(message)
      else
        response["response"]?.try(&.as_h?) || {} of String => JSON::Any
      end
    end

    private def fail_pending_control_requests(error : Exception)
      channels = @control_request_mutex.synchronize do
        pending = @pending_control_requests.values
        @pending_control_requests.clear
        pending
      end

      channels.each do |channel|
        begin
          channel.send(error)
        rescue Channel::ClosedError
        end
      end
    end

    private def build_hook_initialize_payload : Hash(String, JSON::Any)?
      hooks = @options.try(&.hooks)
      return nil unless hooks

      payload = {} of String => JSON::Any

      add_matcher_hook_payload(payload, "PreToolUse", hooks.pre_tool_use)
      add_matcher_hook_payload(payload, "PostToolUse", hooks.post_tool_use)
      add_matcher_hook_payload(payload, "PostToolUseFailure", hooks.post_tool_use_failure)
      add_matcher_hook_payload(payload, "PermissionRequest", hooks.permission_request)
      add_simple_hook_payload(payload, "Elicitation", hooks.elicitation)
      add_simple_hook_payload(payload, "ElicitationResult", hooks.elicitation_result)
      add_simple_hook_payload(payload, "PreCompact", hooks.pre_compact)
      add_simple_hook_payload(payload, "Notification", hooks.notification)
      add_simple_hook_payload(payload, "SubagentStart", hooks.subagent_start)
      add_simple_hook_payload(payload, "SubagentStop", hooks.subagent_stop)
      add_simple_hook_payload(payload, "Stop", hooks.stop)
      add_simple_hook_payload(payload, "TeammateIdle", hooks.teammate_idle)
      add_simple_hook_payload(payload, "TaskCompleted", hooks.task_completed)
      add_simple_hook_payload(payload, "ConfigChange", hooks.config_change)

      payload.empty? ? nil : payload
    end

    private def add_matcher_hook_payload(
      payload : Hash(String, JSON::Any),
      hook_name : String,
      matchers : Array(HookMatcher)?,
    )
      return unless matchers

      entries = matchers.compact_map do |matcher|
        callback_ids = register_hook_callbacks(hook_name, matcher.hooks)
        next if callback_ids.empty?

        entry = {} of String => JSON::Any
        if matcher_value = matcher.matcher
          entry["matcher"] = JSON::Any.new(matcher_value)
        end
        matcher.timeout.try { |timeout| entry["timeout"] = JSON::Any.new(timeout) }
        entry["hookCallbackIds"] = JSON::Any.new(callback_ids.map { |id| JSON::Any.new(id) })
        JSON::Any.new(entry)
      end

      return if entries.empty?

      payload[hook_name] = JSON::Any.new(entries)
      @registered_control_hook_events.add(hook_name)
    end

    private def add_simple_hook_payload(
      payload : Hash(String, JSON::Any),
      hook_name : String,
      callbacks : Array(HookCallback)?,
    )
      return unless callbacks

      callback_ids = register_hook_callbacks(hook_name, callbacks)
      return if callback_ids.empty?

      entry = {
        "hookCallbackIds" => JSON::Any.new(callback_ids.map { |id| JSON::Any.new(id) }),
      }

      payload[hook_name] = JSON::Any.new([JSON::Any.new(entry)])
      @registered_control_hook_events.add(hook_name)
    end

    private def register_hook_callbacks(
      hook_name : String,
      callbacks : Array(HookCallback),
    ) : Array(String)
      callbacks.map do |callback|
        @hook_callback_counter += 1
        callback_id = "hook_#{@hook_callback_counter}"
        @registered_hook_callbacks[callback_id] = HookCallbackRegistration.new(hook_name, callback)
        callback_id
      end
    end

    private def control_hook_registered?(hook_name : String) : Bool
      @registered_control_hook_events.includes?(hook_name)
    end

    private def build_agents_initialize_payload : JSON::Any?
      agents = @options.try(&.agents)
      return nil unless agents

      JSON.parse(agents.to_json)
    end

    # Common context fields for all hook inputs
    private def hook_common_fields(hook_event_name : String)
      {
        session_id:      session_id || "unknown",
        cwd:             @options.try(&.cwd),
        permission_mode: @options.try(&.permission_mode).try { |mode| permission_mode_value(mode) },
        hook_event_name: hook_event_name,
      }
    end

    private def trigger_hook(event : Symbol, data : String? = nil)
      hooks = @options.try(&.hooks)
      return unless hooks

      event_name = case event
                   when :session_start      then "SessionStart"
                   when :session_end        then "SessionEnd"
                   when :user_prompt_submit then "UserPromptSubmit"
                   else                          return
                   end

      callbacks = case event
                  when :session_start      then hooks.session_start
                  when :session_end        then hooks.session_end
                  when :user_prompt_submit then hooks.user_prompt_submit
                  else                          nil
                  end

      return unless callbacks

      common = hook_common_fields(event_name)
      input = HookInput.new(
        session_id: common[:session_id],
        cwd: common[:cwd],
        permission_mode: common[:permission_mode],
        hook_event_name: common[:hook_event_name],
        user_prompt: data,
      )
      ctx = HookContext.new(session_id: common[:session_id])

      callbacks.each do |callback|
        safe_hook_call(common[:hook_event_name] || "?") { callback.call(input, "", ctx) }
      end
    end

    # Invoke a user-provided hook callback without letting it take down
    # the response-reader fiber. A callback that raises writes a one-line
    # diagnostic to STDERR (or the configured stderr callback) and the
    # pipeline continues. Without this guard a buggy hook used to skip
    # `fail_pending_control_requests`, leaking subprocesses and hanging
    # in-flight control requests.
    private def safe_hook_call(event_name : String, &)
      yield
    rescue ex
      stderr_cb = @options.try(&.stderr)
      message = "[hook error] #{event_name}: #{ex.class}: #{ex.message}\n"
      if stderr_cb
        stderr_cb.call(message)
      else
        STDERR.puts(message)
      end
    end

    private def handle_permission_request(request : PermissionRequest)
      all_hooks = @options.try(&.hooks)
      return if run_local_pre_tool_use_hooks(all_hooks, request)
      run_local_permission_request_hooks(all_hooks, request)

      if callback = @options.try(&.can_use_tool)
        context = PermissionContext.new(
          tool_name: request.tool_name,
          tool_input: request.tool_input,
          session_id: session_id || "unknown"
        )

        result = callback.call(context)
        grant_permission(request.tool_use_id, result.allow?, result.reason)
        return
      end
    end

    private def run_local_pre_tool_use_hooks(
      hooks : HookConfig?,
      request : PermissionRequest,
    ) : Bool
      return false if control_hook_registered?("PreToolUse")

      hooks.try(&.pre_tool_use).try do |matchers|
        common = hook_common_fields("PreToolUse")
        input = HookInput.new(
          session_id: common[:session_id],
          cwd: common[:cwd],
          permission_mode: common[:permission_mode],
          hook_event_name: common[:hook_event_name],
          tool_name: request.tool_name,
          tool_input: request.tool_input,
          tool_use_id: request.tool_use_id,
        )
        ctx = HookContext.new(session_id: common[:session_id])

        matchers.each do |hook_matcher|
          next unless hook_matcher.matches?(request.tool_name)

          hook_matcher.hooks.each do |callback|
            result = callback.call(input, request.tool_use_id, ctx)
            output = result.hook_specific_output
            next unless output && output.permission_decision == "deny"

            grant_permission(request.tool_use_id, false, output.permission_decision_reason)
            return true
          end
        end
      end

      false
    end

    private def run_local_permission_request_hooks(
      hooks : HookConfig?,
      request : PermissionRequest,
    )
      return if control_hook_registered?("PermissionRequest")

      hooks.try(&.permission_request).try do |matchers|
        common = hook_common_fields("PermissionRequest")
        input = HookInput.new(
          session_id: common[:session_id],
          cwd: common[:cwd],
          permission_mode: common[:permission_mode],
          hook_event_name: common[:hook_event_name],
          tool_name: request.tool_name,
          tool_input: request.tool_input,
          tool_use_id: request.tool_use_id,
        )
        ctx = HookContext.new(session_id: common[:session_id])

        matchers.each do |hook_matcher|
          next unless hook_matcher.matches?(request.tool_name)
          hook_matcher.hooks.each(&.call(input, request.tool_use_id, ctx))
        end
      end
    end

    # Trigger PostToolUse hooks when we see ToolResultBlock in messages
    private def handle_post_tool_use_hooks(message : AssistantMessage)
      hooks = @options.try(&.hooks)
      return unless hooks

      # Check for ToolResultBlock in content (indicates tool completed)
      message.content.each do |block|
        next unless block.is_a?(ToolResultBlock)

        # Find the corresponding ToolUseBlock to get the tool name
        tool_name = find_tool_name_for_result(message, block.tool_use_id)
        next unless tool_name

        # Determine if this was a failure
        is_error = block.is_error == true
        if is_error
          next if control_hook_registered?("PostToolUseFailure")
        else
          next if control_hook_registered?("PostToolUse")
        end

        hook_matchers = is_error ? hooks.post_tool_use_failure : hooks.post_tool_use
        next unless hook_matchers

        hook_matchers.each do |hook_matcher|
          next unless hook_matcher.matches?(tool_name)

          # Get result content as string
          result_content = case content = block.content
                           when String then content
                           when Array  then content.to_json
                           else             ""
                           end

          hook_event = is_error ? "PostToolUseFailure" : "PostToolUse"
          common = hook_common_fields(hook_event)
          # Find the original tool_input from the ToolUseBlock
          original_tool_input = find_tool_input_for_result(message, block.tool_use_id)
          input = HookInput.new(
            session_id: common[:session_id],
            cwd: common[:cwd],
            permission_mode: common[:permission_mode],
            hook_event_name: common[:hook_event_name],
            tool_name: tool_name,
            tool_input: original_tool_input,
            tool_use_id: block.tool_use_id,
            tool_result: result_content,
            tool_response: result_content,
            error: is_error ? result_content : nil,
          )
          ctx = HookContext.new(session_id: common[:session_id])

          hook_matcher.hooks.each do |callback|
            safe_hook_call("PostToolUse") do
              callback.call(input, block.tool_use_id, ctx)
            end
          end
        end
      end
    end

    # Find tool name from a ToolUseBlock matching the tool_use_id
    private def find_tool_name_for_result(message : AssistantMessage, tool_use_id : String) : String?
      message.content.each do |block|
        if block.is_a?(ToolUseBlock) && block.id == tool_use_id
          return block.name
        end
      end
      nil
    end

    # Find tool input from a ToolUseBlock matching the tool_use_id
    private def find_tool_input_for_result(message : AssistantMessage, tool_use_id : String) : Hash(String, JSON::Any)?
      message.content.each do |block|
        if block.is_a?(ToolUseBlock) && block.id == tool_use_id
          return block.input
        end
      end
      nil
    end

    # Trigger SubagentStart/SubagentStop hooks based on Task tool usage
    private def handle_subagent_hooks(message : AssistantMessage)
      hooks = @options.try(&.hooks)
      return unless hooks

      message.content.each do |block|
        case block
        when ToolUseBlock
          handle_subagent_start(hooks, block)
        when ToolResultBlock
          handle_subagent_stop(hooks, message, block)
        end
      end
    end

    private def handle_subagent_start(hooks : HookConfig, block : ToolUseBlock)
      return unless block.name == "Task"
      return if control_hook_registered?("SubagentStart")
      callbacks = hooks.subagent_start
      return unless callbacks

      common = hook_common_fields("SubagentStart")
      input = HookInput.new(
        session_id: common[:session_id],
        cwd: common[:cwd],
        permission_mode: common[:permission_mode],
        hook_event_name: common[:hook_event_name],
        tool_name: "Task",
        tool_input: block.input,
      )
      ctx = HookContext.new(session_id: common[:session_id])
      callbacks.each do |callback|
        safe_hook_call("SubagentStart") { callback.call(input, block.id, ctx) }
      end
    end

    private def handle_subagent_stop(hooks : HookConfig, message : AssistantMessage, block : ToolResultBlock)
      tool_name = find_tool_name_for_result(message, block.tool_use_id)
      return unless tool_name == "Task"
      return if control_hook_registered?("SubagentStop")
      callbacks = hooks.subagent_stop
      return unless callbacks

      result_content = case content = block.content
                       when String then content
                       when Array  then content.to_json
                       else             ""
                       end
      common = hook_common_fields("SubagentStop")
      input = HookInput.new(
        session_id: common[:session_id],
        cwd: common[:cwd],
        permission_mode: common[:permission_mode],
        hook_event_name: common[:hook_event_name],
        tool_name: "Task",
        tool_result: result_content,
      )
      ctx = HookContext.new(session_id: common[:session_id])
      callbacks.each do |callback|
        safe_hook_call("SubagentStop") { callback.call(input, block.tool_use_id, ctx) }
      end
    end

    # Trigger Stop hook when agent finishes
    private def trigger_stop_hook(result : ResultMessage)
      hooks = @options.try(&.hooks)
      return unless hooks
      return if control_hook_registered?("Stop")

      callbacks = hooks.stop
      return unless callbacks

      common = hook_common_fields("Stop")
      input = HookInput.new(
        session_id: common[:session_id],
        cwd: common[:cwd],
        permission_mode: common[:permission_mode],
        hook_event_name: common[:hook_event_name],
      )
      ctx = HookContext.new(session_id: common[:session_id])
      callbacks.each do |callback|
        safe_hook_call("Stop") { callback.call(input, result.uuid, ctx) }
      end
    end

    # --- Control Request Handling (SDK MCP Server Integration) ---

    # Handle incoming control request from CLI
    private def handle_control_request(request : ControlRequest)
      case req = request.request
      when ControlMCPMessageRequest
        handle_mcp_message_request(request.request_id, req)
      when ControlInitializeRequest
        handle_initialize_request(request.request_id, req)
      when ControlPermissionRequest
        handle_control_permission_request(request.request_id, req)
      when ControlElicitationRequest
        handle_control_elicitation_request(request.request_id, req)
      when ControlHookCallbackRequest
        handle_hook_callback_request(request.request_id, req)
      when ControlUnknownRequest
        # Always reply so the CLI's pending request resolves. Without this
        # reply the CLI would wait indefinitely for a response.
        send_control_error(
          request.request_id,
          "Unknown control request subtype: #{req.subtype}",
        )
      else
        send_control_error(request.request_id, "Unhandled control request subtype")
      end
    rescue ex
      send_control_error(request.request_id, ex.message || "Control request failed")
    end

    # Handle MCP message request (route to SDK MCP server)
    private def handle_mcp_message_request(request_id : String, req : ControlMCPMessageRequest)
      server_name = req.server_name
      message = req.message

      # Find the SDK server
      server = @cli_client.get_sdk_server(server_name)
      unless server
        send_control_error(request_id, "Unknown SDK MCP server: #{server_name}")
        return
      end

      # Route the JSON-RPC message to the server
      jsonrpc_response = server.handle_jsonrpc(message)

      # Build MCP response
      mcp_result = build_mcp_response(jsonrpc_response)
      response = ControlResponse.mcp_response(request_id, mcp_result)
      @cli_client.send_control_response(response)
    end

    # Build MCP response from JSON-RPC response
    private def build_mcp_response(response : JSONRPCResponse) : JSON::Any
      result = {} of String => JSON::Any
      result["jsonrpc"] = JSON::Any.new(response.jsonrpc)
      response.id.try { |id| result["id"] = id }
      response.result.try { |res| result["result"] = res }
      if err = response.error
        error_obj = {} of String => JSON::Any
        error_obj["code"] = JSON::Any.new(err.code.to_i64)
        error_obj["message"] = JSON::Any.new(err.message)
        # JSON-RPC 2.0 allows an optional `data` payload on errors. If a
        # SDK MCP tool raises with structured diagnostics, this keeps
        # them reachable to the caller instead of silently dropping them.
        err.data.try { |data| error_obj["data"] = data }
        result["error"] = JSON::Any.new(error_obj)
      end
      JSON::Any.new(result)
    end

    # Handle initialize request from CLI
    private def handle_initialize_request(request_id : String, req : ControlInitializeRequest)
      # CLI is acknowledging our SDK servers - respond with success
      response = ControlResponse.success(request_id)
      @cli_client.send_control_response(response)
    end

    # Handle permission request via control protocol
    private def handle_control_permission_request(request_id : String, req : ControlPermissionRequest)
      response_data = if callback = @options.try(&.can_use_tool)
                        context = PermissionContext.new(
                          tool_name: req.tool_name,
                          tool_input: req.input,
                          session_id: session_id || "unknown",
                          suggestions: parse_permission_suggestions(req.permission_suggestions),
                          tool_use_id: req.tool_use_id,
                          agent_id: req.agent_id,
                          blocked_path: req.blocked_path,
                          decision_reason: req.decision_reason,
                          title: req.title,
                          display_name: req.display_name,
                          description: req.description,
                        )
                        permission_result_to_response(callback.call(context), req.input)
                      else
                        {
                          "behavior"     => JSON::Any.new("allow"),
                          "updatedInput" => JSON::Any.new(req.input),
                        }
                      end

      response = ControlResponse.success(request_id, JSON::Any.new(response_data))
      @cli_client.send_control_response(response)
    end

    private def handle_control_elicitation_request(request_id : String, req : ControlElicitationRequest)
      response_data = if callback = @options.try(&.on_elicitation)
                        elicitation_response_to_json(
                          callback.call(
                            ElicitationRequest.new(
                              server_name: req.mcp_server_name,
                              message: req.message,
                              mode: req.mode,
                              url: req.url,
                              elicitation_id: req.elicitation_id,
                              requested_schema: req.requested_schema,
                            )
                          )
                        )
                      else
                        elicitation_response_to_json(ElicitationResponse.decline)
                      end

      response = ControlResponse.success(request_id, JSON::Any.new(response_data))
      @cli_client.send_control_response(response)
    end

    # Handle hook callback request from CLI (e.g. PreCompact)
    private def handle_hook_callback_request(request_id : String, req : ControlHookCallbackRequest)
      registration = @registered_hook_callbacks[req.callback_id]?
      raise Error.new("No hook callback found for ID: #{req.callback_id}") unless registration

      input = build_hook_input(req.input, registration.hook_name)
      ctx = HookContext.new(session_id: input.session_id || "unknown", cwd: input.cwd)
      result = registration.callback.call(input, req.tool_use_id || input.tool_use_id || request_id, ctx)

      response = ControlResponse.success(request_id, JSON::Any.new(hook_result_to_response(result)))
      @cli_client.send_control_response(response)
    end

    # Send control error response
    private def send_control_error(request_id : String, error_message : String)
      response = ControlResponse.error(request_id, error_message)
      @cli_client.send_control_response(response)
    end

    private def extract_any(input : Hash(String, JSON::Any)?, *keys : String) : JSON::Any?
      return nil unless input

      keys.each do |key|
        if value = input[key]?
          return value
        end
      end

      nil
    end

    # Extract a string field from a hash
    private def extract_string(input : Hash(String, JSON::Any)?, *keys : String) : String?
      extract_any(input, *keys).try(&.as_s?)
    end

    # Extract a bool field from a hash
    private def extract_bool(input : Hash(String, JSON::Any)?, *keys : String) : Bool?
      extract_any(input, *keys).try(&.as_bool?)
    end

    private def extract_array(input : Hash(String, JSON::Any)?, *keys : String) : Array(JSON::Any)?
      extract_any(input, *keys).try(&.as_a?)
    end

    private def extract_hash(input : Hash(String, JSON::Any)?, *keys : String) : Hash(String, JSON::Any)?
      extract_any(input, *keys).try(&.as_h?)
    end

    private def normalize_hook_name(hook_name : String) : String
      HOOK_NAME_ALIASES[hook_name]? || hook_name
    end

    # Build base HookInput with common context fields populated
    private def build_base_hook_input(input_data : Hash(String, JSON::Any)?, hook_name : String) : HookInput
      common = hook_common_fields(hook_name)

      HookInput.new(
        session_id: extract_string(input_data, "session_id", "sessionId") || common[:session_id],
        transcript_path: extract_string(input_data, "transcript_path", "transcriptPath"),
        cwd: extract_string(input_data, "cwd") || common[:cwd],
        permission_mode: extract_string(input_data, "permission_mode", "permissionMode") || common[:permission_mode],
        hook_event_name: extract_string(input_data, "hook_event_name", "hookEventName") || common[:hook_event_name],
      )
    end

    # Build HookInput with appropriate fields based on hook type
    # ameba:disable Metrics/CyclomaticComplexity
    private def build_hook_input(input_data : Hash(String, JSON::Any)?, hook_name : String) : HookInput
      input = build_base_hook_input(input_data, hook_name)
      normalized_hook_name = normalize_hook_name(input.hook_event_name || hook_name)

      case normalized_hook_name
      when "notification"
        input = apply_notification_fields(input, input_data)
      when "pre_compact"
        input = apply_pre_compact_fields(input, input_data)
      when "stop"
        input.stop_hook_active = extract_bool(input_data, "stop_hook_active", "stopHookActive")
      when "session_start"
        input.source = extract_string(input_data, "source")
      when "session_end"
        input.session_end_reason = extract_string(input_data, "reason", "session_end_reason", "sessionEndReason")
      when "subagent_start"
        input = apply_subagent_fields(input, input_data)
      when "subagent_stop"
        input = apply_subagent_fields(input, input_data)
        input.stop_hook_active = extract_bool(input_data, "stop_hook_active", "stopHookActive")
      when "pre_tool_use", "post_tool_use", "post_tool_use_failure"
        input = apply_tool_fields(input, input_data)
      when "permission_request"
        input = apply_tool_fields(input, input_data)
        input.permission_suggestions = extract_array(input_data, "permission_suggestions", "permissionSuggestions")
      when "elicitation"
        input = apply_elicitation_fields(input, input_data)
      when "elicitation_result"
        input = apply_elicitation_fields(input, input_data)
        input.elicitation_action = extract_string(input_data, "action")
        input.elicitation_content = extract_hash(input_data, "content")
      when "task_completed"
        input.task_id = extract_string(input_data, "task_id", "taskId")
        input.task_status = extract_string(input_data, "status")
        input.task_summary = extract_string(input_data, "summary")
        input.tool_use_id = extract_string(input_data, "tool_use_id", "toolUseId")
      when "teammate_idle"
        input.agent_id = extract_string(input_data, "agent_id", "agentId")
        input.agent_type = extract_string(input_data, "agent_type", "agentType")
      when "config_change"
        input.config_change_source = extract_string(input_data, "source", "changeSource")
        input.config_change_diff = extract_hash(input_data, "diff", "change")
      end

      input
    end

    # ameba:enable Metrics/CyclomaticComplexity

    private def apply_notification_fields(input : HookInput, input_data : Hash(String, JSON::Any)?) : HookInput
      input.notification_message = extract_string(input_data, "message")
      input.notification_title = extract_string(input_data, "title")
      input.notification_type = extract_string(input_data, "notification_type", "notificationType")
      input
    end

    private def apply_pre_compact_fields(input : HookInput, input_data : Hash(String, JSON::Any)?) : HookInput
      input.trigger = extract_string(input_data, "trigger")
      input.custom_instructions = extract_string(input_data, "custom_instructions", "customInstructions")
      input
    end

    private def apply_subagent_fields(input : HookInput, input_data : Hash(String, JSON::Any)?) : HookInput
      input.agent_id = extract_string(input_data, "agent_id", "agentId")
      input.agent_type = extract_string(input_data, "agent_type", "agentType")
      input.agent_transcript_path = extract_string(input_data, "agent_transcript_path", "agentTranscriptPath")
      input
    end

    private def apply_tool_fields(input : HookInput, input_data : Hash(String, JSON::Any)?) : HookInput
      input.tool_name = extract_string(input_data, "tool_name", "toolName")
      input.tool_input = extract_hash(input_data, "tool_input", "toolInput")
      input.tool_use_id = extract_string(input_data, "tool_use_id", "toolUseId")
      input.tool_result = extract_string(input_data, "tool_result", "toolResult") ||
                          extract_string(input_data, "tool_response", "toolResponse")
      input.tool_response = extract_string(input_data, "tool_response", "toolResponse") ||
                            extract_string(input_data, "tool_result", "toolResult")
      input.error = extract_string(input_data, "error")
      input.is_interrupt = extract_bool(input_data, "is_interrupt", "isInterrupt")
      input
    end

    private def apply_elicitation_fields(input : HookInput, input_data : Hash(String, JSON::Any)?) : HookInput
      input.mcp_server_name = extract_string(input_data, "mcp_server_name", "mcpServerName")
      input.elicitation_message = extract_string(input_data, "message")
      input.elicitation_mode = extract_string(input_data, "mode")
      input.elicitation_url = extract_string(input_data, "url")
      input.elicitation_id = extract_string(input_data, "elicitation_id", "elicitationId")
      input.requested_schema = extract_hash(input_data, "requested_schema", "requestedSchema")
      input
    end

    private def permission_result_to_response(
      result : PermissionResult,
      original_input : Hash(String, JSON::Any),
    ) : Hash(String, JSON::Any)
      if result.allow?
        response = {
          "behavior"     => JSON::Any.new("allow"),
          "updatedInput" => JSON::Any.new(result.updated_input || original_input),
        }

        if updates = result.updated_permissions
          response["updatedPermissions"] = JSON::Any.new(
            updates.map { |update| permission_update_to_json_any(update) }
          )
        end

        response
      else
        response = {
          "behavior" => JSON::Any.new("deny"),
        }
        result.reason.try { |reason| response["message"] = JSON::Any.new(reason) }
        response["interrupt"] = JSON::Any.new(true) if result.interrupt?
        response
      end
    end

    private def parse_permission_suggestions(
      suggestions : Array(JSON::Any)?,
    ) : Array(PermissionSuggestion)?
      return nil unless suggestions

      parsed = suggestions.compact_map do |suggestion_any|
        suggestion = suggestion_any.as_h?
        next unless suggestion

        update_data = suggestion["update"]?.try(&.as_h?)
        update = update_data.try { |value| parse_permission_update(value) }
        next unless update

        PermissionSuggestion.new(
          update: update,
          description: suggestion["description"]?.try(&.as_s?),
        )
      end

      parsed.empty? ? nil : parsed
    end

    # ameba:disable Metrics/CyclomaticComplexity
    private def parse_permission_update(data : Hash(String, JSON::Any)) : PermissionUpdate?
      case data["type"]?.try(&.as_s?)
      when "addRules"
        AddRulesUpdate.new(
          rules: parse_permission_rules(data["rules"]?.try(&.as_a?) || [] of JSON::Any),
          behavior: parse_permission_behavior(data["behavior"]?.try(&.as_s?)),
          destination: parse_permission_destination(data["destination"]?.try(&.as_s?)),
        )
      when "replaceRules"
        ReplaceRulesUpdate.new(
          rules: parse_permission_rules(data["rules"]?.try(&.as_a?) || [] of JSON::Any),
          behavior: parse_permission_behavior(data["behavior"]?.try(&.as_s?)),
          destination: parse_permission_destination(data["destination"]?.try(&.as_s?)),
        )
      when "removeRules"
        RemoveRulesUpdate.new(
          rules: parse_permission_rules(data["rules"]?.try(&.as_a?) || [] of JSON::Any),
          behavior: parse_permission_behavior(data["behavior"]?.try(&.as_s?)),
          destination: parse_permission_destination(data["destination"]?.try(&.as_s?)),
        )
      when "setMode"
        mode = parse_permission_mode(data["mode"]?.try(&.as_s?))
        return nil unless mode

        SetModeUpdate.new(
          mode: mode,
          destination: parse_permission_destination(data["destination"]?.try(&.as_s?)),
        )
      when "addDirectories"
        AddDirectoriesUpdate.new(
          directories: parse_string_array(data["directories"]?.try(&.as_a?) || [] of JSON::Any),
          destination: parse_permission_destination(data["destination"]?.try(&.as_s?)),
        )
      when "removeDirectories"
        RemoveDirectoriesUpdate.new(
          directories: parse_string_array(data["directories"]?.try(&.as_a?) || [] of JSON::Any),
          destination: parse_permission_destination(data["destination"]?.try(&.as_s?)),
        )
      end
    end

    # ameba:enable Metrics/CyclomaticComplexity

    private def parse_permission_rules(values : Array(JSON::Any)) : Array(PermissionRuleValue)
      values.compact_map do |value|
        rule = value.as_h?
        next unless rule

        pattern = rule["pattern"]?.try(&.as_s?)
        next unless pattern

        PermissionRuleValue.new(pattern, rule["description"]?.try(&.as_s?))
      end
    end

    private def parse_string_array(values : Array(JSON::Any)) : Array(String)
      values.compact_map(&.as_s?)
    end

    private def parse_permission_behavior(value : String?) : PermissionRuleBehavior
      case value
      when "deny" then PermissionRuleBehavior::Deny
      when "ask"  then PermissionRuleBehavior::Ask
      else             PermissionRuleBehavior::Allow
      end
    end

    private def parse_permission_destination(value : String?) : PermissionUpdateDestination
      case value
      when "userSettings"    then PermissionUpdateDestination::UserSettings
      when "projectSettings" then PermissionUpdateDestination::ProjectSettings
      when "localSettings"   then PermissionUpdateDestination::LocalSettings
      else                        PermissionUpdateDestination::Session
      end
    end

    private def parse_permission_mode(value : String?) : PermissionMode?
      case value
      when "default"           then PermissionMode::Default
      when "acceptEdits"       then PermissionMode::AcceptEdits
      when "plan"              then PermissionMode::Plan
      when "bypassPermissions" then PermissionMode::BypassPermissions
      when "auto"              then PermissionMode::Auto
      when "dontAsk"           then PermissionMode::DontAsk
      end
    end

    private def permission_update_to_json_any(update : PermissionUpdate) : JSON::Any
      data = case update
             when AddRulesUpdate
               {
                 "type"        => JSON::Any.new("addRules"),
                 "rules"       => JSON::Any.new(update.rules.map { |rule| permission_rule_to_json_any(rule) }),
                 "behavior"    => JSON::Any.new(permission_behavior_value(update.behavior)),
                 "destination" => JSON::Any.new(permission_destination_value(update.destination)),
               }
             when ReplaceRulesUpdate
               {
                 "type"        => JSON::Any.new("replaceRules"),
                 "rules"       => JSON::Any.new(update.rules.map { |rule| permission_rule_to_json_any(rule) }),
                 "behavior"    => JSON::Any.new(permission_behavior_value(update.behavior)),
                 "destination" => JSON::Any.new(permission_destination_value(update.destination)),
               }
             when RemoveRulesUpdate
               {
                 "type"        => JSON::Any.new("removeRules"),
                 "rules"       => JSON::Any.new(update.rules.map { |rule| permission_rule_to_json_any(rule) }),
                 "behavior"    => JSON::Any.new(permission_behavior_value(update.behavior)),
                 "destination" => JSON::Any.new(permission_destination_value(update.destination)),
               }
             when SetModeUpdate
               {
                 "type"        => JSON::Any.new("setMode"),
                 "mode"        => JSON::Any.new(permission_mode_value(update.mode)),
                 "destination" => JSON::Any.new(permission_destination_value(update.destination)),
               }
             when AddDirectoriesUpdate
               {
                 "type"        => JSON::Any.new("addDirectories"),
                 "directories" => JSON::Any.new(update.directories.map { |directory| JSON::Any.new(directory) }),
                 "destination" => JSON::Any.new(permission_destination_value(update.destination)),
               }
             when RemoveDirectoriesUpdate
               {
                 "type"        => JSON::Any.new("removeDirectories"),
                 "directories" => JSON::Any.new(update.directories.map { |directory| JSON::Any.new(directory) }),
                 "destination" => JSON::Any.new(permission_destination_value(update.destination)),
               }
             else
               {} of String => JSON::Any
             end

      JSON::Any.new(data)
    end

    private def permission_rule_to_json_any(rule : PermissionRuleValue) : JSON::Any
      data = {
        "pattern" => JSON::Any.new(rule.pattern),
      }
      rule.description.try { |description| data["description"] = JSON::Any.new(description) }
      JSON::Any.new(data)
    end

    private def permission_behavior_value(behavior : PermissionRuleBehavior) : String
      case behavior
      when PermissionRuleBehavior::Allow then "allow"
      when PermissionRuleBehavior::Deny  then "deny"
      when PermissionRuleBehavior::Ask   then "ask"
      else                                    "allow"
      end
    end

    private def permission_destination_value(destination : PermissionUpdateDestination) : String
      case destination
      when PermissionUpdateDestination::UserSettings    then "userSettings"
      when PermissionUpdateDestination::ProjectSettings then "projectSettings"
      when PermissionUpdateDestination::LocalSettings   then "localSettings"
      when PermissionUpdateDestination::Session         then "session"
      else                                                   "session"
      end
    end

    private def hook_result_to_response(result : HookResult) : Hash(String, JSON::Any)
      response = {
        "continue"       => JSON::Any.new(result.continue?),
        "suppressOutput" => JSON::Any.new(result.suppress_output?),
      }

      result.decision.try { |decision| response["decision"] = JSON::Any.new(decision) }
      result.system_message.try { |message| response["systemMessage"] = JSON::Any.new(message) }
      result.reason.try { |reason| response["reason"] = JSON::Any.new(reason) }

      if hook_specific_output = result.hook_specific_output
        response["hookSpecificOutput"] = JSON::Any.new(
          hook_specific_output_to_response(hook_specific_output)
        )
      end

      response
    end

    private def hook_specific_output_to_response(output : HookSpecificOutput) : Hash(String, JSON::Any)
      response = {
        "hookEventName" => JSON::Any.new(output.hook_event_name),
      }

      output.permission_decision.try do |value|
        response["permissionDecision"] = JSON::Any.new(value)
      end
      output.permission_decision_reason.try do |value|
        response["permissionDecisionReason"] = JSON::Any.new(value)
      end
      output.decision.try { |value| response["decision"] = JSON::Any.new(value) }
      output.updated_input.try { |value| response["updatedInput"] = JSON::Any.new(value) }
      output.additional_context.try do |value|
        response["additionalContext"] = JSON::Any.new(value)
      end
      output.updated_tool_output.try do |value|
        response["updatedToolOutput"] = value
      end
      output.updated_mcp_tool_output.try do |value|
        response["updatedMCPToolOutput"] = value
      end
      output.action.try { |value| response["action"] = JSON::Any.new(value) }
      output.content.try { |value| response["content"] = JSON::Any.new(value) }

      response
    end

    private def elicitation_response_to_json(result : ElicitationResponse) : Hash(String, JSON::Any)
      response = {
        "action" => JSON::Any.new(result.action),
      }

      result.content.try { |value| response["content"] = JSON::Any.new(value) }
      response
    end
  end
end
