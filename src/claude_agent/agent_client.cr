require "./cli_client"
require "./hooks"
require "./types/control_messages"

module ClaudeAgent
  class AgentClient
    @cli_client : CLIClient
    @message_channel : Channel(Message)
    @response_fiber : Fiber?
    @interrupted : Bool = false
    @sdk_init_sent : Bool = false

    def initialize(@options : AgentOptions? = nil)
      @cli_client = CLIClient.new(@options)
      @message_channel = Channel(Message).new(100)
    end

    # Get the current session ID
    def session_id : String?
      @cli_client.session_id
    end

    def start
      @cli_client.start
      @interrupted = false
      trigger_hook(:session_start)
      start_response_reader
      # Send SDK MCP server initialization if configured
      send_sdk_initialization
    end

    # Send SDK MCP server initialization to CLI
    private def send_sdk_initialization
      return if @sdk_init_sent
      return unless @cli_client.has_sdk_servers?

      @cli_client.send_sdk_init
      @sdk_init_sent = true
    end

    def stop
      trigger_hook(:session_end)
      @cli_client.stop
      @message_channel.close
    end

    # Send a query and get responses
    def query(prompt : String)
      trigger_hook(:user_prompt_submit, prompt)
      @cli_client.send_prompt(prompt)
    end

    # Interrupt a streaming query
    def interrupt
      return if @interrupted
      @interrupted = true

      # Send interrupt message to CLI
      @cli_client.send_message({
        "type" => "interrupt",
      })
    end

    # Rewind files to a checkpoint
    # Requires enable_file_checkpointing: true and replay_user_messages: true
    def rewind_files(user_message_uuid : String)
      @cli_client.send_message({
        "type"              => "rewind_files",
        "user_message_uuid" => user_message_uuid,
      })
    end

    # Iterate over incoming messages
    def each_response(&block : Message ->)
      loop do
        message = @message_channel.receive?
        break unless message

        # Handle control requests from CLI (SDK MCP server routing)
        if message.is_a?(ControlRequest)
          handle_control_request(message)
          next # Control requests are internal, don't pass to user
        end

        # Ignore control responses (acknowledgments of our requests)
        if message.is_a?(ControlResponseMessage)
          next # Control responses are internal, don't pass to user
        end

        # Handle permissions/hooks
        if message.is_a?(PermissionRequest)
          handle_permission_request(message)
        end

        # Trigger PostToolUse hooks when we see tool results in AssistantMessage
        if message.is_a?(AssistantMessage)
          handle_post_tool_use_hooks(message)
          handle_subagent_hooks(message)
        end

        # Trigger Stop hook when we receive ResultMessage
        if message.is_a?(ResultMessage)
          trigger_stop_hook(message)
        end

        block.call(message)

        break if message.is_a?(ResultMessage)
      end
    end

    # Send a follow-up message
    def send_user_message(content : String)
      trigger_hook(:user_prompt_submit, content)
      @cli_client.send_message({
        "type"    => "user",
        "message" => {"role" => "user", "content" => content},
      })
    end

    # Send permission response
    def grant_permission(tool_use_id : String, allow : Bool, reason : String? = nil)
      @cli_client.send_message({
        "type"        => "permission_response",
        "tool_use_id" => tool_use_id,
        "allow"       => allow,
        "reason"      => reason,
      })
    end

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
            break if @message_channel.closed?
            @message_channel.send(message)
          end
        rescue ex
          # Log or handle
        ensure
          @message_channel.close unless @message_channel.closed?
        end
      end
    end

    # Common context fields for all hook inputs
    private def hook_common_fields(hook_event_name : String)
      {
        session_id:      session_id || "unknown",
        cwd:             @options.try(&.cwd),
        permission_mode: @options.try(&.permission_mode).try(&.to_s),
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
        callback.call(input, "", ctx)
      end
    end

    private def handle_permission_request(request : PermissionRequest)
      all_hooks = @options.try(&.hooks)

      # 1. Run PreToolUse hooks
      if hooks = all_hooks.try(&.pre_tool_use)
        hooks.each do |hook_matcher|
          if hook_matcher.matches?(request.tool_name)
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

            hook_matcher.hooks.each do |callback|
              res = callback.call(input, request.tool_use_id, ctx)

              # If any hook denies, we deny and return (short-circuit)
              if output = res.hook_specific_output
                if output.permission_decision == "deny"
                  grant_permission(request.tool_use_id, false, output.permission_decision_reason)
                  return
                end
              end
            end
          end
        end
      end

      # 2. Run PermissionRequest hooks
      if hooks = all_hooks.try(&.permission_request)
        hooks.each do |hook_matcher|
          if hook_matcher.matches?(request.tool_name)
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
            hook_matcher.hooks.each(&.call(input, request.tool_use_id, ctx))
          end
        end
      end

      # 3. Run User Callback if present
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
            callback.call(input, block.tool_use_id, ctx)
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
      callbacks.each(&.call(input, block.id, ctx))
    end

    private def handle_subagent_stop(hooks : HookConfig, message : AssistantMessage, block : ToolResultBlock)
      tool_name = find_tool_name_for_result(message, block.tool_use_id)
      return unless tool_name == "Task"
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
      callbacks.each(&.call(input, block.tool_use_id, ctx))
    end

    # Trigger Stop hook when agent finishes
    private def trigger_stop_hook(result : ResultMessage)
      hooks = @options.try(&.hooks)
      return unless hooks

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
      callbacks.each(&.call(input, result.uuid, ctx))
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
      when ControlHookCallbackRequest
        handle_hook_callback_request(request.request_id, req)
      else
        # Unknown control request subtype - send error response
        send_control_error(request.request_id, "Unknown control request subtype")
      end
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
        result["error"] = JSON::Any.new({
          "code"    => JSON::Any.new(err.code.to_i64),
          "message" => JSON::Any.new(err.message),
        })
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
      # Route to permission callback if configured
      if callback = @options.try(&.can_use_tool)
        context = PermissionContext.new(
          tool_name: req.tool_name,
          tool_input: req.input,
          session_id: session_id || "unknown"
        )
        result = callback.call(context)

        # Build response
        behavior = result.allow? ? "allow" : "deny"
        response_data = {
          "behavior" => JSON::Any.new(behavior),
        }
        result.reason.try { |reason| response_data["reason"] = JSON::Any.new(reason) }

        response = ControlResponse.success(request_id, JSON::Any.new(response_data))
        @cli_client.send_control_response(response)
      else
        # No callback - default to allow
        response = ControlResponse.success(request_id, JSON::Any.new({
          "behavior" => JSON::Any.new("allow"),
        }))
        @cli_client.send_control_response(response)
      end
    end

    # Handle hook callback request from CLI (e.g. PreCompact)
    private def handle_hook_callback_request(request_id : String, req : ControlHookCallbackRequest)
      hooks = @options.try(&.hooks)

      unless hooks
        response = ControlResponse.success(request_id)
        @cli_client.send_control_response(response)
        return
      end

      callbacks = get_callbacks_for_hook(hooks, req.hook)

      if callbacks
        input = build_hook_input(req)
        ctx = HookContext.new(session_id: input.session_id || "unknown")

        callbacks.each do |callback|
          callback.call(input, request_id, ctx)
        end
      end

      response = ControlResponse.success(request_id)
      @cli_client.send_control_response(response)
    end

    # pre_tool_use and post_tool_use are handled via PermissionRequest
    # and AssistantMessage respectively, not via control callbacks here.
    private def get_callbacks_for_hook(hooks : HookConfig, hook_name : String) : Array(HookCallback)?
      case hook_name
      when "pre_compact"        then hooks.pre_compact
      when "user_prompt_submit" then hooks.user_prompt_submit
      when "stop"               then hooks.stop
      when "session_start"      then hooks.session_start
      when "session_end"        then hooks.session_end
      when "subagent_start"     then hooks.subagent_start
      when "subagent_stop"      then hooks.subagent_stop
      when "notification"       then hooks.notification
      end
    end

    # Send control error response
    private def send_control_error(request_id : String, error_message : String)
      response = ControlResponse.error(request_id, error_message)
      @cli_client.send_control_response(response)
    end

    # Map hook name to PascalCase event name
    private def hook_event_name_for(hook_name : String) : String
      case hook_name
      when "pre_compact"        then "PreCompact"
      when "notification"       then "Notification"
      when "user_prompt_submit" then "UserPromptSubmit"
      when "stop"               then "Stop"
      when "session_start"      then "SessionStart"
      when "session_end"        then "SessionEnd"
      when "subagent_start"     then "SubagentStart"
      when "subagent_stop"      then "SubagentStop"
      when "permission_request" then "PermissionRequest"
      else                           hook_name
      end
    end

    # Extract a string field from a hash
    private def extract_string(input : Hash(String, JSON::Any)?, key : String) : String?
      input.try(&.[key]?.try(&.as_s?))
    end

    # Extract a bool field from a hash
    private def extract_bool(input : Hash(String, JSON::Any)?, key : String) : Bool?
      input.try(&.[key]?.try(&.as_bool?))
    end

    # Build base HookInput with common context fields populated
    private def build_base_hook_input(req : ControlHookCallbackRequest) : HookInput
      tool_input = req.input
      common = hook_common_fields(hook_event_name_for(req.hook))

      HookInput.new(
        session_id: extract_string(tool_input, "session_id") || common[:session_id],
        transcript_path: extract_string(tool_input, "transcript_path"),
        cwd: extract_string(tool_input, "cwd") || common[:cwd],
        permission_mode: extract_string(tool_input, "permission_mode") || common[:permission_mode],
        hook_event_name: common[:hook_event_name],
        tool_input: tool_input,
      )
    end

    # Build HookInput with appropriate fields based on hook type
    private def build_hook_input(req : ControlHookCallbackRequest) : HookInput
      input = build_base_hook_input(req)
      tool_input = req.input

      case req.hook
      when "notification"
        input.notification_message = extract_string(tool_input, "message")
        input.notification_title = extract_string(tool_input, "title")
        input.notification_type = extract_string(tool_input, "notification_type")
      when "pre_compact"
        input.trigger = extract_string(tool_input, "trigger")
        input.custom_instructions = extract_string(tool_input, "custom_instructions")
      when "stop"
        input.stop_hook_active = extract_bool(tool_input, "stop_hook_active")
      when "session_start"
        input.source = extract_string(tool_input, "source")
      when "session_end"
        input.session_end_reason = extract_string(tool_input, "reason")
      when "subagent_start"
        input.agent_id = extract_string(tool_input, "agent_id")
        input.agent_type = extract_string(tool_input, "agent_type")
      when "subagent_stop"
        input.agent_id = extract_string(tool_input, "agent_id")
        input.agent_type = extract_string(tool_input, "agent_type")
        input.agent_transcript_path = extract_string(tool_input, "agent_transcript_path")
        input.stop_hook_active = extract_bool(tool_input, "stop_hook_active")
      when "pre_tool_use", "post_tool_use", "post_tool_use_failure"
        input.tool_name = extract_string(tool_input, "tool_name")
        input.tool_use_id = extract_string(tool_input, "tool_use_id")
      when "permission_request"
        input.tool_name = extract_string(tool_input, "tool_name")
        input.tool_use_id = extract_string(tool_input, "tool_use_id")
      end

      input
    end
  end
end
