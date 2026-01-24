require "./spec_helper"

describe ClaudeAgent::SDKMCPServer do
  describe "#handle_jsonrpc" do
    it "handles initialize request" do
      server = ClaudeAgent::SDKMCPServer.new("test-server", "1.0.0")

      message = ClaudeAgent::JSONRPCMessage.new(
        method: "initialize",
        id: JSON::Any.new(1_i64),
        params: {"protocolVersion" => JSON::Any.new("2024-11-05")}
      )

      response = server.handle_jsonrpc(message)
      response.error.should be_nil
      response.result.should_not be_nil

      result = response.result.as(JSON::Any).as_h
      result["protocolVersion"].as_s.should eq("2025-03-26")
      result["serverInfo"].as_h["name"].as_s.should eq("test-server")
      result["serverInfo"].as_h["version"].as_s.should eq("1.0.0")
    end

    it "handles tools/list request with no tools" do
      server = ClaudeAgent::SDKMCPServer.new("test-server")

      message = ClaudeAgent::JSONRPCMessage.new(
        method: "tools/list",
        id: JSON::Any.new(2_i64)
      )

      response = server.handle_jsonrpc(message)
      response.error.should be_nil
      response.result.should_not be_nil

      result = response.result.as(JSON::Any).as_h
      result["tools"].as_a.should be_empty
    end

    it "handles tools/list request with tools" do
      tool = ClaudeAgent::SDKTool.new(
        name: "greet",
        description: "Greet a user",
        input_schema: {
          "type"       => JSON::Any.new("object"),
          "properties" => JSON::Any.new({
            "name" => JSON::Any.new({"type" => JSON::Any.new("string")}),
          }),
        },
        handler: ->(_args : Hash(String, JSON::Any)) {
          ClaudeAgent::ToolResult.text("Hello!")
        }
      )

      server = ClaudeAgent::SDKMCPServer.new("test-server", tools: [tool])

      message = ClaudeAgent::JSONRPCMessage.new(
        method: "tools/list",
        id: JSON::Any.new(3_i64)
      )

      response = server.handle_jsonrpc(message)
      response.error.should be_nil

      result = response.result.as(JSON::Any).as_h
      tools = result["tools"].as_a
      tools.size.should eq(1)
      tools[0].as_h["name"].as_s.should eq("greet")
      tools[0].as_h["description"].as_s.should eq("Greet a user")
    end

    it "handles tools/call request" do
      tool = ClaudeAgent::SDKTool.new(
        name: "greet",
        description: "Greet a user",
        input_schema: {} of String => JSON::Any,
        handler: ->(args : Hash(String, JSON::Any)) {
          name = args["name"]?.try(&.as_s?) || "World"
          ClaudeAgent::ToolResult.text("Hello, #{name}!")
        }
      )

      server = ClaudeAgent::SDKMCPServer.new("test-server", tools: [tool])

      message = ClaudeAgent::JSONRPCMessage.new(
        method: "tools/call",
        id: JSON::Any.new(4_i64),
        params: {
          "name"      => JSON::Any.new("greet"),
          "arguments" => JSON::Any.new({"name" => JSON::Any.new("Alice")}),
        }
      )

      response = server.handle_jsonrpc(message)
      response.error.should be_nil

      result = response.result.as(JSON::Any).as_h
      content = result["content"].as_a
      content.size.should eq(1)
      content[0].as_h["type"].as_s.should eq("text")
      content[0].as_h["text"].as_s.should eq("Hello, Alice!")
    end

    it "handles tools/call with unknown tool" do
      server = ClaudeAgent::SDKMCPServer.new("test-server")

      message = ClaudeAgent::JSONRPCMessage.new(
        method: "tools/call",
        id: JSON::Any.new(5_i64),
        params: {
          "name"      => JSON::Any.new("unknown_tool"),
          "arguments" => JSON::Any.new({} of String => JSON::Any),
        }
      )

      response = server.handle_jsonrpc(message)
      response.error.should_not be_nil
      if err = response.error
        err.code.should eq(ClaudeAgent::JSONRPCError::INVALID_PARAMS)
        err.message.should contain("Unknown tool")
      end
    end

    it "handles unknown method" do
      server = ClaudeAgent::SDKMCPServer.new("test-server")

      message = ClaudeAgent::JSONRPCMessage.new(
        method: "unknown/method",
        id: JSON::Any.new(6_i64)
      )

      response = server.handle_jsonrpc(message)
      response.error.should_not be_nil
      if err = response.error
        err.code.should eq(ClaudeAgent::JSONRPCError::METHOD_NOT_FOUND)
      end
    end

    it "handles ping request" do
      server = ClaudeAgent::SDKMCPServer.new("test-server")

      message = ClaudeAgent::JSONRPCMessage.new(
        method: "ping",
        id: JSON::Any.new(7_i64)
      )

      response = server.handle_jsonrpc(message)
      response.error.should be_nil
      response.result.should_not be_nil
    end

    it "handles tool execution error gracefully" do
      tool = ClaudeAgent::SDKTool.new(
        name: "failing_tool",
        description: "A tool that fails",
        input_schema: {} of String => JSON::Any,
        handler: ->(_args : Hash(String, JSON::Any)) {
          raise "Something went wrong!"
          ClaudeAgent::ToolResult.text("never reached")
        }
      )

      server = ClaudeAgent::SDKMCPServer.new("test-server", tools: [tool])

      message = ClaudeAgent::JSONRPCMessage.new(
        method: "tools/call",
        id: JSON::Any.new(8_i64),
        params: {
          "name"      => JSON::Any.new("failing_tool"),
          "arguments" => JSON::Any.new({} of String => JSON::Any),
        }
      )

      response = server.handle_jsonrpc(message)
      # Should return success with isError: true, not a JSON-RPC error
      response.error.should be_nil
      result = response.result.as(JSON::Any).as_h
      result["isError"].as_bool.should be_true
      result["content"].as_a[0].as_h["text"].as_s.should contain("Something went wrong")
    end
  end
