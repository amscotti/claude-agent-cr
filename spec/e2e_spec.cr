require "./spec_helper"

if SpecHelpers.live_e2e_enabled?
  describe "ClaudeAgent live E2E" do
    it "returns server info and supports dynamic controls" do
      options = ClaudeAgent::AgentOptions.new(
        allowed_tools: ["Read", "Glob", "Grep"],
        permission_mode: ClaudeAgent::PermissionMode::Default,
        max_turns: 4,
      )

      assistant_text = ""

      ClaudeAgent::AgentClient.open(options) do |client|
        info = client.get_server_info
        info.should_not be_nil
        actual_info = info.as(ClaudeAgent::ServerInfo)
        actual_info.commands.size.should be > 0
        actual_info.output_style.should_not be_nil

        client.set_permission_mode(ClaudeAgent::PermissionMode::Plan)
        client.set_model("claude-sonnet-4-5")
        client.get_mcp_status.should be_a(ClaudeAgent::MCPStatusResponse)

        client.query("Answer with exactly: OK")
        client.each_response do |message|
          if message.is_a?(ClaudeAgent::AssistantMessage) && message.has_text?
            assistant_text += message.text
          end
        end
      end

      assistant_text.includes?("OK").should be_true
    end

    it "lists session history after a live query" do
      session_id = nil.as(String?)

      ClaudeAgent.query("Answer with exactly: SESSION_OK") do |message|
        if message.is_a?(ClaudeAgent::InitMessage)
          session_id = message.session_id
        end
      end

      session_id.should_not be_nil
      actual_session_id = session_id.as(String)

      sessions = ClaudeAgent.list_sessions(directory: Dir.current, limit: 20)
      sessions.any? { |session| session.session_id == actual_session_id }.should be_true

      messages = ClaudeAgent.get_session_messages(actual_session_id, directory: Dir.current)
      messages.any? { |message| message.type == "user" }.should be_true
      messages.any? { |message| message.type == "assistant" }.should be_true
    end

    it "applies pre-tool hook input overrides end to end" do
      rewrite_bash = ->(input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
        if input.tool_name == "Bash"
          ClaudeAgent::HookResult.allow_with_input({
            "command" => JSON::Any.new("pwd"),
          })
        else
          ClaudeAgent::HookResult.allow
        end
      }

      options = ClaudeAgent::AgentOptions.new(
        allowed_tools: ["Bash"],
        permission_mode: ClaudeAgent::PermissionMode::AcceptEdits,
        hooks: ClaudeAgent::HookConfig.new(
          pre_tool_use: [ClaudeAgent::HookMatcher.new(matcher: "Bash", hooks: [rewrite_bash])],
        ),
        max_turns: 3,
      )

      assistant_text = ""

      ClaudeAgent::AgentClient.open(options) do |client|
        client.query("Use Bash to run `echo should-be-overridden`, then tell me exactly what command output you saw.")
        client.each_response do |message|
          if message.is_a?(ClaudeAgent::AssistantMessage) && message.has_text?
            assistant_text += message.text
          end
        end
      end

      assistant_text.includes?(Dir.current).should be_true
    end

    it "emits rich task events when using the Agent tool" do
      options = ClaudeAgent::AgentOptions.new(
        allowed_tools: ["Read", "Glob", "Grep", "Agent"],
        max_turns: 4,
      )

      started_task_ids = [] of String
      progress_task_ids = [] of String
      saw_result = false

      ClaudeAgent::AgentClient.open(options) do |client|
        client.query("Use the Agent tool to inspect this repository and suggest one test improvement in exactly one sentence.")

        client.each_response do |message|
          case message
          when ClaudeAgent::TaskStartedMessage
            started_task_ids << message.task_id
          when ClaudeAgent::TaskProgressMessage
            progress_task_ids << message.task_id
          when ClaudeAgent::ResultMessage
            saw_result = message.success?
          end
        end
      end

      started_task_ids.should_not be_empty
      progress_task_ids.should_not be_empty
      (started_task_ids & progress_task_ids).should_not be_empty
      saw_result.should be_true
    end

    it "returns structured output end to end" do
      schema = ClaudeAgent::Schema.object({
        "status" => ClaudeAgent::Schema.string("Result status"),
        "score"  => ClaudeAgent::Schema.integer("Confidence score", minimum: 1, maximum: 10),
      }, required: ["status", "score"])

      options = ClaudeAgent::AgentOptions.new(
        allowed_tools: ["Read"],
        permission_mode: ClaudeAgent::PermissionMode::BypassPermissions,
        allow_dangerously_skip_permissions: true,
        output_format: ClaudeAgent::OutputFormat.json_schema(schema, name: "E2EStatus"),
        max_turns: 3,
      )

      structured_output = nil.as(JSON::Any?)

      ClaudeAgent.query("Return a JSON object with status set to 'ok' and score set to 5. Do not use any tools.", options) do |message|
        if message.is_a?(ClaudeAgent::ResultMessage)
          structured_output = message.structured_output
        end
      end

      structured_output.should_not be_nil
      if output = structured_output
        output.raw.should_not be_nil
        output_hash = output.as_h?
        if output_hash
          output_hash["status"]?.try(&.as_s?).should_not be_nil
          output_hash["score"]?.should_not be_nil
        end
      end
    end

    it "provides typed init metadata during a live query" do
      init_message = nil.as(ClaudeAgent::InitMessage?)

      ClaudeAgent.query("Answer with exactly: INIT_OK") do |message|
        if message.is_a?(ClaudeAgent::InitMessage)
          init_message = message
        end
      end

      init_message.should_not be_nil
      actual_init = init_message.as(ClaudeAgent::InitMessage)
      actual_init.server_info.commands.should_not be_empty
      actual_init.output_style.should_not be_nil
      actual_init.slash_commands.should_not be_empty
    end

    it "emits partial stream events when include_partial_messages is enabled" do
      options = ClaudeAgent::AgentOptions.new(
        include_partial_messages: true,
        model: "claude-sonnet-4-5",
        max_turns: 2,
        thinking: ClaudeAgent::ThinkingConfig.enabled(8_000),
      )

      stream_event_types = [] of String
      thinking_deltas = [] of String
      saw_assistant = false
      saw_result = false

      ClaudeAgent.query("Think of three jokes, then tell one.", options) do |message|
        case message
        when ClaudeAgent::StreamEvent
          event = message.event
          event_type = event["type"]?.try(&.as_s?)
          stream_event_types << event_type if event_type

          if event_type == "content_block_delta"
            delta = event["delta"]?.try(&.as_h?)
            if delta && delta["type"]?.try(&.as_s?) == "thinking_delta"
              if thinking = delta["thinking"]?.try(&.as_s?)
                thinking_deltas << thinking
              end
            end
          end
        when ClaudeAgent::AssistantMessage
          saw_assistant = true
        when ClaudeAgent::ResultMessage
          saw_result = true
        end
      end

      stream_event_types.should contain("message_start")
      stream_event_types.should contain("content_block_start")
      stream_event_types.should contain("content_block_delta")
      stream_event_types.should contain("content_block_stop")
      stream_event_types.should contain("message_stop")
      thinking_deltas.should_not be_empty
      saw_assistant.should be_true
      saw_result.should be_true
    end
  end
end
