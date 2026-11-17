require "set"
require "uuid"
require "./cli_client"
require "./hooks"
require "./types/control_messages"

module ClaudeAgent
  # Sentinel distinguishing an omitted optional parameter from an explicit `nil`
  # (e.g. `AgentClient#set_max_thinking_tokens`).
  struct Omitted
  end

  OMITTED = Omitted.new

  class AgentClient
    {% if compare_versions(Crystal::VERSION, "1.12.0") >= 0 %}
      private alias MonotonicTimestamp = Time::Instant
    {% else %}
      private alias MonotonicTimestamp = Time::Span
    {% end %}

    private alias ControlRequestResult = Hash(String, JSON::Any) | Exception
    private INITIALIZE_TIMEOUT             = 90.seconds
    private MAX_INITIALIZE_STARTUP_TIMEOUT = 10.minutes
    private DEFAULT_RUN_END_CEILING_MS     =       600_000_i64
    private MAX_RUN_END_CEILING_MS         = 2_147_483_647_i64
    private RUN_END_CEILING_ENV            = "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS"

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
      "MessageDisplay"        => "message_display",
      "message_display"       => "message_display",
      "DirectoryAdded"        => "directory_added",
      "directory_added"       => "directory_added",
      "PostToolBatch"         => "post_tool_batch",
      "post_tool_batch"       => "post_tool_batch",
      "UserPromptExpansion"   => "user_prompt_expansion",
      "user_prompt_expansion" => "user_prompt_expansion",
      "StopFailure"           => "stop_failure",
      "stop_failure"          => "stop_failure",
      "PostCompact"           => "post_compact",
      "post_compact"          => "post_compact",
      "PreModelSwitch"        => "pre_model_switch",
      "pre_model_switch"      => "pre_model_switch",
      "PostModelSwitch"       => "post_model_switch",
      "post_model_switch"     => "post_model_switch",
      "PermissionDenied"      => "permission_denied",
      "permission_denied"     => "permission_denied",
      "Setup"                 => "setup",
      "setup"                 => "setup",
      "TaskCreated"           => "task_created",
      "task_created"          => "task_created",
      "WorktreeCreate"        => "worktree_create",
      "worktree_create"       => "worktree_create",
      "WorktreeRemove"        => "worktree_remove",
      "worktree_remove"       => "worktree_remove",
      "InstructionsLoaded"    => "instructions_loaded",
      "instructions_loaded"   => "instructions_loaded",
      "CwdChanged"            => "cwd_changed",
      "cwd_changed"           => "cwd_changed",
      "FileChanged"           => "file_changed",
      "file_changed"          => "file_changed",
    }

    # Task types whose completion can wake a follow-up turn. Matches the
    # Python SDK's DEFERRING_TASK_TYPES.
    private DEFERRING_TASK_TYPES = Set{"local_agent", "local_workflow"}

    # Known permission mode wire values accepted by set_permission_mode.
    # `"manual"` is an alias for `"default"` (TS 0.3.200 / 0.3.214).
    private KNOWN_PERMISSION_MODE_STRINGS = Set{
      "default", "manual", "acceptEdits", "plan",
      "bypassPermissions", "auto", "dontAsk",
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
    # Original tool inputs for suppress'ed can_use_tool requests, keyed by
    # control request_id. Used by `respond_to_permission` when building the
    # allow payload (updatedInput defaults to the original input).
    @pending_permission_inputs : Hash(String, Hash(String, JSON::Any))
    @hook_callback_counter : Int64 = 0
    @request_counter : Int64 = 0
    @interrupted : Bool = false
    @sdk_init_sent : Bool = false
    @started : Bool = false
    @server_info : ServerInfo? = nil
    @state_mutex : Mutex = Mutex.new
    # Task IDs of started-but-not-finished delegated agent work. A result
    # frame only ends one turn — background tasks keep running past it and
    # may still emit messages / need control responses (Py 0.2.127 / #1088).
    # Only `local_agent` / `local_workflow` types are tracked; background
    # shells can run forever and would withhold end-of-turn forever.
    @inflight_tasks : Set(String) = Set(String).new
    # SessionStore live transcript mirror (nil when no session_store option).
    @mirror_batcher : TranscriptMirrorBatcher? = nil
    @materialized_resume : MaterializedResume? = nil
    # Most recent terminal error result (`is_error: true`), if the latest
    # turn marker is one. Read by `connection_closed_error` so pending
    # control requests (e.g. `initialize` during a refused resume) fail
    # with the CLI's actual error text. Cleared by any later message —
    # a new turn marker means the conversation moved on. Written and
    # read only on the response-reader fiber. Mirrors Python's
    # `Query._last_error_result` (0.2.140).
    @last_error_result : ResultMessage? = nil
    @session_state : String? = nil
    @result_received : Bool = false
    @turn_in_progress : Bool = false
    @ceiling_deadline : MonotonicTimestamp? = nil
    @init_keepalive_channel : Channel(Nil)? = nil

    def initialize(@options : AgentOptions? = nil, cli_client : CLIClient? = nil)
      @cli_client = cli_client || CLIClient.new(@options)
      @message_channel = Channel(Message).new(100)
      @pending_control_requests = {} of String => Channel(ControlRequestResult)
      @control_request_mutex = Mutex.new
      @registered_hook_callbacks = {} of String => HookCallbackRegistration
      @registered_control_hook_events = Set(String).new
      @pending_permission_inputs = {} of String => Hash(String, JSON::Any)
    end

    # Get the current session ID
    def session_id : String?
      @cli_client.session_id
    end

    def started? : Bool
      @state_mutex.synchronize { @started }
    end

    def start
      prepare_session_store!
      # Same mutual-exclusion rule as the one-shot path (mirrors Python
      # `_configure_can_use_tool`, which both entry points share).
      @options.try(&.validate_can_use_tool!)
      validate_mcp_server_names!
      @cli_client.start
      setup_transcript_mirror
      @state_mutex.synchronize do
        @interrupted = false
        @started = true
      end
      start_response_reader
      begin
        send_sdk_initialization
      rescue ex
        @state_mutex.synchronize { @started = false }
        fail_pending_control_requests(ex)
        teardown_session_store
        @cli_client.stop
        @message_channel.close unless @message_channel.closed?
        raise ex
      end
      trigger_hook(:session_start)
    end

    # Send SDK MCP server initialization to CLI
    private def send_sdk_initialization
      return if @sdk_init_sent

      manifests = capture_sdk_server_manifests
      # Register hooks under the same mutex as reinitialize / hook lookups
      # so the response-reader fiber cannot race registry mutations.
      request, blocks_on_failure = @control_request_mutex.synchronize do
        build_initialize_request(manifests)
      end
      response = send_control_request(
        request,
        initialize_timeout,
        max_total_timeout: max_initialize_timeout,
      )
      validate_initialize_on_failure!(response, blocks_on_failure, check_hooks_applied: true)
      @server_info = response.empty? ? nil : ServerInfo.from_data(response)
      @sdk_init_sent = true
      replay_pending_requests(response)
    end

    # Re-send the initialize control request after a transport gap.
    # Redelivers hooks/agents/skills payload and lets the CLI redeliver
    # pending permission/dialog prompts (TS 0.3.195 `Query.reinitialize()`).
    # Clears prior hook callback registrations so newly advertised callback
    # IDs map cleanly onto this client's registry.
    #
    # Hook registry clear/rebuild is guarded by `@control_request_mutex` so
    # concurrent `handle_hook_callback_request` lookups cannot race the
    # rebuild. The mutex is released before waiting on the control response
    # to avoid deadlock with the response-reader fiber.
    def reinitialize : Hash(String, JSON::Any)
      raise ConnectionError.new("Not connected. Call start() first.") unless started?

      manifests = capture_sdk_server_manifests
      request, blocks_on_failure = @control_request_mutex.synchronize do
        @registered_hook_callbacks.clear
        @registered_control_hook_events.clear
        @hook_callback_counter = 0
        build_initialize_request(manifests)
      end

      response = send_control_request(
        request,
        initialize_timeout,
        max_total_timeout: max_initialize_timeout,
      )
      validate_initialize_on_failure!(response, blocks_on_failure, check_hooks_applied: false)
      @server_info = response.empty? ? nil : ServerInfo.from_data(response)
      @sdk_init_sent = true
      replay_pending_requests(response)
      response
    end

    protected def initialize_timeout : Time::Span
      INITIALIZE_TIMEOUT
    end

    protected def max_initialize_timeout : Time::Span
      MAX_INITIALIZE_STARTUP_TIMEOUT
    end

    private def build_initialize_request(
      manifests : Hash(String, JSON::Any)? = nil,
    ) : {Hash(String, JSON::Any), Bool}
      request = {} of String => JSON::Any
      request["subtype"] = JSON::Any.new("initialize")

      populate_initialize_mcp(request, manifests)
      blocks_on_failure = populate_initialize_hooks(request)
      populate_initialize_agents(request)
      populate_initialize_flags(request)
      populate_initialize_skills(request)
      populate_initialize_system_prompt(request)

      {request, blocks_on_failure}
    end

    private def validate_mcp_server_names! : Nil
      @options.try(&.mcp_servers).try(&.each_key { |name| ClaudeAgent.validate_mcp_server_name!(name) })
      @cli_client.sdk_server_names.each do |name|
        ClaudeAgent.validate_mcp_server_name!(name)
        @cli_client.get_sdk_server(name).try { |server| ClaudeAgent.validate_mcp_server_name!(server.name) }
      end
    end

    private def populate_initialize_mcp(
      request : Hash(String, JSON::Any),
      manifests : Hash(String, JSON::Any)? = nil,
    )
      validate_mcp_server_names!
      return unless @cli_client.has_sdk_servers?

      server_names = @cli_client.sdk_server_names
      request["sdkMcpServers"] = JSON::Any.new(
        server_names.map { |name| JSON::Any.new(name) }
      )

      configs = {} of String => JSON::Any
      server_names.each do |name|
        server = @cli_client.get_sdk_server(name)
        next unless server

        if cfg = build_sdk_server_config(server)
          configs[name] = JSON::Any.new(cfg)
        end
      end
      request["sdkMcpServerConfigs"] = JSON::Any.new(configs) unless configs.empty?

      resolved_manifests = manifests || capture_sdk_server_manifests
      request["sdkMcpServerManifests"] = JSON::Any.new(resolved_manifests) unless resolved_manifests.empty?
    end

    private def build_sdk_server_config(server : SDKMCPServer) : Hash(String, JSON::Any)?
      cfg = {} of String => JSON::Any
      server.timeout.try { |timeout| cfg["timeout"] = JSON::Any.new(timeout.to_i64) }
      server.tool_policies.try do |policies|
        cfg["tools"] = JSON::Any.new(build_tool_policies_json(policies))
      end
      cfg.empty? ? nil : cfg
    end

    private def build_tool_policies_json(policies : Array(MCPServerToolPolicy)) : Array(JSON::Any)
      policies.map do |policy|
        obj = {"name" => JSON::Any.new(policy.name)}
        policy.permission_policy.try { |perm| obj["permission_policy"] = JSON::Any.new(perm) }
        policy.org_max_permission.try { |org| obj["org_max_permission"] = JSON::Any.new(org) }
        JSON::Any.new(obj)
      end
    end

    private def capture_sdk_server_manifests : Hash(String, JSON::Any)
      manifests = {} of String => JSON::Any
      return manifests unless @cli_client.has_sdk_servers?

      @cli_client.sdk_server_names.each do |name|
        server = @cli_client.get_sdk_server(name)
        next unless server

        manifest = capture_sdk_server_manifest(server)
        manifests[name] = JSON::Any.new(manifest) unless manifest.empty?
      end
      manifests
    end

    private def capture_sdk_server_manifest(server : SDKMCPServer) : Hash(String, JSON::Any)
      done = Channel(Hash(String, JSON::Any)?).new(1)
      logger = ->(msg : String) { log_stderr("[claude-agent-cr] #{msg}\n") }

      spawn do
        result = server.build_manifest(logger)
        begin
          done.send(result) unless done.closed?
        rescue Channel::ClosedError
        end
      rescue ex
        log_stderr("[claude-agent-cr] SDK MCP manifest capture failed for #{server.name.inspect}: #{ex.message}\n")
        begin
          done.send(nil) unless done.closed?
        rescue Channel::ClosedError
        end
      end

      select
      when manifest = done.receive
        manifest || {} of String => JSON::Any
      when timeout(250.milliseconds)
        done.close
        log_stderr("[claude-agent-cr] SDK MCP manifest capture timed out for #{server.name.inspect}\n")
        {} of String => JSON::Any
      end
    end

    private def validate_initialize_on_failure!(
      response : Hash(String, JSON::Any),
      blocks_on_failure : Bool,
      *,
      check_hooks_applied : Bool,
    ) : Nil
      return unless blocks_on_failure

      unless response["hook_on_failure_supported"]?.try(&.as_bool?) == true
        raise ConnectionError.new(
          "The process answering initialize does not honor on_failure on hook matchers, " \
          "so a hook that fails would not block. Update Claude Code or remove on_failure=\"block\".",
        )
      end

      if check_hooks_applied && response["hooks_applied"]?.try(&.as_bool?) == false
        raise ConnectionError.new(
          "This session was already running and did not register your hooks, so a hook set to " \
          "on_failure=\"block\" would never run. Start a new session or remove on_failure=\"block\".",
        )
      end
    end

    private def replay_pending_requests(response : Hash(String, JSON::Any)) : Nil
      replay_pending_permission_requests(response["pending_permission_requests"]?.try(&.as_a?))
      replay_pending_elicitation_requests(response["pending_elicitation_requests"]?.try(&.as_a?))
    end

    private def replay_pending_permission_requests(entries : Array(JSON::Any)?) : Nil
      return unless entries

      entries.each do |entry|
        item = entry.as_h?
        next unless item

        req_id = item["request_id"]?.try(&.as_s?)
        next unless req_id

        inner = (item["request"]?.try(&.as_h?) || item).dup
        inner.delete("server_policy_ask_only")
        inner.delete("serverPolicyAskOnly")
        inner["subtype"] ||= JSON::Any.new("can_use_tool")

        begin
          perm_req = ControlPermissionRequest.from_json(inner.to_json)
          handle_control_permission_request(req_id, perm_req)
        rescue ex
          send_control_error(req_id, ex.message || "Failed to replay permission request")
        end
      end
    end

    private def replay_pending_elicitation_requests(entries : Array(JSON::Any)?) : Nil
      return unless entries

      entries.each do |entry|
        item = entry.as_h?
        next unless item

        req_id = item["request_id"]?.try(&.as_s?)
        next unless req_id

        inner = (item["request"]?.try(&.as_h?) || item).dup
        inner["subtype"] ||= JSON::Any.new("elicitation")

        begin
          elicit_req = ControlElicitationRequest.from_json(inner.to_json)
          handle_control_elicitation_request(req_id, elicit_req)
        rescue ex
          send_control_error(req_id, ex.message || "Failed to replay elicitation request")
        end
      end
    end

    private def populate_initialize_hooks(request : Hash(String, JSON::Any)) : Bool
      hooks_payload, blocks_on_failure = build_hook_initialize_payload
      if hooks_payload
        request["hooks"] = JSON::Any.new(hooks_payload)
      end
      blocks_on_failure
    end

    private def populate_initialize_agents(request : Hash(String, JSON::Any))
      if agents_payload = build_agents_initialize_payload
        request["agents"] = agents_payload
      end
    end

    private def populate_initialize_flags(request : Hash(String, JSON::Any))
      opts = @options
      return unless opts

      request["promptSuggestions"] = JSON::Any.new(true) if opts.prompt_suggestions?
      request["agentProgressSummaries"] = JSON::Any.new(true) if opts.agent_progress_summaries?

      # Stream subagent text/thinking blocks as assistant/user messages
      # with `parent_tool_use_id` set. Delivered via initialize (not argv),
      # matching the TS SDK's `forwardSubagentText` (0.2.119).
      request["forwardSubagentText"] = JSON::Any.new(true) if opts.forward_subagent_text?
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

    # `exclude_dynamic_sections` and `snapshot` on `SystemPromptPreset` /
    # `SystemPromptCustom` flow through the initialize request as
    # `excludeDynamicSections` and `systemPromptSnapshot`, not CLI flags.
    # `title` is also forwarded here so the CLI can apply it to the
    # session transcript without us waiting for `session_id` first.
    # Older CLIs silently ignore unknown initialize fields.
    private def populate_initialize_system_prompt(request : Hash(String, JSON::Any))
      case system_prompt = @options.try(&.system_prompt)
      when SystemPromptPreset
        if system_prompt.exclude_dynamic_sections?
          request["excludeDynamicSections"] = JSON::Any.new(true)
        end
        unless (snapshot = system_prompt.snapshot).nil?
          request["systemPromptSnapshot"] = JSON::Any.new(snapshot)
        end
      when SystemPromptCustom
        unless (snapshot = system_prompt.snapshot).nil?
          request["systemPromptSnapshot"] = JSON::Any.new(snapshot)
        end
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
      teardown_session_store
    end

    # Send a query and get responses
    def query(prompt : String, *, uuid : String? = nil, should_query : Bool = true)
      reset_turn_state_for_prompt
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

    # Interrupt a streaming query via the control protocol.
    #
    # Pass `cancel_queued: true` (capability `interrupt_cancel_queued_v1`) to
    # also cancel queued and pending-dispatch messages. The response may
    # include `still_queued` — UUIDs of queued async messages that will still
    # run (capability `interrupt_receipt_v1`, TS 0.3.205 / 0.3.219) — and
    # when cancelling, `cancelled` — UUIDs removed by this interrupt.
    def interrupt(*, cancel_queued : Bool = false) : InterruptReceipt
      @state_mutex.synchronize { @interrupted = true }

      request = {
        "subtype" => JSON::Any.new("interrupt"),
      }
      request["cancel_queued"] = JSON::Any.new(true) if cancel_queued

      response = send_control_request(request)
      InterruptReceipt.from_response(response)
    end

    # Seed the CLI's `readFileState` cache with path+mtime entries so `Edit`
    # works after the originating `Read` was removed from context
    # (TS `seed_read_state`, CLI 2.1.83+). Sends one control request per entry.
    def seed_read_state(entries : Array(ReadStateEntry))
      entries.each do |entry|
        send_control_request({
          "subtype" => JSON::Any.new("seed_read_state"),
          "path"    => JSON::Any.new(entry.path),
          "mtime"   => JSON::Any.new(entry.mtime),
        })
      end
    end

    # ameba:disable Naming/AccessorMethodName
    def set_permission_mode(mode : PermissionMode)
      set_permission_mode(permission_mode_value(mode))
    end

    # ameba:disable Naming/AccessorMethodName
    def set_permission_mode(mode : String)
      wire_mode = normalize_permission_mode_string(mode)
      send_control_request({
        "subtype" => JSON::Any.new("set_permission_mode"),
        "mode"    => JSON::Any.new(wire_mode),
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

    # Update the thinking token budget and/or thinking display mode mid-session.
    # Omitting `max_thinking_tokens` (leaving `OMITTED`) leaves the budget
    # unchanged; passing explicit `nil` sends `"max_thinking_tokens": null` to
    # reset to the session default. `thinking_display` accepts `"summarized"`,
    # `"omitted"`, or `"highlights"`.
    def set_max_thinking_tokens(
      max_thinking_tokens : Int32? | Omitted = OMITTED,
      *,
      thinking_display : String? = nil,
    ) : Hash(String, JSON::Any)
      request = {
        "subtype" => JSON::Any.new("set_max_thinking_tokens"),
      }
      unless max_thinking_tokens.is_a?(Omitted)
        request["max_thinking_tokens"] = max_thinking_tokens ? JSON::Any.new(max_thinking_tokens.to_i64) : JSON::Any.new(nil)
      end
      thinking_display.try { |display| request["thinking_display"] = JSON::Any.new(display) }
      send_control_request(request)
    end

    def get_mcp_status(*, live_reply : Bool? = nil) : MCPStatusResponse
      request = {
        "subtype" => JSON::Any.new("mcp_status"),
      }
      unless live_reply.nil?
        request["liveReply"] = JSON::Any.new(live_reply)
      end
      response = send_control_request(request)

      response = response.dup
      response["mcpServers"] ||= JSON::Any.new([] of JSON::Any)
      MCPStatusResponse.from_json(response.to_json)
    end

    # Retrieve a breakdown of context window usage by category.
    def get_context_usage(*, detail : String? = nil) : ContextUsageResponse
      request = {
        "subtype" => JSON::Any.new("get_context_usage"),
      }
      detail.try { |value| request["detail"] = JSON::Any.new(value) }
      response = send_control_request(request)

      ContextUsageResponse.from_json(response.to_json)
    end

    # Reload plugins and receive refreshed commands, agents, and MCP servers.
    # Returns the raw response payload (shape mirrors system/init).
    def reload_plugins(
      *,
      hold_on_cache_impact : Bool? = nil,
      add_plugins : (Array(PluginEntry) | Array(String) | Array(PluginConfig))? = nil,
      refuse_if_busy : Bool? = nil,
    ) : Hash(String, JSON::Any)
      request = {
        "subtype" => JSON::Any.new("reload_plugins"),
      }
      unless hold_on_cache_impact.nil?
        request["hold_on_cache_impact"] = JSON::Any.new(hold_on_cache_impact)
      end
      if plugins = add_plugins
        request["add_plugins"] = JSON::Any.new(serialize_reload_plugins(plugins))
      end
      unless refuse_if_busy.nil?
        request["refuse_if_busy"] = JSON::Any.new(refuse_if_busy)
      end
      send_control_request(request)
    end

    private def serialize_reload_plugins(
      plugins : Array(PluginEntry) | Array(String) | Array(PluginConfig),
    ) : Array(JSON::Any)
      plugins.map do |entry|
        case entry
        when String
          JSON::Any.new({
            "type" => JSON::Any.new("local"),
            "path" => JSON::Any.new(entry),
          })
        when PluginConfig
          JSON.parse(entry.to_json)
        else
          JSON::Any.new(nil)
        end
      end
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
    #
    # Optional `request_timeouts` merges a per-server `request_timeout_ms`
    # into each named entry (TS 0.3.198). Servers may also carry the field
    # directly in their config hash for full backward compatibility.
    def set_mcp_servers(
      mcp_servers : Hash(String, JSON::Any),
      *,
      request_timeouts : Hash(String, Int32)? = nil,
    )
      mcp_servers.each_key { |name| ClaudeAgent.validate_mcp_server_name!(name) }
      servers = merge_mcp_request_timeouts(mcp_servers, request_timeouts)
      send_control_request({
        "subtype" => JSON::Any.new("mcp_set_servers"),
        "servers" => JSON::Any.new(servers),
      })
    end

    # Replace the active MCP server configuration using typed `MCPServerConfig`
    # entries, updating the in-process SDK MCP server registry cleanly.
    def set_mcp_servers(
      servers : Hash(String, MCPServerConfig),
      *,
      request_timeouts : Hash(String, Int32)? = nil,
    )
      raise ConnectionError.new("Not connected. Call start() first.") unless started?

      sdk_servers, wire_servers = prepare_typed_mcp_servers(servers, request_timeouts)
      previous_servers = snapshot_sdk_servers

      @cli_client.replace_sdk_servers(sdk_servers)
      begin
        send_control_request({
          "subtype" => JSON::Any.new("mcp_set_servers"),
          "servers" => JSON::Any.new(wire_servers),
        })
      rescue ex
        @cli_client.replace_sdk_servers(previous_servers)
        raise ex
      end
    end

    def set_mcp_servers(
      servers : Hash(String, SDKMCPServer),
      *,
      request_timeouts : Hash(String, Int32)? = nil,
    )
      set_mcp_servers(
        servers.transform_values(&.as(MCPServerConfig)),
        request_timeouts: request_timeouts,
      )
    end

    def set_mcp_servers(
      servers : Hash(String, ExternalMCPServerConfig),
      *,
      request_timeouts : Hash(String, Int32)? = nil,
    )
      set_mcp_servers(
        servers.transform_values(&.as(MCPServerConfig)),
        request_timeouts: request_timeouts,
      )
    end

    private def snapshot_sdk_servers : Hash(String, SDKMCPServer)
      previous = {} of String => SDKMCPServer
      @cli_client.sdk_server_names.each do |name|
        if existing = @cli_client.get_sdk_server(name)
          previous[name] = existing
        end
      end
      previous
    end

    private def prepare_typed_mcp_servers(
      servers : Hash(String, MCPServerConfig),
      request_timeouts : Hash(String, Int32)?,
    ) : {Hash(String, SDKMCPServer), Hash(String, JSON::Any)}
      sdk_servers = {} of String => SDKMCPServer
      wire_servers = {} of String => JSON::Any

      servers.each do |name, config|
        ClaudeAgent.validate_mcp_server_name!(name)
        timeout_override = request_timeouts.try(&.[name]?)

        case config
        when SDKMCPServer
          ClaudeAgent.validate_mcp_server_name!(config.name)
          sdk_servers[name] = config
          wire_servers[name] = JSON::Any.new(sdk_server_wire_config(config, timeout_override))
        when ExternalMCPServerConfig
          wire_servers[name] = JSON::Any.new(external_server_wire_config(config, timeout_override))
        end
      end

      {sdk_servers, wire_servers}
    end

    private def sdk_server_wire_config(
      config : SDKMCPServer,
      timeout_override : Int32?,
    ) : Hash(String, JSON::Any)
      wire = {
        "type"    => JSON::Any.new("sdk"),
        "name"    => JSON::Any.new(config.name),
        "version" => JSON::Any.new(config.version),
      } of String => JSON::Any

      effective_timeout = timeout_override || config.timeout
      effective_timeout.try { |timeout| wire["timeout"] = JSON::Any.new(timeout.to_i64) }
      config.tool_policies.try do |policies|
        wire["tools"] = JSON::Any.new(build_tool_policies_json(policies))
      end
      wire
    end

    private def external_server_wire_config(
      config : ExternalMCPServerConfig,
      timeout_override : Int32?,
    ) : Hash(String, JSON::Any)
      wire = {} of String => JSON::Any
      config.type.try { |v| wire["type"] = JSON::Any.new(v) }
      config.command.try { |v| wire["command"] = JSON::Any.new(v) }
      config.args.try { |v| wire["args"] = JSON::Any.new(v.map { |arg| JSON::Any.new(arg) }) }
      config.url.try { |v| wire["url"] = JSON::Any.new(v) }

      if env = config.env
        wire["env"] = JSON::Any.new(env.transform_values { |v| JSON::Any.new(v) })
      end
      if headers = config.headers
        wire["headers"] = JSON::Any.new(headers.transform_values { |v| JSON::Any.new(v) })
      end

      effective_timeout = timeout_override || config.timeout
      effective_timeout.try { |timeout| wire["timeout"] = JSON::Any.new(timeout.to_i64) }
      config.always_load.try { |val| wire["alwaysLoad"] = JSON::Any.new(val) }
      config.tools.try { |policies| wire["tools"] = JSON::Any.new(build_tool_policies_json(policies)) }
      wire
    end

    private def merge_mcp_request_timeouts(
      mcp_servers : Hash(String, JSON::Any),
      request_timeouts : Hash(String, Int32)?,
    ) : Hash(String, JSON::Any)
      return mcp_servers unless request_timeouts

      merged = {} of String => JSON::Any
      mcp_servers.each do |name, config|
        if timeout = request_timeouts[name]?
          if entry = config.as_h?
            entry = entry.dup
            entry["request_timeout_ms"] = JSON::Any.new(timeout.to_i64)
            merged[name] = JSON::Any.new(entry)
          else
            merged[name] = config
          end
        else
          merged[name] = config
        end
      end
      merged
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

    # Rename the live session transcript via the control protocol.
    def rename_session(
      title : String,
      *,
      source : String = "host",
      session_id : String? = nil,
    ) : Hash(String, JSON::Any)
      request = {
        "subtype" => JSON::Any.new("rename_session"),
        "title"   => JSON::Any.new(title),
        "source"  => JSON::Any.new(source),
      }
      session_id.try { |id| request["session_id"] = JSON::Any.new(id) }
      send_control_request(request)
    end

    # ameba:enable Naming/AccessorMethodName

    # Rewind files to a checkpoint.
    # Requires enable_file_checkpointing: true and replay_user_messages: true.
    # Sends via the control protocol (matching the TypeScript SDK).
    #
    # Response may include `skippedLinks` (Int count of paths the rewind
    # safety guards refused to restore or delete; TS 0.3.x). Use
    # `rewind_files_skipped_links` to extract it.
    def rewind_files(user_message_id : String, *, dry_run : Bool = false) : Hash(String, JSON::Any)
      send_control_request({
        "subtype"         => JSON::Any.new("rewind_files"),
        "user_message_id" => JSON::Any.new(user_message_id),
        "dry_run"         => JSON::Any.new(dry_run),
      })
    end

    # Extract the optional `skippedLinks` count from a `rewind_files` response.
    def self.rewind_files_skipped_links(response : Hash(String, JSON::Any)) : Int32?
      response["skippedLinks"]?.try(&.as_i?)
    end

    # Rewind the conversation transcript to a previous user message and
    # establish a durable resume anchor there. A subsequent `resume` of the
    # returned session continues from the rewound point. Pass `dry_run: true`
    # to preview the would-be-rewound state without mutating the transcript.
    # Matches the TS SDK's `rewind_conversation` control request (0.3.186).
    def rewind_conversation(user_message_id : String, *, dry_run : Bool = false) : Hash(String, JSON::Any)
      send_control_request({
        "subtype"         => JSON::Any.new("rewind_conversation"),
        "user_message_id" => JSON::Any.new(user_message_id),
        "dry_run"         => JSON::Any.new(dry_run),
      })
    end

    # Iterate over incoming messages.
    #
    # A `ResultMessage` ends one turn, not necessarily the run: delegated
    # background tasks (`local_agent` / `local_workflow`) and CLI
    # `session_state_changed` transitions (`"running"` / `"requires_action"`)
    # can keep the run alive past it so follow-up turns still receive hook,
    # permission, and SDK-MCP responses. When `@session_state` is nil (older
    # CLIs), falls back to exiting after `ResultMessage` with empty
    # `@inflight_tasks`. Internal `sdk_host_only: true` frames are dropped
    # before reaching the caller.
    def each_response(&block : Message ->)
      reset_response_loop_state
      awaiting_prompt_suggestion = false

      loop do
        timed_out, message = next_response_message(awaiting_prompt_suggestion)
        if timed_out
          if has_inflight_tasks?
            clear_run_end_ceiling
            next
          end
          break
        end
        break unless message
        next if handle_internal_message(message)

        process_stream_message(message)

        unless message.sdk_host_only_frame?
          run_message_hooks(message)
          block.call(message)
        end

        if should_end_run?
          if @options.try(&.prompt_suggestions?) && !awaiting_prompt_suggestion
            awaiting_prompt_suggestion = true
            next
          end
          break
        end
      end
    end

    # Send a follow-up message. Pass `should_query: false` to append the
    # message to the transcript without triggering an assistant turn.
    def send_user_message(content : String, *, uuid : String? = nil, should_query : Bool = true)
      reset_turn_state_for_prompt
      trigger_hook(:user_prompt_submit, content) if should_query
      @cli_client.send_user_message(content, uuid: uuid, should_query: should_query)
    end

    # Send permission response (legacy stream-message path).
    def grant_permission(tool_use_id : String, allow : Bool, reason : String? = nil)
      message = Hash(String, String | Bool?).new
      message["type"] = "permission_response"
      message["tool_use_id"] = tool_use_id
      message["allow"] = allow
      message["reason"] = reason if reason
      @cli_client.send_json(message)
    end

    # Reply out-of-band to a `can_use_tool` control request whose callback
    # returned `PermissionResult.suppress`. Pair with
    # `PermissionContext#request_id` from the callback.
    #
    # Builds the allow/deny payload via the same path as the automatic
    # control handler. When allowing, original tool input is taken from the
    # pending map (stored at suppress time), else `result.updated_input`,
    # else an empty hash.
    def respond_to_permission(request_id : String, result : PermissionResult)
      raise ConnectionError.new("Not connected. Call start() first.") unless started?

      original_input = @control_request_mutex.synchronize do
        @pending_permission_inputs.delete(request_id)
      end
      original_input ||= result.updated_input || {} of String => JSON::Any

      response_data = permission_result_to_response(result, original_input)
      response = ControlResponse.success(request_id, JSON::Any.new(response_data))
      @cli_client.send_control_response(response)
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
        @cli_client.each_message do |message|
          next if @message_channel.closed?
          next if handle_reader_control_message(message)

          record_reader_message_state(message)
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

    private def handle_reader_control_message(message : Message) : Bool
      case message
      when ControlResponseMessage
        handle_control_response(message)
        true
      when UnknownMessage
        case message.type
        when "keep_alive"
          handle_keep_alive(message)
          true
        when "transcript_mirror"
          handle_transcript_mirror(message)
          true
        else
          false
        end
      else
        false
      end
    end

    private def record_reader_message_state(message : Message) : Nil
      if message.is_a?(ResultMessage)
        @mirror_batcher.try(&.flush)
        @last_error_result = message.is_error == true ? message : nil
      elsif !message.is_a?(SessionStateChangedMessage)
        @last_error_result = nil
      end
    end

    private def handle_keep_alive(message : UnknownMessage) : Nil
      mark = message.data["startup_mark"]? || message.data["startupMark"]?
      return unless mark
      return if mark.raw.nil? || mark.raw == false

      channel = @control_request_mutex.synchronize { @init_keepalive_channel }
      return unless channel

      select
      when channel.send(nil)
      else
      end
    rescue Channel::ClosedError
    end

    # Validate session_store options and materialize resume/continue from the
    # store into a temp CLAUDE_CONFIG_DIR when needed. AgentOptions is a struct,
    # so materialization returns a new options value that we push into both
    # AgentClient and CLIClient before spawn.
    private def prepare_session_store! : Nil
      opts = @options
      return unless opts

      ClaudeAgent.validate_session_store_options!(opts)
      return unless opts.session_store

      if materialized = ClaudeAgent.materialize_resume_session(opts)
        updated = ClaudeAgent.apply_materialized_options(opts, materialized)
        @options = updated
        @cli_client.replace_options(updated)
        @materialized_resume = materialized
      end
    end

    private def setup_transcript_mirror : Nil
      opts = @options
      store = opts.try(&.session_store)
      return unless opts && store

      projects_dir = ClaudeAgent.effective_projects_dir(opts.env)
      @mirror_batcher = ClaudeAgent.build_mirror_batcher(
        store,
        projects_dir: projects_dir,
        flush_mode: opts.session_store_flush,
        on_error: ->(key : SessionKey?, error : String) {
          report_mirror_error(key, error)
        },
      )
    end

    private def teardown_session_store : Nil
      @mirror_batcher.try(&.close)
      @mirror_batcher = nil
      @materialized_resume.try(&.cleanup)
      @materialized_resume = nil
    end

    private def handle_transcript_mirror(message : UnknownMessage) : Nil
      batcher = @mirror_batcher
      return unless batcher

      data = message.data
      file_path = data["filePath"]?.try(&.as_s?) || data["file_path"]?.try(&.as_s?)
      return unless file_path

      raw_entries = data["entries"]?.try(&.as_a?)
      return unless raw_entries

      entries = raw_entries.compact_map do |value|
        hash = value.as_h?
        next unless hash
        begin
          SessionStoreEntry.from_hash(hash)
        rescue
          nil
        end
      end
      return if entries.empty?

      batcher.enqueue(file_path, entries)
    end

    # Surface a SessionStore.append failure as a mirror_error message for
    # consumers (at-most-once; the dropped batch is not retried further).
    private def report_mirror_error(key : SessionKey?, error : String) : Nil
      return if @message_channel.closed?

      session_id = key.try(&.session_id) || ""
      data = {
        "type"       => JSON::Any.new("mirror_error"),
        "subtype"    => JSON::Any.new("mirror_error"),
        "error"      => JSON::Any.new(error),
        "session_id" => JSON::Any.new(session_id),
        "uuid"       => JSON::Any.new(UUID.random.to_s),
      } of String => JSON::Any
      if key
        key_hash = {
          "project_key" => JSON::Any.new(key.project_key),
          "session_id"  => JSON::Any.new(key.session_id),
        } of String => JSON::Any
        if sub = key.subpath
          key_hash["subpath"] = JSON::Any.new(sub)
        end
        data["key"] = JSON::Any.new(key_hash)
      end

      msg = MirrorErrorMessage.new(
        data["uuid"].as_s?,
        session_id,
        error,
        data,
      )
      begin
        @message_channel.send(msg)
      rescue Channel::ClosedError
      end
    end

    # Translate an abrupt subprocess exit into a more actionable error.
    # Prefers the structured `ResultError` when the CLI emitted a terminal
    # error result first (e.g. a refused resume — so a pending
    # `initialize` sees the actual error text instead of a generic
    # "exit code 1"), then the unknown-option diagnostic (a signature of
    # forwarding an SDK-only flag to an older CLI), then a generic
    # ConnectionError. Mirrors Python's `Query._read_messages` error
    # replacement (0.2.140).
    private def connection_closed_error : ClaudeAgent::Error
      if failed = @last_error_result
        return ResultError.from_result(failed)
      end
      if flag = @cli_client.detect_unknown_option_error
        UnsupportedOptionError.new(flag, cli_path: @options.try(&.cli_path))
      else
        ConnectionError.new("Agent client connection closed")
      end
    end

    private def permission_mode_value(mode : PermissionMode) : String
      mode.to_cli_value
    end

    # Normalize a permission-mode string for the control wire.
    # Accepts `"manual"` as an alias for `"default"`; rejects unrecognized
    # modes with a clear error instead of silently forwarding them
    # (TS 0.3.200 / 0.3.214).
    private def normalize_permission_mode_string(mode : String) : String
      unless KNOWN_PERMISSION_MODE_STRINGS.includes?(mode)
        raise Error.new(
          "Unrecognized permission mode: #{mode.inspect}. " \
          "Expected one of: default, manual, acceptEdits, plan, " \
          "bypassPermissions, auto, dontAsk"
        )
      end

      mode == "manual" ? "default" : mode
    end

    private def monotonic_now : MonotonicTimestamp
      {% if compare_versions(Crystal::VERSION, "1.12.0") >= 0 %}
        Time.instant
      {% else %}
        Time.monotonic
      {% end %}
    end

    private def reset_response_loop_state : Nil
      @state_mutex.synchronize do
        @result_received = false
        @turn_in_progress = false
        @ceiling_deadline = nil
      end
    end

    private def reset_turn_state_for_prompt : Nil
      @state_mutex.synchronize do
        @result_received = false
        @ceiling_deadline = nil
      end
    end

    private def next_response_message(awaiting_prompt_suggestion : Bool) : {Bool, Message?}
      return {false, receive_post_result_message} if awaiting_prompt_suggestion

      loop do
        deadline = @state_mutex.synchronize { @ceiling_deadline }
        return {false, @message_channel.receive?} unless deadline

        remaining = deadline - monotonic_now
        if remaining <= Time::Span::ZERO
          still_armed = @state_mutex.synchronize { !@ceiling_deadline.nil? && @result_received }
          return {true, nil} if still_armed
          next
        end

        select
        when msg = @message_channel.receive?
          return {false, msg}
        when timeout(remaining)
          still_armed = @state_mutex.synchronize { !@ceiling_deadline.nil? && @result_received }
          return {true, nil} if still_armed
        end
      end
    end

    private def process_stream_message(message : Message) : Nil
      had_tasks = has_inflight_tasks?
      track_task_lifecycle(message)
      rearm_run_end_ceiling_between_turns if had_tasks && !has_inflight_tasks?

      case message
      when SessionStateChangedMessage
        on_session_state(message.state)
      when ResultMessage
        @state_mutex.synchronize do
          @result_received = true
          @turn_in_progress = false
        end
        if !should_end_run? && @session_state != "requires_action"
          arm_run_end_ceiling
        end
      else
        if top_level_turn_activity?(message)
          @state_mutex.synchronize { @turn_in_progress = true }
          clear_run_end_ceiling
        end
      end
    end

    private def on_session_state(state : String) : Nil
      @session_state = state
      if state == "idle" || state == "requires_action"
        clear_run_end_ceiling
      else
        rearm_run_end_ceiling_between_turns
      end
    end

    private def should_end_run? : Bool
      return false unless @state_mutex.synchronize { @result_received }
      return false if has_inflight_tasks?

      state = @session_state
      state.nil? || state == "idle"
    end

    private def top_level_turn_activity?(message : Message) : Bool
      case message
      when AssistantMessage
        message.parent_tool_use_id.nil?
      when StreamEvent
        message.parent_tool_use_id.nil?
      else
        false
      end
    end

    private def run_end_ceiling_ms : Int64
      opts_env = @options.try(&.env)
      raw = if opts_env && opts_env.has_key?(RUN_END_CEILING_ENV)
              opts_env[RUN_END_CEILING_ENV]
            else
              ENV[RUN_END_CEILING_ENV]?
            end
      return DEFAULT_RUN_END_CEILING_MS unless raw

      stripped = raw.strip
      return DEFAULT_RUN_END_CEILING_MS unless stripped.matches?(/\A[+-]?\d+\z/)

      value = stripped.to_i64?
      return DEFAULT_RUN_END_CEILING_MS unless value && value >= 0

      value
    end

    private def arm_run_end_ceiling : Nil
      ceiling_ms = run_end_ceiling_ms
      if ceiling_ms <= 0
        clear_run_end_ceiling
        return
      end

      clamped = Math.min(ceiling_ms, MAX_RUN_END_CEILING_MS)
      @state_mutex.synchronize do
        return if @turn_in_progress

        @ceiling_deadline = monotonic_now + clamped.milliseconds
      end
    end

    private def rearm_run_end_ceiling_between_turns : Nil
      result_seen = @state_mutex.synchronize { @result_received && !@turn_in_progress }
      return unless result_seen

      state = @session_state
      return if state.nil? || state == "idle" || state == "requires_action"

      arm_run_end_ceiling
    end

    private def clear_run_end_ceiling : Nil
      @state_mutex.synchronize { @ceiling_deadline = nil }
    end

    private def receive_post_result_message : Message?
      select
      when message = @message_channel.receive?
        message
      when timeout(2.seconds)
        nil
      end
    end

    private def has_inflight_tasks? : Bool
      !@inflight_tasks.empty?
    end

    # Track delegated agent task lifecycle so `each_response` can tell
    # "one turn ended" apart from "the run is idle". Only
    # DEFERRING_TASK_TYPES are tracked — background shells may never
    # reach a terminal status and would withhold end-of-turn forever.
    private def track_task_lifecycle(message : Message)
      case message
      when TaskStartedMessage
        if task_type = message.task_type
          @inflight_tasks.add(message.task_id) if DEFERRING_TASK_TYPES.includes?(task_type)
        end
      when TaskNotificationMessage
        @inflight_tasks.delete(message.task_id)
      when TaskUpdatedMessage
        @inflight_tasks.delete(message.task_id) if message.terminal?
      end
    end

    private def handle_internal_message(message : Message) : Bool
      case message
      when ControlRequest
        handle_control_request(message)
        true
      when ControlResponseMessage
        true
      when UnknownMessage
        message.type == "keep_alive"
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
      *,
      max_total_timeout : Time::Span? = nil,
    ) : Hash(String, JSON::Any)
      raise ConnectionError.new("Not connected. Call start() first.") unless started?

      response_channel = Channel(ControlRequestResult).new(1)
      request_id = register_pending_control_request(response_channel)
      subtype = request["subtype"]?.try(&.as_s?) || "unknown"
      keepalive_channel = setup_init_keepalive(subtype)

      control_request = {
        "type"       => JSON::Any.new("control_request"),
        "request_id" => JSON::Any.new(request_id),
        "request"    => JSON::Any.new(request),
      }

      @cli_client.send_message(control_request)

      begin
        await_control_response(
          response_channel,
          request_id,
          request,
          subtype,
          timeout,
          max_total_timeout,
          keepalive_channel,
        )
      ensure
        clear_init_keepalive(keepalive_channel) if keepalive_channel
      end
    end

    private def setup_init_keepalive(subtype : String) : Channel(Nil)?
      return unless subtype == "initialize"

      channel = Channel(Nil).new(16)
      @control_request_mutex.synchronize { @init_keepalive_channel = channel }
      channel
    end

    private def clear_init_keepalive(channel : Channel(Nil)) : Nil
      @control_request_mutex.synchronize do
        @init_keepalive_channel = nil if @init_keepalive_channel == channel
      end
      channel.close unless channel.closed?
    end

    private def await_control_response(
      response_channel : Channel(ControlRequestResult),
      request_id : String,
      request : Hash(String, JSON::Any),
      subtype : String,
      timeout : Time::Span,
      max_total_timeout : Time::Span?,
      keepalive_channel : Channel(Nil)?,
    ) : Hash(String, JSON::Any)
      unless keepalive_channel
        select
        when result = response_channel.receive
          return unwrap_control_result(result, request)
        when timeout(timeout)
          unregister_pending_control_request(request_id)
          raise TimeoutError.new("Control request timeout: #{subtype}")
        end
      end

      started_at = monotonic_now
      max_deadline = max_total_timeout ? (started_at + max_total_timeout) : nil
      deadline = started_at + timeout

      loop do
        remaining = deadline - monotonic_now
        if remaining <= Time::Span::ZERO
          unregister_pending_control_request(request_id)
          raise TimeoutError.new("Control request timeout: #{subtype}")
        end

        select
        when result = response_channel.receive
          return unwrap_control_result(result, request)
        when keepalive_channel.receive?
          next_deadline = monotonic_now + timeout
          deadline = if max_dl = max_deadline
                       next_deadline < max_dl ? next_deadline : max_dl
                     else
                       next_deadline
                     end
        when timeout(remaining)
          unregister_pending_control_request(request_id)
          raise TimeoutError.new("Control request timeout: #{subtype}")
        end
      end
    end

    private def unwrap_control_result(
      result : ControlRequestResult,
      request : Hash(String, JSON::Any),
    ) : Hash(String, JSON::Any)
      case result
      when Exception
        raise result
      when Hash(String, JSON::Any)
        parse_control_response(result, request)
      else
        {} of String => JSON::Any
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
        if error_code = response["error_code"]?.try(&.as_s?)
          raise ControlError.new(message, error_code)
        end
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
        deliver_control_failure(channel, error)
      end
    end

    # Deliver one pending-control failure, ignoring receivers that
    # already went away. A closed channel must not abort delivery to
    # the remaining waiters.
    private def deliver_control_failure(
      channel : Channel(ControlRequestResult),
      error : Exception,
    ) : Nil
      channel.send(error)
    rescue Channel::ClosedError
    end

    private def build_hook_initialize_payload : {Hash(String, JSON::Any)?, Bool}
      hooks = @options.try(&.hooks)
      return {nil, false} unless hooks

      payload = {} of String => JSON::Any
      blocks_on_failure = false

      each_hook_entry(hooks) do |hook_name, entries|
        blocks = add_hook_entries_payload(payload, hook_name, entries)
        blocks_on_failure ||= blocks
      end

      {payload.empty? ? nil : payload, blocks_on_failure}
    end

    private def each_hook_entry(hooks : HookConfig, & : String, HookEntryList? ->) : Nil
      yield "PreToolUse", hooks.pre_tool_use
      yield "PostToolUse", hooks.post_tool_use
      yield "PostToolUseFailure", hooks.post_tool_use_failure
      yield "PermissionRequest", hooks.permission_request
      yield "Elicitation", hooks.elicitation
      yield "ElicitationResult", hooks.elicitation_result
      yield "UserPromptSubmit", hooks.user_prompt_submit
      yield "Stop", hooks.stop
      yield "SubagentStart", hooks.subagent_start
      yield "SubagentStop", hooks.subagent_stop
      yield "PreCompact", hooks.pre_compact
      yield "SessionStart", hooks.session_start
      yield "SessionEnd", hooks.session_end
      yield "Notification", hooks.notification
      yield "TeammateIdle", hooks.teammate_idle
      yield "TaskCompleted", hooks.task_completed
      yield "ConfigChange", hooks.config_change
      yield "MessageDisplay", hooks.message_display
      yield "DirectoryAdded", hooks.directory_added
      each_extended_hook_entry(hooks) { |name, entries| yield name, entries }
    end

    private def each_extended_hook_entry(hooks : HookConfig, & : String, HookEntryList? ->) : Nil
      yield "PostToolBatch", hooks.post_tool_batch
      yield "UserPromptExpansion", hooks.user_prompt_expansion
      yield "StopFailure", hooks.stop_failure
      yield "PostCompact", hooks.post_compact
      yield "PreModelSwitch", hooks.pre_model_switch
      yield "PostModelSwitch", hooks.post_model_switch
      yield "PermissionDenied", hooks.permission_denied
      yield "Setup", hooks.setup
      yield "TaskCreated", hooks.task_created
      yield "WorktreeCreate", hooks.worktree_create
      yield "WorktreeRemove", hooks.worktree_remove
      yield "InstructionsLoaded", hooks.instructions_loaded
      yield "CwdChanged", hooks.cwd_changed
      yield "FileChanged", hooks.file_changed
    end

    private def add_hook_entries_payload(
      payload : Hash(String, JSON::Any),
      hook_name : String,
      entries : HookEntryList?,
    ) : Bool
      return false unless entries

      case entries
      when Array(HookMatcher)
        add_matcher_hook_payload(payload, hook_name, entries)
      when Array(HookCallback)
        add_simple_hook_payload(payload, hook_name, entries)
        false
      else
        false
      end
    end

    private def add_matcher_hook_payload(
      payload : Hash(String, JSON::Any),
      hook_name : String,
      matchers : Array(HookMatcher)?,
    ) : Bool
      return false unless matchers

      blocks_on_failure = false
      entries = matchers.compact_map do |matcher|
        callback_ids = register_hook_callbacks(hook_name, matcher.hooks)
        next if callback_ids.empty?

        entry = {} of String => JSON::Any
        if matcher_value = matcher.matcher
          entry["matcher"] = JSON::Any.new(matcher_value)
        end
        matcher.timeout.try { |timeout| entry["timeout"] = JSON::Any.new(timeout) }
        if on_failure = matcher.on_failure
          entry["onFailure"] = JSON::Any.new(on_failure)
          blocks_on_failure ||= on_failure != "continue"
        end
        entry["hookCallbackIds"] = JSON::Any.new(callback_ids.map { |id| JSON::Any.new(id) })
        JSON::Any.new(entry)
      end

      return false if entries.empty?

      payload[hook_name] = JSON::Any.new(entries)
      # Caller (build_initialize_request via reinitialize/start) owns locking
      # for registry mutations; start path is also single-writer until the
      # initialize response is processed.
      @registered_control_hook_events.add(hook_name)
      blocks_on_failure
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

    private def extract_callbacks(entries : HookEntryList?) : Array(HookCallback)
      return [] of HookCallback unless entries

      case entries
      when Array(HookCallback)
        entries
      when Array(HookMatcher)
        entries.flat_map(&.hooks)
      else
        [] of HookCallback
      end
    end

    # Must be called while holding `@control_request_mutex` during reinitialize
    # rebuild; safe on the single-threaded start init path before concurrent
    # hook callbacks arrive (reader is spawned but hooks are registered before
    # the CLI typically issues callbacks).
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
      @control_request_mutex.synchronize do
        @registered_control_hook_events.includes?(hook_name)
      end
    end

    private def build_agents_initialize_payload : JSON::Any?
      agents = @options.try(&.agents)
      return unless agents

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
      return if control_hook_registered?(event_name)

      entries = case event
                when :session_start      then hooks.session_start
                when :session_end        then hooks.session_end
                when :user_prompt_submit then hooks.user_prompt_submit
                end

      callbacks = extract_callbacks(entries)
      return if callbacks.empty?

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

    private def log_stderr(message : String) : Nil
      if stderr_cb = @options.try(&.stderr)
        stderr_cb.call(message)
      else
        STDERR.puts(message)
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
      log_stderr("[hook error] #{event_name}: #{ex.class}: #{ex.message}\n")
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
        # Suppress is for the control-protocol can_use_tool path where a
        # request_id exists for OOB reply. Legacy PermissionRequest messages
        # have no request_id — treat suppress as a defer no-op (do not
        # grant and do not deny) rather than auto-denying via allow=false.
        return if result.suppress_response?

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

      message.content.each do |block|
        next unless block.is_a?(ToolResultBlock)
        invoke_post_tool_use_hooks(hooks, message, block)
      end
    end

    private def invoke_post_tool_use_hooks(
      hooks : HookConfig,
      message : AssistantMessage,
      block : ToolResultBlock,
    )
      tool_name = find_tool_name_for_result(message, block.tool_use_id)
      return unless tool_name

      is_error = block.is_error == true
      hook_event = is_error ? "PostToolUseFailure" : "PostToolUse"
      return if control_hook_registered?(hook_event)

      hook_matchers = is_error ? hooks.post_tool_use_failure : hooks.post_tool_use
      return unless hook_matchers

      input = build_post_tool_use_hook_input(message, block, tool_name, is_error, hook_event)
      session_id = input.session_id || ""
      ctx = HookContext.new(session_id: session_id)

      hook_matchers.each do |hook_matcher|
        next unless hook_matcher.matches?(tool_name)
        hook_matcher.hooks.each do |callback|
          safe_hook_call("PostToolUse") { callback.call(input, block.tool_use_id, ctx) }
        end
      end
    end

    private def build_post_tool_use_hook_input(
      message : AssistantMessage,
      block : ToolResultBlock,
      tool_name : String,
      is_error : Bool,
      hook_event : String,
    ) : HookInput
      result_content = tool_result_content_string(block.content)
      common = hook_common_fields(hook_event)
      HookInput.new(
        session_id: common[:session_id],
        cwd: common[:cwd],
        permission_mode: common[:permission_mode],
        hook_event_name: common[:hook_event_name],
        tool_name: tool_name,
        tool_input: find_tool_input_for_result(message, block.tool_use_id),
        tool_use_id: block.tool_use_id,
        tool_result: result_content,
        tool_response: result_content,
        error: is_error ? result_content : nil,
      )
    end

    private def tool_result_content_string(content) : String
      case content
      when String then content
      when Array  then content.to_json
      else             ""
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
      callbacks = extract_callbacks(hooks.subagent_start)
      return if callbacks.empty?

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
      callbacks = extract_callbacks(hooks.subagent_stop)
      return if callbacks.empty?

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

      callbacks = extract_callbacks(hooks.stop)
      return if callbacks.empty?

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
                          request_id: request_id,
                          mcp_server: req.mcp_server,
                          decision_reason_type: req.decision_reason_type,
                          decision_reason_code: req.decision_reason_code,
                          server_policy_ask_only: req.server_policy_ask_only,
                          classifier_approvable: req.classifier_approvable,
                          suppress_always_allow_rule: req.suppress_always_allow_rule,
                          default_to_no: req.default_to_no,
                          matched_ask_rule: req.matched_ask_rule,
                          requires_user_interaction: req.requires_user_interaction,
                          server_prompt: req.server_prompt,
                        )
                        result = callback.call(context)
                        # Returning suppress (TS canUseTool → null) means the
                        # caller will respond out-of-band using request_id via
                        # `respond_to_permission`. Stash original input for
                        # allow payloads that omit updated_input.
                        if result.suppress_response?
                          @control_request_mutex.synchronize do
                            @pending_permission_inputs[request_id] = req.input
                          end
                          return
                        end
                        permission_result_to_response(result, req.input)
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
                              property_order: req.property_order,
                              title: req.title,
                              display_name: req.display_name,
                              description: req.description,
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
      registration = @control_request_mutex.synchronize do
        @registered_hook_callbacks[req.callback_id]?
      end
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
      return unless input

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

    private def extract_int64(input : Hash(String, JSON::Any)?, *keys : String) : Int64?
      extract_any(input, *keys).try(&.as_i64?)
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
        prompt_id: extract_string(input_data, "prompt_id", "promptId"),
        effort: extract_hook_effort(input_data),
      )
    end

    private def extract_hook_effort(input_data : Hash(String, JSON::Any)?) : HookEffort?
      effort_hash = extract_hash(input_data, "effort")
      return unless effort_hash

      level = effort_hash["level"]?.try(&.as_s?)
      return unless level

      HookEffort.new(level)
    end

    private def extract_mcp_server_provenance(input_data : Hash(String, JSON::Any)?) : MCPServerProvenance?
      server_hash = extract_hash(input_data, "mcp_server", "mcpServer")
      return unless server_hash

      name = server_hash["name"]?.try(&.as_s?)
      source = server_hash["source"]?.try(&.as_s?)
      return unless name && source

      MCPServerProvenance.new(name, source)
    end

    private def extract_background_tasks(input_data : Hash(String, JSON::Any)?) : Array(BackgroundTaskSummary)?
      entries = extract_array(input_data, "background_tasks", "backgroundTasks")
      return unless entries

      entries.compact_map do |item|
        hash = item.as_h?
        next unless hash

        id = hash["id"]?.try(&.as_s?)
        type = hash["type"]?.try(&.as_s?)
        status = hash["status"]?.try(&.as_s?)
        description = hash["description"]?.try(&.as_s?)
        next unless id && type && status && description

        BackgroundTaskSummary.new(
          id: id,
          type: type,
          status: status,
          description: description,
          command: hash["command"]?.try(&.as_s?),
          agent_type: hash["agent_type"]?.try(&.as_s?) || hash["agentType"]?.try(&.as_s?),
          server: hash["server"]?.try(&.as_s?),
          tool: hash["tool"]?.try(&.as_s?),
          name: hash["name"]?.try(&.as_s?),
        )
      end
    end

    private def extract_session_crons(input_data : Hash(String, JSON::Any)?) : Array(SessionCronSummary)?
      entries = extract_array(input_data, "session_crons", "sessionCrons")
      return unless entries

      entries.compact_map do |item|
        hash = item.as_h?
        next unless hash

        id = hash["id"]?.try(&.as_s?)
        schedule = hash["schedule"]?.try(&.as_s?)
        recurring = hash["recurring"]?.try(&.as_bool?)
        prompt = hash["prompt"]?.try(&.as_s?)
        next if recurring.nil?
        next unless id && schedule && prompt

        SessionCronSummary.new(id: id, schedule: schedule, recurring: recurring, prompt: prompt)
      end
    end

    # Build HookInput with appropriate fields based on hook type
    private def build_hook_input(input_data : Hash(String, JSON::Any)?, hook_name : String) : HookInput
      input = build_base_hook_input(input_data, hook_name)
      normalized = normalize_hook_name(input.hook_event_name || hook_name)
      apply_primary_hook_fields(input, input_data, normalized)
    end

    private def apply_primary_hook_fields(
      input : HookInput,
      input_data : Hash(String, JSON::Any)?,
      normalized : String,
    ) : HookInput
      case normalized
      when "pre_tool_use", "post_tool_use", "post_tool_use_failure", "post_tool_batch"
        apply_tool_fields(input, input_data)
      when "permission_request"
        apply_tool_fields(input, input_data)
        input.permission_suggestions = extract_array(input_data, "permission_suggestions", "permissionSuggestions")
        input
      when "permission_denied"
        apply_tool_fields(input, input_data)
        input.error ||= extract_string(input_data, "reason")
        input
      when "stop"
        apply_stop_fields(input, input_data)
      when "subagent_start"
        apply_subagent_fields(input, input_data)
      when "subagent_stop"
        apply_subagent_fields(input, input_data)
        apply_stop_fields(input, input_data)
      when "user_prompt_submit", "user_prompt_expansion"
        input.user_prompt = extract_string(input_data, "prompt", "user_prompt", "userPrompt")
        input
      else
        apply_secondary_hook_fields(input, input_data, normalized)
      end
    end

    private def apply_secondary_hook_fields(
      input : HookInput,
      input_data : Hash(String, JSON::Any)?,
      normalized : String,
    ) : HookInput
      case normalized
      when "notification"
        apply_notification_fields(input, input_data)
      when "pre_compact", "post_compact"
        apply_pre_compact_fields(input, input_data)
      when "session_start", "setup"
        input.source = extract_string(input_data, "source", "trigger")
        input
      when "session_end"
        input.session_end_reason = extract_string(input_data, "reason", "session_end_reason", "sessionEndReason")
        input
      when "elicitation"
        apply_elicitation_fields(input, input_data)
      when "elicitation_result"
        apply_elicitation_fields(input, input_data)
        input.elicitation_action = extract_string(input_data, "action")
        input.elicitation_content = extract_hash(input_data, "content")
        input
      when "task_completed", "task_created"
        apply_task_fields(input, input_data)
      else
        apply_misc_hook_fields(input, input_data, normalized)
      end
    end

    private def apply_misc_hook_fields(
      input : HookInput,
      input_data : Hash(String, JSON::Any)?,
      normalized : String,
    ) : HookInput
      case normalized
      when "teammate_idle"
        input.agent_id = extract_string(input_data, "agent_id", "agentId")
        input.agent_type = extract_string(input_data, "agent_type", "agentType")
      when "config_change"
        input.config_change_source = extract_string(input_data, "source", "changeSource")
        input.config_change_diff = extract_hash(input_data, "diff", "change")
      when "message_display"
        input.message_content = extract_string(input_data, "message_content", "messageContent", "content")
      when "directory_added", "cwd_changed", "file_changed", "worktree_create", "worktree_remove", "instructions_loaded"
        input.directory_path = extract_string(
          input_data,
          "path",
          "directory",
          "directory_path",
          "directoryPath",
          "worktree_path",
          "worktreePath",
          "file_path",
          "filePath",
        )
      when "stop_failure"
        input.error = extract_string(input_data, "error", "error_details", "errorDetails")
        input.last_assistant_message = extract_string(input_data, "last_assistant_message", "lastAssistantMessage")
      end
      input
    end

    private def apply_stop_fields(input : HookInput, input_data : Hash(String, JSON::Any)?) : HookInput
      input.stop_hook_active = extract_bool(input_data, "stop_hook_active", "stopHookActive")
      input.last_assistant_message = extract_string(input_data, "last_assistant_message", "lastAssistantMessage")
      input.background_tasks = extract_background_tasks(input_data)
      input.session_crons = extract_session_crons(input_data)
      input
    end

    private def apply_task_fields(input : HookInput, input_data : Hash(String, JSON::Any)?) : HookInput
      input.task_id = extract_string(input_data, "task_id", "taskId")
      input.task_status = extract_string(input_data, "status")
      input.task_summary = extract_string(input_data, "summary")
      input.tool_use_id = extract_string(input_data, "tool_use_id", "toolUseId")
      input
    end

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
      input.duration_ms = extract_int64(input_data, "duration_ms", "durationMs")
      input.mcp_server = extract_mcp_server_provenance(input_data)
      input.agent_id ||= extract_string(input_data, "agent_id", "agentId")
      input.agent_type ||= extract_string(input_data, "agent_type", "agentType")
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
      return unless suggestions

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
        return unless mode

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
      when "default", "manual" then PermissionMode::Default
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

      output.permission_decision.try { |v| response["permissionDecision"] = JSON::Any.new(v) }
      output.permission_decision_reason.try { |v| response["permissionDecisionReason"] = JSON::Any.new(v) }
      output.decision.try { |v| response["decision"] = JSON::Any.new(v) }
      output.updated_input.try { |v| response["updatedInput"] = JSON::Any.new(v) }
      output.additional_context.try { |v| response["additionalContext"] = JSON::Any.new(v) }
      output.updated_tool_output.try { |v| response["updatedToolOutput"] = v }
      output.updated_mcp_tool_output.try { |v| response["updatedMCPToolOutput"] = v }
      output.action.try { |v| response["action"] = JSON::Any.new(v) }
      output.content.try { |v| response["content"] = JSON::Any.new(v) }
      output.display_content.try { |v| response["displayContent"] = JSON::Any.new(v) }
      output.classifier_context.try { |v| response["classifierContext"] = JSON::Any.new(v) }
      output.suppress_original_prompt.try { |v| response["suppressOriginalPrompt"] = JSON::Any.new(v) }
      output.session_title.try { |v| response["sessionTitle"] = JSON::Any.new(v) }
      output.initial_user_message.try { |v| response["initialUserMessage"] = JSON::Any.new(v) }
      output.watch_paths.try do |paths|
        response["watchPaths"] = JSON::Any.new(paths.map { |path| JSON::Any.new(path) })
      end
      output.reload_skills.try { |v| response["reloadSkills"] = JSON::Any.new(v) }
      output.retry.try { |v| response["retry"] = JSON::Any.new(v) }
      output.worktree_path.try { |v| response["worktreePath"] = JSON::Any.new(v) }

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