end

describe ClaudeAgent::JSONRPCMessage do
  it "creates a message with all fields" do
    message = ClaudeAgent::JSONRPCMessage.new(
      method: "tools/call",
      id: JSON::Any.new(1_i64),
      params: {"name" => JSON::Any.new("test")}
    )

    message.jsonrpc.should eq("2.0")
    message.method.should eq("tools/call")
    message.id.should_not be_nil
    message.params.should_not be_nil
  end

  it "detects notifications (no id)" do
    message = ClaudeAgent::JSONRPCMessage.new(
      method: "notifications/initialized"
    )

    message.notification?.should be_true
  end
end

describe ClaudeAgent::JSONRPCResponse do
  it "creates a success response" do
    response = ClaudeAgent::JSONRPCResponse.success(
      JSON::Any.new(1_i64),
      JSON::Any.new({"result" => JSON::Any.new("ok")})
    )

    response.jsonrpc.should eq("2.0")
    response.id.should_not be_nil
    response.result.should_not be_nil
    response.error.should be_nil
  end

  it "creates an error response" do
    response = ClaudeAgent::JSONRPCResponse.error(
      JSON::Any.new(1_i64),
      -32601,
      "Method not found"
    )

    response.jsonrpc.should eq("2.0")
    response.error.should_not be_nil
    if err = response.error
      err.code.should eq(-32601)
      err.message.should eq("Method not found")
    end
    response.result.should be_nil
  end
end

describe ClaudeAgent::ControlResponse do
  it "creates a success response" do
    response = ClaudeAgent::ControlResponse.success("req-123")

    response.type.should eq("control_response")
    response.response["subtype"].as_s.should eq("success")
    response.response["request_id"].as_s.should eq("req-123")
  end

  it "creates an error response" do
    response = ClaudeAgent::ControlResponse.error("req-456", "Something failed")

    response.type.should eq("control_response")
    response.response["subtype"].as_s.should eq("error")
    response.response["request_id"].as_s.should eq("req-456")
    response.response["error"].as_s.should eq("Something failed")
  end

  it "creates an MCP response" do
    mcp_result = JSON::Any.new({
      "jsonrpc" => JSON::Any.new("2.0"),
      "id"      => JSON::Any.new(1_i64),
      "result"  => JSON::Any.new({"tools" => JSON::Any.new([] of JSON::Any)}),
    })

    response = ClaudeAgent::ControlResponse.mcp_response("req-789", mcp_result)

    response.type.should eq("control_response")
    response.response["subtype"].as_s.should eq("success")
    response.response["mcp_response"].should_not be_nil
  end
end

