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

    it "parses SystemMessage" do
      json = <<-JSON
      {
        "type": "system",
        "subtype": "init",
        "session_id": "sess-456"
      }
      JSON

      message = ClaudeAgent::Message.parse(json)
      message.should be_a(ClaudeAgent::SystemMessage)

      if message.is_a?(ClaudeAgent::SystemMessage)
        message.subtype.should eq("init")
        message.session_id.should eq("sess-456")
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
        message.usage.should_not be_nil
      end
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

    it "raises error for unknown message type" do
      json = <<-JSON
      {
        "type": "unknown_type",
        "data": "test"
      }
      JSON

      expect_raises(ClaudeAgent::Error, /Unknown message type/) do
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
end
