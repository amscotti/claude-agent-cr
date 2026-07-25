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

    it "exposes tool_use_meta sidecar, stop_details, and refusal? on AssistantMessage" do
      json = <<-JSON
      {
        "type": "assistant",
        "uuid": "env-uuid",
        "session_id": "sess-1",
        "message": {
          "id": "msg-001",
          "model": "claude-sonnet-4-6",
          "stop_reason": "refusal",
          "stop_details": {
            "category": "cyber",
            "explanation": "Refused: unsafe operation",
            "fallback_credit_token": null
          },
          "content": [
            {"type": "tool_use", "id": "tool-1", "name": "mcp__github__search", "input": {}}
          ]
        },
        "tool_use_meta": [
          {
            "id": "tool-1",
            "display_name": "Search GitHub",
            "server_display_name": "GitHub",
            "icon_url": "https://example.com/icon.png"
          }
        ]
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::AssistantMessage)

      if message.is_a?(ClaudeAgent::AssistantMessage)
        message.stop_reason.should eq("refusal")
        message.refusal?.should be_true

        details = message.stop_details
        details.should_not be_nil
        details.try(&.category).should eq("cyber")
        details.try(&.explanation).should eq("Refused: unsafe operation")
        details.try(&.fallback_credit_token).should be_nil

        meta = message.tool_use_meta
        meta.should_not be_nil
        meta.try(&.size).should eq(1)

        entry = message.tool_use_meta_for("tool-1")
        entry.should_not be_nil
        entry.try(&.display_name).should eq("Search GitHub")
        entry.try(&.server_display_name).should eq("GitHub")
        entry.try(&.icon_url).should eq("https://example.com/icon.png")

        message.tool_use_meta_for("missing-id").should be_nil
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
        message.is_meta.should be_nil
        message.is_synthetic.should be_nil
        message.file_attachments.should be_nil
        message.meta?.should be_false
      end
    end

    it "parses UserMessage isMeta as is_meta" do
      json = <<-JSON
      {
        "type": "user",
        "uuid": "user-meta-flag",
        "session_id": "sess-456",
        "isMeta": true,
        "message": {"role": "user", "content": "system note"}
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::UserMessage)

      if message.is_a?(ClaudeAgent::UserMessage)
        message.is_meta.should eq(true)
        message.meta?.should be_true
      end
    end

    it "maps isSynthetic to is_meta on UserMessage parse" do
      json = <<-JSON
      {
        "type": "user",
        "uuid": "user-synth",
        "session_id": "sess-456",
        "isSynthetic": true,
        "message": {"role": "user", "content": "synthetic"}
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::UserMessage)

      if message.is_a?(ClaudeAgent::UserMessage)
        message.is_synthetic.should eq(true)
        message.is_meta.should eq(true)
        message.meta?.should be_true
      end
    end

    it "parses UserMessage snake_case is_meta" do
      json = <<-JSON
      {
        "type": "user",
        "uuid": "user-snake-meta",
        "session_id": "sess-456",
        "is_meta": true,
        "message": {"role": "user", "content": "meta"}
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      if message.is_a?(ClaudeAgent::UserMessage)
        message.is_meta.should eq(true)
        message.meta?.should be_true
      end
    end

    it "parses UserMessage file_attachments" do
      json = <<-JSON
      {
        "type": "user",
        "uuid": "user-attach",
        "session_id": "sess-456",
        "message": {"role": "user", "content": "see attached"},
        "file_attachments": [
          {
            "path": "/tmp/photo.png",
            "name": "photo.png",
            "mediaType": "image/png"
          },
          {
            "path": "/tmp/notes.txt",
            "filename": "notes.txt",
            "media_type": "text/plain"
          }
        ]
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::UserMessage)

      if message.is_a?(ClaudeAgent::UserMessage)
        attachments = message.file_attachments
        attachments.should_not be_nil
        attachments.try(&.size).should eq(2)
        if first = attachments.try(&.first)
          first.path.should eq("/tmp/photo.png")
          first.name.should eq("photo.png")
          first.media_type.should eq("image/png")
        end
        if second = attachments.try(&.[1])
          second.path.should eq("/tmp/notes.txt")
          second.name.should eq("notes.txt")
          second.media_type.should eq("text/plain")
        end
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

    it "parses TaskUpdatedMessage with terminal killed status" do
      json = <<-JSON
      {
        "type": "system",
        "subtype": "task_updated",
        "uuid": "task-upd-123",
        "session_id": "sess-456",
        "task_id": "task-123",
        "patch": {"status": "killed", "end_time": 1234}
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::TaskUpdatedMessage)

      if message.is_a?(ClaudeAgent::TaskUpdatedMessage)
        message.task_id.should eq("task-123")
        message.status.should eq("killed")
        message.patch["end_time"]?.try(&.as_i64).should eq(1234_i64)
        message.terminal?.should be_true
      end
    end

    it "parses TaskUpdatedMessage with non-terminal running status" do
      json = <<-JSON
      {
        "type": "system",
        "subtype": "task_updated",
        "uuid": "task-upd-456",
        "session_id": "sess-456",
        "task_id": "task-456",
        "patch": {"status": "running"}
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::TaskUpdatedMessage)

      if message.is_a?(ClaudeAgent::TaskUpdatedMessage)
        message.status.should eq("running")
        message.terminal?.should be_false
      end
    end

    it "exposes TERMINAL_TASK_STATUSES covering both vocabularies" do
      ClaudeAgent::TERMINAL_TASK_STATUSES.should contain("completed")
      ClaudeAgent::TERMINAL_TASK_STATUSES.should contain("failed")
      ClaudeAgent::TERMINAL_TASK_STATUSES.should contain("stopped")
      ClaudeAgent::TERMINAL_TASK_STATUSES.should contain("killed")
    end

    it "parses ResultMessage" do
      json = <<-JSON
      {
        "type": "result",
        "uuid": "result-123",
        "session_id": "sess-456",
        "subtype": "success",
        "origin": {"kind": "human"},
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
        message.origin.try(&.kind).should eq("human")
        message.origin.try(&.human?).should be_true
        message.origin.try(&.task_notification?).should be_false
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

    it "parses ResultMessage with typed ModelUsage including canonicalModel and provider" do
      json = <<-JSON
      {
        "type": "result",
        "uuid": "result-mu-1",
        "session_id": "sess-456",
        "subtype": "success",
        "result": "Hello",
        "duration_ms": 3000,
        "duration_api_ms": 2000,
        "is_error": false,
        "num_turns": 1,
        "total_cost_usd": 0.0106,
        "modelUsage": {
          "claude-sonnet-4-5-20250929": {
            "inputTokens": 3,
            "outputTokens": 24,
            "cacheReadInputTokens": 20012,
            "cacheCreationInputTokens": 100,
            "webSearchRequests": 1,
            "costUSD": 0.0106,
            "contextWindow": 200000,
            "maxOutputTokens": 64000,
            "canonicalModel": "claude-sonnet-4-5",
            "provider": "firstParty"
          }
        }
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::ResultMessage)

      if message.is_a?(ClaudeAgent::ResultMessage)
        usage_map = message.model_usage
        usage_map.should_not be_nil
        entry = usage_map.try(&.["claude-sonnet-4-5-20250929"])
        entry.should_not be_nil
        if entry
          entry.should be_a(ClaudeAgent::ModelUsage)
          entry.input_tokens.should eq(3)
          entry.output_tokens.should eq(24)
          entry.cache_read_input_tokens.should eq(20012)
          entry.cache_creation_input_tokens.should eq(100)
          entry.web_search_requests.should eq(1)
          entry.cost_usd.should eq(0.0106)
          entry.context_window.should eq(200000)
          entry.max_output_tokens.should eq(64000)
          entry.canonical_model.should eq("claude-sonnet-4-5")
          entry.provider.should eq("firstParty")
        end
      end
    end

    it "parses ModelUsage with missing optional fields defaulting safely" do
      json = <<-JSON
      {
        "type": "result",
        "uuid": "result-mu-2",
        "session_id": "sess-456",
        "subtype": "success",
        "modelUsage": {
          "m1": {
            "inputTokens": 10,
            "outputTokens": 5,
            "costUSD": 0.001,
            "contextWindow": 200000,
            "maxOutputTokens": 8192
          }
        }
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      if message.is_a?(ClaudeAgent::ResultMessage)
        entry = message.model_usage.try(&.["m1"])
        entry.should_not be_nil
        if entry
          entry.input_tokens.should eq(10)
          entry.cache_creation_input_tokens.should eq(0)
          entry.web_search_requests.should eq(0)
          entry.canonical_model.should be_nil
          entry.provider.should be_nil
        end
      end
    end

    it "parses ResultMessage new metadata fields" do
      json = <<-JSON
      {
        "type": "result",
        "uuid": "result-meta-1",
        "session_id": "sess-456",
        "subtype": "success",
        "result": "ok",
        "terminal_reason": "completed",
        "fast_mode_state": "off",
        "fast_mode_disabled_reason": "preference",
        "user_message_uuid": "user-uuid-abc",
        "request_sent_wall_ms": 1710000000123,
        "permission_denials": [
          {
            "tool_name": "Bash",
            "tool_use_id": "tool-1",
            "tool_input": {"command": "rm -rf /"},
            "decision_reason_type": "safetyCheck"
          }
        ]
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::ResultMessage)

      if message.is_a?(ClaudeAgent::ResultMessage)
        message.terminal_reason.should eq("completed")
        message.fast_mode_disabled_reason.should eq("preference")
        message.user_message_uuid.should eq("user-uuid-abc")
        message.request_sent_wall_ms.should eq(1_710_000_000_123_i64)

        denials = message.permission_denials
        denials.should_not be_nil
        denials.try(&.size).should eq(1)
        if denial = denials.try(&.first)
          denial.should be_a(ClaudeAgent::PermissionDenial)
          denial.tool_name.should eq("Bash")
          denial.tool_use_id.should eq("tool-1")
          denial.tool_input.try(&.["command"].as_s).should eq("rm -rf /")
          denial.decision_reason_type.should eq("safetyCheck")
        end
      end
    end

    it "documents TERMINAL_REASONS and PERMISSION_DENIAL_REASONS constants" do
      ClaudeAgent::TERMINAL_REASONS.should contain("completed")
      ClaudeAgent::TERMINAL_REASONS.should contain("aborted_streaming")
      ClaudeAgent::TERMINAL_REASONS.should contain("aborted_tools")
      ClaudeAgent::TERMINAL_REASONS.should contain("tool_deferred_unavailable")
      ClaudeAgent::TERMINAL_REASONS.should contain("turn_setup_failed")
      ClaudeAgent::TERMINAL_REASONS.should contain("api_error")
      ClaudeAgent::TERMINAL_REASONS.should contain("budget_exhausted")
      ClaudeAgent::TERMINAL_REASONS.should contain("structured_output_retry_exhausted")
      ClaudeAgent::TERMINAL_REASONS.should contain("malformed_tool_use_exhausted")
      ClaudeAgent::TERMINAL_REASONS.should contain("max_budget_usd")

      ClaudeAgent::PERMISSION_DENIAL_REASONS.should contain("safetyCheck")
      ClaudeAgent::PERMISSION_DENIAL_REASONS.should contain("asyncAgent")
    end

    it "parses UserMessage with tool_result_meta array (CLI wire shape)" do
      json = <<-JSON
      {
        "type": "user",
        "uuid": "user-meta-1",
        "session_id": "sess-456",
        "message": {"role": "user", "content": "tool result"},
        "tool_use_result": "Permission denied",
        "tool_result_meta": [
          {
            "id": "toolu_1",
            "non_execution_kind": "denied",
            "user_feedback": "User denied Bash"
          }
        ]
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::UserMessage)

      if message.is_a?(ClaudeAgent::UserMessage)
        meta = message.tool_result_meta
        meta.should_not be_nil
        meta.try(&.size).should eq(1)
        entry = message.tool_result_meta_for("toolu_1")
        entry.should_not be_nil
        entry.try(&.non_execution_kind).should eq("denied")
        entry.try(&.user_feedback).should eq("User denied Bash")
      end
    end

    it "parses UserMessage with single-object tool_result_meta (compat)" do
      json = <<-JSON
      {
        "type": "user",
        "uuid": "user-meta-1b",
        "session_id": "sess-456",
        "message": {"role": "user", "content": "tool result"},
        "tool_result_meta": {
          "non_execution_kind": "interrupted",
          "user_feedback": "stopped"
        }
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      if message.is_a?(ClaudeAgent::UserMessage)
        message.tool_result_meta.try(&.size).should eq(1)
        message.tool_result_meta.try(&.first.non_execution_kind).should eq("interrupted")
      end
    end

    it "parses UserMessage without tool_result_meta (backward compat)" do
      json = <<-JSON
      {
        "type": "user",
        "uuid": "user-meta-2",
        "session_id": "sess-456",
        "message": {"role": "user", "content": "Hello"}
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      if message.is_a?(ClaudeAgent::UserMessage)
        message.tool_result_meta.should be_nil
      end
    end

    it "parses AssistantMessage with timestamp and aborted" do
      json = <<-JSON
      {
        "type": "assistant",
        "uuid": "asst-abort-1",
        "session_id": "sess-456",
        "timestamp": "2026-07-24T12:00:00.000Z",
        "aborted": true,
        "message": {
          "content": [{"type": "text", "text": "partial..."}]
        }
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::AssistantMessage)

      if message.is_a?(ClaudeAgent::AssistantMessage)
        message.timestamp.should eq("2026-07-24T12:00:00.000Z")
        message.aborted.should eq(true)
        message.aborted?.should be_true
        message.text.should eq("partial...")
      end
    end

    it "parses AssistantMessage without timestamp/aborted (backward compat)" do
      json = <<-JSON
      {
        "type": "assistant",
        "uuid": "asst-old-1",
        "session_id": "sess-456",
        "message": {
          "content": [{"type": "text", "text": "done"}]
        }
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      if message.is_a?(ClaudeAgent::AssistantMessage)
        message.timestamp.should be_nil
        message.aborted.should be_nil
        message.aborted?.should be_false
      end
    end

    it "parses MessageOrigin with subkind and body" do
      json = <<-JSON
      {
        "type": "result",
        "uuid": "result-origin-1",
        "session_id": "sess-456",
        "subtype": "success",
        "origin": {
          "kind": "task-notification",
          "subkind": "scheduled-trigger"
        }
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      if message.is_a?(ClaudeAgent::ResultMessage)
        origin = message.origin
        origin.should_not be_nil
        origin.try(&.kind).should eq("task-notification")
        origin.try(&.subkind).should eq("scheduled-trigger")
        origin.try(&.scheduled_trigger?).should be_true
        origin.try(&.task_notification?).should be_true
      end
    end

    it "parses MessageOrigin peer body" do
      json = <<-JSON
      {
        "type": "result",
        "uuid": "result-origin-2",
        "session_id": "sess-456",
        "subtype": "success",
        "origin": {
          "kind": "peer",
          "from": "agent-1",
          "name": "Reviewer",
          "body": "Please review the PR",
          "senderTaskId": "task-99"
        }
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      if message.is_a?(ClaudeAgent::ResultMessage)
        origin = message.origin
        origin.try(&.kind).should eq("peer")
        origin.try(&.from).should eq("agent-1")
        origin.try(&.name).should eq("Reviewer")
        origin.try(&.body).should eq("Please review the PR")
        origin.try(&.sender_task_id).should eq("task-99")
      end
    end

    it "parses CommandLifecycleMessage" do
      json = <<-JSON
      {
        "type": "system",
        "subtype": "command_lifecycle",
        "session_id": "sess-456",
        "uuid": "lifecycle-1",
        "message_uuid": "cmd-uuid-1",
        "state": "completed"
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::CommandLifecycleMessage)

      if message.is_a?(ClaudeAgent::CommandLifecycleMessage)
        message.uuid.should eq("lifecycle-1")
        message.message_uuid.should eq("cmd-uuid-1")
        message.state.should eq("completed")
        message.terminal?.should be_true
      end
    end

    it "parses CommandLifecycleMessage cancelled state" do
      json = <<-JSON
      {
        "type": "system",
        "subtype": "command_lifecycle",
        "session_id": "sess-456",
        "uuid": "lifecycle-2",
        "state": "cancelled"
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      if message.is_a?(ClaudeAgent::CommandLifecycleMessage)
        message.state.should eq("cancelled")
        message.message_uuid.should be_nil
        message.terminal?.should be_true
        ClaudeAgent::COMMAND_LIFECYCLE_STATES.should contain("cancelled")
      end
    end

    it "parses BackgroundTasksChangedMessage" do
      json = <<-JSON
      {
        "type": "system",
        "subtype": "background_tasks_changed",
        "session_id": "sess-456",
        "uuid": "btc-1",
        "tasks": [
          {
            "task_id": "task-1",
            "task_type": "shell",
            "description": "Running tests"
          },
          {
            "task_id": "task-2",
            "task_type": "subagent",
            "description": "Explore codebase"
          }
        ]
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::BackgroundTasksChangedMessage)

      if message.is_a?(ClaudeAgent::BackgroundTasksChangedMessage)
        message.uuid.should eq("btc-1")
        message.tasks.size.should eq(2)
        message.tasks[0].task_id.should eq("task-1")
        message.tasks[0].task_type.should eq("shell")
        message.tasks[0].description.should eq("Running tests")
        message.tasks[1].task_id.should eq("task-2")
        message.tasks[1].task_type.should eq("subagent")
      end
    end

    it "parses BackgroundTasksChangedMessage with empty tasks" do
      json = <<-JSON
      {
        "type": "system",
        "subtype": "background_tasks_changed",
        "session_id": "sess-456",
        "tasks": []
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      if message.is_a?(ClaudeAgent::BackgroundTasksChangedMessage)
        message.tasks.should be_empty
      end
    end

    it "parses ModelFallbackMessage" do
      json = <<-JSON
      {
        "type": "system",
        "subtype": "model_fallback",
        "session_id": "sess-456",
        "uuid": "mf-1",
        "trigger": "overloaded",
        "original_model": "claude-opus-4-7",
        "fallback_model": "claude-sonnet-4-6"
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::ModelFallbackMessage)

      if message.is_a?(ClaudeAgent::ModelFallbackMessage)
        message.trigger.should eq("overloaded")
        message.original_model.should eq("claude-opus-4-7")
        message.fallback_model.should eq("claude-sonnet-4-6")
        message.uuid.should eq("mf-1")
        ClaudeAgent::MODEL_FALLBACK_TRIGGERS.should contain("overloaded")
        ClaudeAgent::MODEL_FALLBACK_TRIGGERS.should contain("last_resort")
        ClaudeAgent::MODEL_FALLBACK_TRIGGERS.should contain("server_error")
      end
    end

    it "parses WorkerShuttingDownMessage" do
      json = <<-JSON
      {
        "type": "system",
        "subtype": "worker_shutting_down",
        "session_id": "sess-456",
        "uuid": "wsd-1",
        "reason": "host_exit"
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::WorkerShuttingDownMessage)

      if message.is_a?(ClaudeAgent::WorkerShuttingDownMessage)
        message.reason.should eq("host_exit")
        message.uuid.should eq("wsd-1")
      end
    end

    it "parses ToolProgressMessage with subagent fields" do
      json = <<-JSON
      {
        "type": "tool_progress",
        "uuid": "tp-1",
        "session_id": "sess-456",
        "tool_use_id": "tool-99",
        "tool_name": "Agent",
        "parent_tool_use_id": null,
        "elapsed_time_seconds": 12.5,
        "task_id": "task-sub-1",
        "heartbeat": true,
        "subagent_type": "Explore",
        "subagent_retry": {
          "agent_id": "agent-abc",
          "attempt": 2,
          "max_retries": 5,
          "retry_delay_ms": 1500,
          "error_status": 429,
          "error_category": "rate_limit"
        }
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::ToolProgressMessage)

      if message.is_a?(ClaudeAgent::ToolProgressMessage)
        message.tool_use_id.should eq("tool-99")
        message.tool_name.should eq("Agent")
        message.elapsed_time_seconds.should eq(12.5)
        message.task_id.should eq("task-sub-1")
        message.heartbeat.should eq(true)
        message.subagent_type.should eq("Explore")
        message.blocked.should be_nil
        retry_info = message.subagent_retry
        retry_info.should_not be_nil
        if retry_info
          retry_info.agent_id.should eq("agent-abc")
          retry_info.attempt.should eq(2)
          retry_info.max_retries.should eq(5)
          retry_info.retry_delay_ms.should eq(1500)
          retry_info.error_status.should eq(429)
          retry_info.error_category.should eq("rate_limit")
        end
      end
    end

    it "parses ToolProgressMessage blocked for workflow_agent classifier" do
      json = <<-JSON
      {
        "type": "tool_progress",
        "uuid": "tp-blocked",
        "session_id": "sess-456",
        "tool_use_id": "tool-wf-1",
        "tool_name": "workflow_agent",
        "elapsed_time_seconds": 1.0,
        "blocked": true
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::ToolProgressMessage)

      if message.is_a?(ClaudeAgent::ToolProgressMessage)
        message.tool_name.should eq("workflow_agent")
        message.blocked.should eq(true)
      end
    end

    it "exposes non-empty usage-limit error prefix constants" do
      ClaudeAgent::USAGE_LIMIT_ERROR_PREFIXES.should_not be_empty
      ClaudeAgent::USAGE_LIMIT_ERROR_PREFIXES.should contain("You've hit your")
      ClaudeAgent::USAGE_LIMIT_ERROR_PREFIXES.should contain("You're out of usage credits")
      ClaudeAgent::USAGE_WARNING_PREFIXES.should_not be_empty
      ClaudeAgent::USAGE_TRANSITION_PREFIXES.should_not be_empty
      ClaudeAgent::ORG_POLICY_LIMIT_PREFIXES.should_not be_empty

      sample = "You've hit your limit · resets 3pm"
      matched = ClaudeAgent::USAGE_LIMIT_ERROR_PREFIXES.any? { |prefix| sample.starts_with?(prefix) }
      matched.should be_true
    end

    it "parses RateLimitInfo with credits and model_scoped extensions" do
      json = <<-JSON
      {
        "type": "rate_limit_event",
        "uuid": "rate-ext-1",
        "session_id": "sess-456",
        "rate_limit_info": {
          "status": "rejected",
          "resetsAt": 1774000000,
          "rateLimitType": "seven_day_overage_included",
          "utilization": 1.0,
          "errorCode": "credits_required",
          "canUserPurchaseCredits": true,
          "hasChargeableSavedPaymentMethod": false,
          "model_scoped": [
            {
              "display_name": "Sonnet",
              "utilization": 0.85,
              "resets_at": "2026-07-31T00:00:00Z"
            }
          ]
        }
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::RateLimitEvent)

      if message.is_a?(ClaudeAgent::RateLimitEvent)
        info = message.rate_limit_info
        info.status.should eq("rejected")
        info.error_code.should eq("credits_required")
        info.can_user_purchase_credits.should eq(true)
        info.has_chargeable_saved_payment_method.should eq(false)
        info.rate_limit_type.should eq("seven_day_overage_included")

        scoped = info.model_scoped
        scoped.should_not be_nil
        scoped.try(&.size).should eq(1)
        if entry = scoped.try(&.first)
          entry.display_name.should eq("Sonnet")
          entry.utilization.should eq(0.85)
          entry.resets_at.should eq("2026-07-31T00:00:00Z")
        end
      end
    end

    it "parses ResultMessage without new optional fields (backward compat)" do
      json = <<-JSON
      {
        "type": "result",
        "uuid": "result-old",
        "session_id": "sess-456",
        "subtype": "success",
        "result": "ok"
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      if message.is_a?(ClaudeAgent::ResultMessage)
        message.model_usage.should be_nil
        message.permission_denials.should be_nil
        message.fast_mode_disabled_reason.should be_nil
        message.user_message_uuid.should be_nil
        message.request_sent_wall_ms.should be_nil
        message.terminal_reason.should be_nil
        message.origin.should be_nil
      end
    end

    it "falls back to GenericSystemMessage for incomplete command_lifecycle" do
      json = <<-JSON
      {
        "type": "system",
        "subtype": "command_lifecycle",
        "session_id": "sess-456",
        "uuid": "lifecycle-incomplete"
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::GenericSystemMessage)
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