describe "Control Message Parsing" do
  it "parses ControlRequest with mcp_message subtype" do
    json = <<-JSON
    {
      "type": "control_request",
      "request_id": "req-123",
      "request": {
        "subtype": "mcp_message",
        "server_name": "my-server",
        "message": {
          "jsonrpc": "2.0",
          "id": 1,
          "method": "tools/list"
        }
      }
    }
    JSON

    message = ClaudeAgent::Message.parse(json)
    message.should be_a(ClaudeAgent::ControlRequest)

    if message.is_a?(ClaudeAgent::ControlRequest)
      message.request_id.should eq("req-123")
      message.request.should be_a(ClaudeAgent::ControlMCPMessageRequest)

      if req = message.request.as?(ClaudeAgent::ControlMCPMessageRequest)
        req.server_name.should eq("my-server")
        req.message.method.should eq("tools/list")
      end
    end
  end

  it "parses ControlRequest with initialize subtype" do
    json = <<-JSON
    {
      "type": "control_request",
      "request_id": "req-456",
      "request": {
        "subtype": "initialize",
        "sdkMcpServers": ["server1", "server2"]
      }
    }
    JSON

    message = ClaudeAgent::Message.parse(json)
    message.should be_a(ClaudeAgent::ControlRequest)

    if message.is_a?(ClaudeAgent::ControlRequest)
      message.request.should be_a(ClaudeAgent::ControlInitializeRequest)

      if req = message.request.as?(ClaudeAgent::ControlInitializeRequest)
        req.sdk_mcp_servers.should eq(["server1", "server2"])
      end
    end
  end

  it "parses ControlRequest with can_use_tool subtype" do
    json = <<-JSON
    {
      "type": "control_request",
      "request_id": "req-789",
      "request": {
        "subtype": "can_use_tool",
        "tool_name": "Bash",
        "input": {"command": "ls -la"}
      }
    }
    JSON

    message = ClaudeAgent::Message.parse(json)
    message.should be_a(ClaudeAgent::ControlRequest)

    if message.is_a?(ClaudeAgent::ControlRequest)
      message.request.should be_a(ClaudeAgent::ControlPermissionRequest)

      if req = message.request.as?(ClaudeAgent::ControlPermissionRequest)
        req.tool_name.should eq("Bash")
        req.input["command"].as_s.should eq("ls -la")
      end
    end
  end

  it "parses ControlRequest with interrupt subtype" do
    json = <<-JSON
    {
      "type": "control_request",
      "request_id": "req-int-001",
      "request": {
        "subtype": "interrupt"
      }
    }
    JSON

    message = ClaudeAgent::Message.parse(json)
    message.should be_a(ClaudeAgent::ControlRequest)

    if message.is_a?(ClaudeAgent::ControlRequest)
      message.request_id.should eq("req-int-001")
      message.request.should be_a(ClaudeAgent::ControlInterruptRequest)
    end
  end

  it "parses ControlRequest with set_permission_mode subtype" do
    json = <<-JSON
    {
      "type": "control_request",
      "request_id": "req-perm-001",
      "request": {
        "subtype": "set_permission_mode",
        "mode": "bypassPermissions"
      }
    }
    JSON

    message = ClaudeAgent::Message.parse(json)
    message.should be_a(ClaudeAgent::ControlRequest)

    if message.is_a?(ClaudeAgent::ControlRequest)
      message.request.should be_a(ClaudeAgent::ControlSetPermissionModeRequest)

      if req = message.request.as?(ClaudeAgent::ControlSetPermissionModeRequest)
        req.mode.should eq("bypassPermissions")
      end
    end
  end

  it "parses ControlRequest with hook_callback subtype" do
    json = <<-JSON
    {
      "type": "control_request",
      "request_id": "req-hook-001",
      "request": {
        "subtype": "hook_callback",
        "hook": "pre_tool_use",
        "input": {"tool_name": "Bash", "command": "ls"}
      }
    }
    JSON

    message = ClaudeAgent::Message.parse(json)
    message.should be_a(ClaudeAgent::ControlRequest)

    if message.is_a?(ClaudeAgent::ControlRequest)
      message.request.should be_a(ClaudeAgent::ControlHookCallbackRequest)

      if req = message.request.as?(ClaudeAgent::ControlHookCallbackRequest)
        req.hook.should eq("pre_tool_use")
        req.input.should_not be_nil
        if input = req.input
          input["tool_name"].as_s.should eq("Bash")
        end
      end
    end
  end

  it "parses ControlRequest with rewind_files subtype" do
    json = <<-JSON
    {
      "type": "control_request",
      "request_id": "req-rewind-001",
      "request": {
        "subtype": "rewind_files",
        "user_message_uuid": "msg-uuid-12345"
      }
    }
    JSON

    message = ClaudeAgent::Message.parse(json)
    message.should be_a(ClaudeAgent::ControlRequest)

    if message.is_a?(ClaudeAgent::ControlRequest)
      message.request.should be_a(ClaudeAgent::ControlRewindFilesRequest)

      if req = message.request.as?(ClaudeAgent::ControlRewindFilesRequest)
        req.user_message_uuid.should eq("msg-uuid-12345")
      end
    end
  end
