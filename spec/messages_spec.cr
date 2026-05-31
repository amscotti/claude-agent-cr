require "./spec_helper"

describe ClaudeAgent::Message do
  describe ".parse" do
    it "parses AssistantMessage" do
      json = <<-JSON
      {
        "type": "assistant",
        "uuid": "123",
        "session_id": "sess-456",
        "message": {
          "content": [
            {"type": "text", "text": "Hello, world!"}
          ],
          "model": "claude-sonnet-4-5-20250929"
        }
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::AssistantMessage)

      if message.is_a?(ClaudeAgent::AssistantMessage)
        message.uuid.should eq("123")
        message.session_id.should eq("sess-456")
        message.text.should eq("Hello, world!")
        message.model.should eq("claude-sonnet-4-5-20250929")
      end
    end

    it "exposes id, usage, stop_reason, stop_sequence from the inner message" do
      json = <<-JSON
      {
        "type": "assistant",
        "uuid": "env-uuid",
        "session_id": "sess-1",
        "message": {
          "id": "msg-001",
          "model": "claude-sonnet-4-6",
          "role": "assistant",
          "stop_reason": "end_turn",
          "stop_sequence": "</finish>",
          "container": null,
          "context_management": null,
          "usage": {
            "input_tokens": 42,
            "output_tokens": 7,
            "cache_creation_input_tokens": 0,
            "cache_read_input_tokens": 0
          },
          "content": [{"type": "text", "text": "ok"}]
        }
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::AssistantMessage)

      if message.is_a?(ClaudeAgent::AssistantMessage)
        message.message_id.should eq("msg-001")
        message.stop_reason.should eq("end_turn")
        message.stop_sequence.should eq("</finish>")
        usage = message.usage
        usage.should_not be_nil
        usage.try(&.["input_tokens"].as_i).should eq(42)
        usage.try(&.["output_tokens"].as_i).should eq(7)
      end
    end

    it "parses AssistantMessage with string error field" do
      json = <<-JSON
      {
        "type": "assistant",
        "uuid": "123",
        "session_id": "sess-456",
        "message": {
          "content": [
            {"type": "text", "text": "An error occurred"}
          ]
        },
        "error": "unknown"
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::AssistantMessage)

      if message.is_a?(ClaudeAgent::AssistantMessage)
        message.error.should_not be_nil
        if err = message.error
          err.type.should eq("error")
          err.message.should eq("unknown")
        end
      end
    end

    it "parses AssistantMessage with object error field" do
      json = <<-JSON
      {
        "type": "assistant",
        "uuid": "123",
        "session_id": "sess-456",
        "message": {
          "content": [
            {"type": "text", "text": "An error occurred"}
          ]
        },
        "error": {"type": "api_error", "message": "Rate limit exceeded"}
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::AssistantMessage)

      if message.is_a?(ClaudeAgent::AssistantMessage)
        message.error.should_not be_nil
        if err = message.error
          err.type.should eq("api_error")
          err.message.should eq("Rate limit exceeded")
        end
      end
    end

    it "parses AssistantMessage with tool use" do
      json = <<-JSON
      {
        "type": "assistant",
        "uuid": "123",
        "session_id": "sess-456",
        "message": {
          "content": [
            {"type": "text", "text": "Let me read that file."},
            {"type": "tool_use", "id": "tool-1", "name": "Read", "input": {"file_path": "/tmp/test.txt"}}
          ]
        }
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::AssistantMessage)

      if message.is_a?(ClaudeAgent::AssistantMessage)
        message.content.size.should eq(2)
        message.content[0].should be_a(ClaudeAgent::TextBlock)
        message.content[1].should be_a(ClaudeAgent::ToolUseBlock)

        tool_use = message.content[1].as(ClaudeAgent::ToolUseBlock)
        tool_use.name.should eq("Read")
        tool_use.input["file_path"].as_s.should eq("/tmp/test.txt")
      end
    end

    it "parses UserMessage" do
      json = <<-JSON
      {
        "type": "user",
        "uuid": "user-123",
        "session_id": "sess-456",
        "message": {"role": "user", "content": "Hello"}
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::UserMessage)

      if message.is_a?(ClaudeAgent::UserMessage)
        message.uuid.should eq("user-123")
        message.session_id.should eq("sess-456")
      end
    end

    it "parses InitMessage with server metadata" do
      json = <<-JSON
      {
        "type": "system",
        "subtype": "init",
        "session_id": "sess-456",
        "commands": [{"name": "commit", "description": "Create a commit", "argumentHint": "[message]"}],
        "agents": [{"name": "reviewer", "description": "Reviews code", "model": "haiku"}],
        "slash_commands": ["commit", "review"],
        "output_style": "default",
        "available_output_styles": ["default", "compact"],
        "models": [{"value": "default", "displayName": "Default", "supportsEffort": true}],
        "account": {"email": "user@example.com", "organization": "Example Org"},
        "pid": 123
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::InitMessage)

      if message.is_a?(ClaudeAgent::InitMessage)
        message.subtype.should eq("init")
        message.session_id.should eq("sess-456")
        message.commands.size.should eq(1)
        message.commands.first.name.should eq("commit")
        message.commands.first.argument_hint.should eq("[message]")
        message.slash_commands.should eq(["commit", "review"])
        message.output_style.should eq("default")
        message.available_output_styles.should eq(["default", "compact"])
        message.agents.first.name.should eq("reviewer")
        message.models.first.value.should eq("default")
        message.account.try(&.email).should eq("user@example.com")
        message.server_info.pid.should eq(123)
      end
    end

    it "exposes init fields the CLI emits (tools, plugins, cwd, version, etc.)" do
      json = <<-JSON
      {
        "type": "system",
        "subtype": "init",
        "session_id": "sess-1",
        "cwd": "/tmp/project",
        "tools": ["Bash", "Read", "Edit"],
        "mcp_servers": [{"name": "ctx7", "status": "connected"}],
        "model": "claude-opus-4-7",
        "permissionMode": "default",
        "apiKeySource": "none",
        "claude_code_version": "2.1.114",
        "skills": ["git", "playwright"],
        "plugins": [{"name": "p1", "path": "/x", "source": "remote"}],
        "memory_paths": {"auto": "/Users/a/.claude/memory/"},
        "fast_mode_state": "off",
        "slash_commands": ["init", "review"]
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::InitMessage)

      if message.is_a?(ClaudeAgent::InitMessage)
        message.cwd.should eq("/tmp/project")
        message.tools.should eq(["Bash", "Read", "Edit"])
        message.model.should eq("claude-opus-4-7")
        message.permission_mode.should eq("default")
        message.claude_code_version.should eq("2.1.114")
        message.skills.should eq(["git", "playwright"])
        message.fast_mode_state.should eq("off")
        message.memory_paths["auto"].should eq("/Users/a/.claude/memory/")
        message.plugins.size.should eq(1)
        message.plugins.first.as_h["name"].as_s.should eq("p1")
        message.mcp_servers.size.should eq(1)
        message.mcp_servers.first.as_h["status"].as_s.should eq("connected")
      end
    end

    it "derives slash commands from command names when slash_commands is absent" do
      json = <<-JSON
      {
        "type": "system",
        "subtype": "init",
        "session_id": "sess-456",
        "commands": [{"name": "commit"}, {"name": "review"}]
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::InitMessage)

      if message.is_a?(ClaudeAgent::InitMessage)
        message.slash_commands.should eq(["commit", "review"])
      end
    end

    it "parses generic system messages and retains raw data" do
      json = <<-JSON
      {
        "type": "system",
        "subtype": "custom_event",
        "session_id": "sess-456",
        "custom_field": "hello"
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::GenericSystemMessage)

      if message.is_a?(ClaudeAgent::GenericSystemMessage)
        message.subtype.should eq("custom_event")
        message["custom_field"].as_s.should eq("hello")
      end
    end

    it "parses CompactBoundaryMessage" do
      json = <<-JSON
      {
        "type": "system",
        "subtype": "compact_boundary",
        "uuid": "compact-123",
        "session_id": "sess-456",
        "compact_metadata": {
          "trigger": "auto",
          "pre_tokens": 4096
        }
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::CompactBoundaryMessage)

      if message.is_a?(ClaudeAgent::CompactBoundaryMessage)
        message.uuid.should eq("compact-123")
        message.compact_metadata.trigger.should eq("auto")
        message.compact_metadata.pre_tokens.should eq(4096)
      end
    end

    it "parses TaskStartedMessage" do
      json = <<-JSON
      {
        "type": "system",
        "subtype": "task_started",
        "uuid": "task-start-123",
        "session_id": "sess-456",
        "task_id": "task-123",
        "description": "Analyze the repository",
        "tool_use_id": "tool-1",
        "task_type": "explore"
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::TaskStartedMessage)

      if message.is_a?(ClaudeAgent::TaskStartedMessage)
        message.uuid.should eq("task-start-123")
        message.task_id.should eq("task-123")
        message.description.should eq("Analyze the repository")
        message.tool_use_id.should eq("tool-1")
        message.task_type.should eq("explore")
      end
    end

    it "parses TaskProgressMessage" do
      json = <<-JSON
      {
        "type": "system",
        "subtype": "task_progress",
        "uuid": "task-progress-123",
        "session_id": "sess-456",
        "task_id": "task-123",
        "description": "Searching files",
        "usage": {
          "total_tokens": 120,
          "tool_uses": 3,
          "duration_ms": 450
        },
        "last_tool_name": "Grep",
        "summary": "Scanning spec files"
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::TaskProgressMessage)

      if message.is_a?(ClaudeAgent::TaskProgressMessage)
        message.task_id.should eq("task-123")
        message.description.should eq("Searching files")
        message.usage.total_tokens.should eq(120)
        message.usage.tool_uses.should eq(3)
        message.usage.duration_ms.should eq(450)
        message.last_tool_name.should eq("Grep")
        message.summary.should eq("Scanning spec files")
      end
    end

    it "parses PromptSuggestionMessage" do
      json = <<-JSON
      {
        "type": "prompt_suggestion",
        "uuid": "suggest-123",
        "session_id": "sess-456",
        "suggestion": "Ask Claude to summarize the repository next"
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::PromptSuggestionMessage)

      if message.is_a?(ClaudeAgent::PromptSuggestionMessage)
        message.uuid.should eq("suggest-123")
        message.session_id.should eq("sess-456")
        message.suggestion.should eq("Ask Claude to summarize the repository next")
      end
    end

    it "parses ElicitationCompleteMessage" do
      json = <<-JSON
      {
        "type": "system",
        "subtype": "elicitation_complete",
        "uuid": "elicitation-123",
        "session_id": "sess-456",
        "mcp_server_name": "auth-server",
        "elicitation_id": "oauth-1"
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::ElicitationCompleteMessage)

      if message.is_a?(ClaudeAgent::ElicitationCompleteMessage)
        message.uuid.should eq("elicitation-123")
        message.session_id.should eq("sess-456")
        message.mcp_server_name.should eq("auth-server")
        message.elicitation_id.should eq("oauth-1")
      end
    end

    it "parses TaskNotificationMessage" do
      json = <<-JSON
      {
        "type": "system",
        "subtype": "task_notification",
        "uuid": "task-notify-123",
        "session_id": "sess-456",
        "task_id": "task-123",
        "status": "completed",
        "output_file": "/tmp/result.txt",
        "summary": "Done",
        "usage": {
          "total_tokens": 240,
          "tool_uses": 5,
          "duration_ms": 900
        }
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::TaskNotificationMessage)

      if message.is_a?(ClaudeAgent::TaskNotificationMessage)
        message.task_id.should eq("task-123")
        message.status.should eq("completed")
        message.output_file.should eq("/tmp/result.txt")
        message.summary.should eq("Done")
        message.usage.try(&.total_tokens).should eq(240)
      end
    end

    it "parses ResultMessage" do
      json = <<-JSON
      {
        "type": "result",
        "uuid": "result-123",
        "session_id": "sess-456",
        "subtype": "success",
        "result": "Task completed",
        "cost_usd": 0.001,
        "duration_ms": 1500,
        "duration_api_ms": 1200,
        "is_error": false,
        "num_turns": 3,
        "stop_reason": "end_turn",
        "total_cost_usd": 0.005,
        "usage": {"input_tokens": 100, "output_tokens": 50}
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::ResultMessage)

      if message.is_a?(ClaudeAgent::ResultMessage)
        message.uuid.should eq("result-123")
        message.subtype.should eq("success")
        message.result.should eq("Task completed")
        message.cost_usd.should eq(0.001)
        message.duration_ms.should eq(1500)
        message.is_error.should eq(false)
        message.num_turns.should eq(3)
        message.stop_reason.should eq("end_turn")
        message.usage.should_not be_nil
      end
    end

    it "parses RateLimitEvent" do
      json = <<-JSON
      {
        "type": "rate_limit_event",
        "uuid": "rate-123",
        "session_id": "sess-456",
        "rate_limit_info": {
          "status": "allowed_warning",
          "resetsAt": 1774000000,
          "rateLimitType": "five_hour",
          "utilization": 0.92,
          "overageStatus": "allowed",
          "overageResetsAt": 1774003600,
          "overageDisabledReason": "none"
        }
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::RateLimitEvent)

      if message.is_a?(ClaudeAgent::RateLimitEvent)
        message.uuid.should eq("rate-123")
        message.session_id.should eq("sess-456")
        message.rate_limit_info.status.should eq("allowed_warning")
        message.rate_limit_info.resets_at.should eq(1_774_000_000)
        message.rate_limit_info.rate_limit_type.should eq("five_hour")
        message.rate_limit_info.utilization.should eq(0.92)
        message.rate_limit_info.overage_status.should eq("allowed")
        message.rate_limit_info.overage_resets_at.should eq(1_774_003_600)
        message.rate_limit_info.overage_disabled_reason.should eq("none")
        message.rate_limit_info.raw["status"].as_s.should eq("allowed_warning")
      end
    end

    it "falls back to UnknownMessage for malformed rate_limit_event payloads" do
      json = <<-JSON
      {
        "type": "rate_limit_event",
        "uuid": "rate-123",
        "session_id": "sess-456",
        "rate_limit_info": {
          "resetsAt": 1774000000
        }
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::UnknownMessage)
    end

    it "parses PermissionRequest" do
      json = <<-JSON
      {
        "type": "permission_request",
        "tool_use_id": "tool-123",
        "tool_name": "Bash",
        "tool_input": {"command": "ls -la"}
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::PermissionRequest)

      if message.is_a?(ClaudeAgent::PermissionRequest)
        message.tool_use_id.should eq("tool-123")
        message.tool_name.should eq("Bash")
        message.tool_input["command"].as_s.should eq("ls -la")
      end
    end

    it "parses UserQuestion" do
      json = <<-JSON
      {
        "type": "user_question",
        "uuid": "q-123",
        "message": "Which option would you prefer?"
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::UserQuestion)

      if message.is_a?(ClaudeAgent::UserQuestion)
        message.uuid.should eq("q-123")
        message.message.should eq("Which option would you prefer?")
      end
    end

    it "parses UnknownMessage for unknown top-level message types" do
      json = <<-JSON
      {
        "type": "unknown_type",
        "data": "test",
        "session_id": "sess-456"
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::UnknownMessage)

      if message.is_a?(ClaudeAgent::UnknownMessage)
        message.type.should eq("unknown_type")
        message["data"].as_s.should eq("test")
      end
    end

    it "raises error when message type is missing" do
      json = <<-JSON
      {
        "session_id": "sess-456"
      }
      JSON

      expect_raises(ClaudeAgent::Error, /Message missing 'type' field/) do
        ClaudeAgent::Message.parse(json)
      end
    end

    it "parses ResultMessage with structured output" do
      json = <<-JSON
      {
        "type": "result",
        "uuid": "result-123",
        "session_id": "sess-456",
        "subtype": "success",
        "result": "Extracted data",
        "structured_output": {
          "name": "John Doe",
          "age": 30,
          "email": "john@example.com",
          "active": true,
          "tags": ["admin", "user"]
        }
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::ResultMessage)

      if message.is_a?(ClaudeAgent::ResultMessage)
        message.success?.should be_true
        message.has_structured_output?.should be_true

        # Test structured output helpers
        message.get_output_string("name").should eq("John Doe")
        message.get_output_int("age").should eq(30)
        message.get_output_string("email").should eq("john@example.com")
        message.get_output_bool("active").should be_true
        message.get_output_array("tags").should_not be_nil
        message.get_output_array("tags").try(&.size).should eq(2)

        # Test hash access
        hash = message.structured_output_hash
        hash.should_not be_nil
        hash.try(&.["name"].as_s).should eq("John Doe")
      end
    end

    it "handles ResultMessage without structured output" do
      json = <<-JSON
      {
        "type": "result",
        "uuid": "result-123",
        "session_id": "sess-456",
        "subtype": "error_max_turns",
        "result": "Max turns reached"
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      if message.is_a?(ClaudeAgent::ResultMessage)
        message.success?.should be_false
        message.has_structured_output?.should be_false
        message.get_output_string("name").should be_nil
        message.structured_output_hash.should be_nil
      end
    end

    it "parses UserMessage with tool_use_result" do
      json = <<-JSON
      {
        "type": "user",
        "uuid": "user-123",
        "session_id": "sess-456",
        "message": {"role": "user", "content": "Done"},
        "tool_use_result": {"tool_use_id": "tool-1", "status": "ok"}
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::UserMessage)

      if message.is_a?(ClaudeAgent::UserMessage)
        message.tool_use_result.should_not be_nil
        message.tool_use_result.try(&.as_h["tool_use_id"].as_s).should eq("tool-1")
      end
    end

    it "parses UserMessage with non-object tool_use_result" do
      json = <<-JSON
      {
        "type": "user",
        "uuid": "user-456",
        "session_id": "sess-456",
        "message": {"role": "user", "content": "Done"},
        "tool_use_result": "ok"
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::UserMessage)

      if message.is_a?(ClaudeAgent::UserMessage)
        message.tool_use_result.try(&.as_s).should eq("ok")
      end
    end

    it "parses ResultMessage with deferred_tool_use" do
      json = <<-JSON
      {
        "type": "result",
        "uuid": "res-123",
        "session_id": "sess-456",
        "subtype": "success",
        "deferred_tool_use": {
          "id": "tool-def",
          "name": "Bash",
          "input": {"command": "ls"}
        }
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::ResultMessage)

      if message.is_a?(ClaudeAgent::ResultMessage)
        message.deferred_tool_use.should_not be_nil
        if deferred = message.deferred_tool_use
          deferred.id.should eq("tool-def")
          deferred.name.should eq("Bash")
          deferred.input["command"].as_s.should eq("ls")
        end
      end
    end

    it "parses HookEventMessage system message" do
      json = <<-JSON
      {
        "type": "system",
        "subtype": "hook_started",
        "session_id": "sess-456",
        "hook_event": "PreToolUse",
        "uuid": "hook-123"
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::HookEventMessage)

      if message.is_a?(ClaudeAgent::HookEventMessage)
        message.subtype.should eq("hook_started")
        message.hook_event_name.should eq("PreToolUse")
        message.uuid.should eq("hook-123")
      end
    end
  end
end

describe ClaudeAgent::ContentBlock do
  it "parses TextBlock" do
    json = %({"type": "text", "text": "Hello"})
    block = ClaudeAgent::ContentBlockConverter.from_json(JSON::PullParser.new(json))
    block.should be_a(ClaudeAgent::TextBlock)
    block.as(ClaudeAgent::TextBlock).text.should eq("Hello")
  end

  it "parses ToolUseBlock" do
    json = %({"type": "tool_use", "id": "t1", "name": "Read", "input": {"path": "/tmp"}})
    block = ClaudeAgent::ContentBlockConverter.from_json(JSON::PullParser.new(json))
    block.should be_a(ClaudeAgent::ToolUseBlock)

    tool = block.as(ClaudeAgent::ToolUseBlock)
    tool.id.should eq("t1")
    tool.name.should eq("Read")
  end

  it "parses ToolResultBlock" do
    json = %({"type": "tool_result", "tool_use_id": "t1", "content": "file contents", "is_error": false})
    block = ClaudeAgent::ContentBlockConverter.from_json(JSON::PullParser.new(json))
    block.should be_a(ClaudeAgent::ToolResultBlock)

    result = block.as(ClaudeAgent::ToolResultBlock)
    result.tool_use_id.should eq("t1")
    result.is_error.should eq(false)
  end

  it "parses ThinkingBlock" do
    json = %({"type": "thinking", "thinking": "Let me consider...", "signature": "sig123"})
    block = ClaudeAgent::ContentBlockConverter.from_json(JSON::PullParser.new(json))
    block.should be_a(ClaudeAgent::ThinkingBlock)

    thinking = block.as(ClaudeAgent::ThinkingBlock)
    thinking.thinking.should eq("Let me consider...")
    thinking.signature.should eq("sig123")
  end

  it "parses RedactedThinkingBlock" do
    json = %({"type": "redacted_thinking", "data": "encrypted_content_here"})
    block = ClaudeAgent::ContentBlockConverter.from_json(JSON::PullParser.new(json))
    block.should be_a(ClaudeAgent::RedactedThinkingBlock)

    redacted = block.as(ClaudeAgent::RedactedThinkingBlock)
    redacted.data.should eq("encrypted_content_here")
  end

  it "parses unknown block types as UnknownBlock" do
    json = %({"type": "future_block", "some_field": "some_value"})
    block = ClaudeAgent::ContentBlockConverter.from_json(JSON::PullParser.new(json))
    block.should be_a(ClaudeAgent::UnknownBlock)

    unknown = block.as(ClaudeAgent::UnknownBlock)
    unknown.type.should eq("future_block")
    unknown.raw_json.should contain("future_block")
    unknown.raw_json.should contain("some_value")
  end

  it "parses ServerToolUseBlock" do
    json = %({"type": "server_tool_use", "id": "st1", "name": "web_search", "input": {"query": "anthropic"}})
    block = ClaudeAgent::ContentBlockConverter.from_json(JSON::PullParser.new(json))
    block.should be_a(ClaudeAgent::ServerToolUseBlock)

    tool = block.as(ClaudeAgent::ServerToolUseBlock)
    tool.id.should eq("st1")
    tool.name.should eq("web_search")
    tool.input["query"].as_s.should eq("anthropic")
  end

  it "parses ServerToolResultBlock" do
    json = %({"type": "advisor_tool_result", "tool_use_id": "st1", "content": {"results": []}})
    block = ClaudeAgent::ContentBlockConverter.from_json(JSON::PullParser.new(json))
    block.should be_a(ClaudeAgent::ServerToolResultBlock)

    result = block.as(ClaudeAgent::ServerToolResultBlock)
    result.tool_use_id.should eq("st1")
    result.content["results"].as_a.should eq([] of JSON::Any)
  end
end