end

describe ClaudeAgent::JSONRPCError do
  describe "standard error codes" do
    it "defines PARSE_ERROR" do
      ClaudeAgent::JSONRPCError::PARSE_ERROR.should eq(-32700)
    end

    it "defines INVALID_REQUEST" do
      ClaudeAgent::JSONRPCError::INVALID_REQUEST.should eq(-32600)
    end

    it "defines METHOD_NOT_FOUND" do
      ClaudeAgent::JSONRPCError::METHOD_NOT_FOUND.should eq(-32601)
    end

    it "defines INVALID_PARAMS" do
      ClaudeAgent::JSONRPCError::INVALID_PARAMS.should eq(-32602)
    end

    it "defines INTERNAL_ERROR" do
      ClaudeAgent::JSONRPCError::INTERNAL_ERROR.should eq(-32603)
    end
  end

  describe "#initialize" do
    it "creates error with code and message" do
      error = ClaudeAgent::JSONRPCError.new(-32600, "Invalid request")
      error.code.should eq(-32600)
      error.message.should eq("Invalid request")
      error.data.should be_nil
    end

    it "creates error with data" do
      error = ClaudeAgent::JSONRPCError.new(
        -32602,
        "Invalid params",
        JSON::Any.new({"field" => JSON::Any.new("missing")})
      )
      error.data.should_not be_nil
    end
  end

  describe "JSON serialization" do
    it "serializes to JSON" do
      error = ClaudeAgent::JSONRPCError.new(-32601, "Method not found")
      json = error.to_json
      parsed = JSON.parse(json)

      parsed["code"].as_i.should eq(-32601)
      parsed["message"].as_s.should eq("Method not found")
    end

    it "round-trips through JSON" do
      original = ClaudeAgent::JSONRPCError.new(-32603, "Internal error")
      json = original.to_json
      restored = ClaudeAgent::JSONRPCError.from_json(json)

      restored.code.should eq(original.code)
      restored.message.should eq(original.message)
    end
  end
end

describe ClaudeAgent::ControlResponseSuccess do
  it "initializes with request_id" do
    response = ClaudeAgent::ControlResponseSuccess.new("req-123")
    response.subtype.should eq("success")
    response.request_id.should eq("req-123")
    response.response.should be_nil
  end

  it "initializes with response data" do
    response = ClaudeAgent::ControlResponseSuccess.new(
      "req-456",
      JSON::Any.new({"result" => JSON::Any.new("ok")})
    )
    response.response.should_not be_nil
  end
end

describe ClaudeAgent::ControlResponseError do
  it "initializes with request_id and error" do
    response = ClaudeAgent::ControlResponseError.new("req-789", "Something failed")
    response.subtype.should eq("error")
    response.request_id.should eq("req-789")
    response.error.should eq("Something failed")
  end
end

describe ClaudeAgent do
  describe ".create_sdk_mcp_server" do
    it "creates an SDK MCP server" do
      server = ClaudeAgent.create_sdk_mcp_server(
        name: "my-tools",
        version: "2.0.0"
      )

      server.name.should eq("my-tools")
      server.version.should eq("2.0.0")
      server.tools.should be_empty
    end

    it "creates an SDK MCP server with tools" do
      tool = ClaudeAgent::SDKTool.new(
        name: "test",
        description: "Test tool",
        input_schema: {} of String => JSON::Any,
        handler: ->(_args : Hash(String, JSON::Any)) {
          ClaudeAgent::ToolResult.text("test")
        }
      )

      server = ClaudeAgent.create_sdk_mcp_server(
        name: "my-tools",
        tools: [tool]
      )

      server.tools.size.should eq(1)
      server.tools[0].name.should eq("test")
    end
  end

  describe ".tool" do
    it "creates a tool with Hash schema" do
      tool = ClaudeAgent.tool(
        name: "calculator",
        description: "Perform calculations",
        schema: {
          "type"       => JSON::Any.new("object"),
          "properties" => JSON::Any.new({
            "expression" => JSON::Any.new({"type" => JSON::Any.new("string")}),
          }),
        }
      ) do |_args|
        ClaudeAgent::ToolResult.text("42")
      end

      tool.name.should eq("calculator")
      tool.description.should eq("Perform calculations")
      tool.input_schema["type"].as_s.should eq("object")
    end

    it "creates a tool with Schema::SchemaType" do
      schema = ClaudeAgent::Schema.object({
        "name" => ClaudeAgent::Schema.string,
      })

      tool = ClaudeAgent.tool(
        name: "greeter",
        description: "Greet someone",
        schema: schema
      ) do |_args|
        ClaudeAgent::ToolResult.text("Hello!")
      end

      tool.name.should eq("greeter")
      tool.description.should eq("Greet someone")
      tool.input_schema["type"].as_s.should eq("object")
    end
  end
end

describe ClaudeAgent::ToolResult do
  describe ".text" do
    it "creates a text result" do
      result = ClaudeAgent::ToolResult.text("Hello, world!")

      result.content.size.should eq(1)
      result.content[0].type.should eq("text")
      result.content[0].text.should eq("Hello, world!")
      result.is_error?.should be_false
    end
  end

  describe ".error" do
    it "creates an error result" do
      result = ClaudeAgent::ToolResult.error("Something went wrong")

      result.content.size.should eq(1)
      result.content[0].type.should eq("text")
      result.content[0].text.should eq("Something went wrong")
      result.is_error?.should be_true
    end
  end

  describe "#initialize" do
    it "creates result with multiple content items" do
      content = [
        ClaudeAgent::ToolResultContent.new(type: "text", text: "Part 1"),
        ClaudeAgent::ToolResultContent.new(type: "text", text: "Part 2"),
      ]
      result = ClaudeAgent::ToolResult.new(content)

      result.content.size.should eq(2)
      result.is_error?.should be_false
    end

    it "creates result with is_error flag" do
      content = [ClaudeAgent::ToolResultContent.new(type: "text", text: "Error")]
      result = ClaudeAgent::ToolResult.new(content, is_error: true)

      result.is_error?.should be_true
    end
  end
end

describe ClaudeAgent::ToolResultContent do
  describe "#initialize" do
    it "creates text content" do
      content = ClaudeAgent::ToolResultContent.new(type: "text", text: "Hello")

      content.type.should eq("text")
      content.text.should eq("Hello")
      content.data.should be_nil
      content.mime_type.should be_nil
    end

    it "creates image content" do
      content = ClaudeAgent::ToolResultContent.new(
        type: "image",
        data: "base64encodeddata",
        mime_type: "image/png"
      )

      content.type.should eq("image")
      content.data.should eq("base64encodeddata")
      content.mime_type.should eq("image/png")
      content.text.should be_nil
    end
  end

  describe "JSON serialization" do
    it "serializes text content to JSON" do
      content = ClaudeAgent::ToolResultContent.new(type: "text", text: "Hello")
      json = content.to_json
      parsed = JSON.parse(json)

      parsed["type"].as_s.should eq("text")
      parsed["text"].as_s.should eq("Hello")
    end

    it "deserializes text content from JSON" do
      json = %({"type":"text","text":"Hello"})
      content = ClaudeAgent::ToolResultContent.from_json(json)

      content.type.should eq("text")
      content.text.should eq("Hello")
    end

    it "round-trips content through JSON" do
      original = ClaudeAgent::ToolResultContent.new(
        type: "image",
        data: "abc123",
        mime_type: "image/jpeg"
      )
      json = original.to_json
      restored = ClaudeAgent::ToolResultContent.from_json(json)

      restored.type.should eq(original.type)
      restored.data.should eq(original.data)
      restored.mime_type.should eq(original.mime_type)
    end
  end
end

describe ClaudeAgent::SDKTool do
  describe "#call" do
    it "invokes the handler with arguments" do
      tool = ClaudeAgent::SDKTool.new(
        name: "echo",
        description: "Echo the input",
        input_schema: {} of String => JSON::Any,
        handler: ->(args : Hash(String, JSON::Any)) {
          message = args["message"]?.try(&.as_s?) || "default"
          ClaudeAgent::ToolResult.text("Echo: #{message}")
        }
      )

      result = tool.call({"message" => JSON::Any.new("test")})
      result.content[0].text.should eq("Echo: test")
    end

    it "handles missing arguments gracefully" do
      tool = ClaudeAgent::SDKTool.new(
        name: "optional",
        description: "Tool with optional args",
        input_schema: {} of String => JSON::Any,
        handler: ->(args : Hash(String, JSON::Any)) {
          value = args["optional"]?.try(&.as_s?) || "fallback"
          ClaudeAgent::ToolResult.text(value)
        }
      )

      result = tool.call({} of String => JSON::Any)
      result.content[0].text.should eq("fallback")
    end
  end
end
