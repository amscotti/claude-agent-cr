require "json"
require "./sdk_tool"
require "../errors"
require "../types/control_messages"

module ClaudeAgent
  # SDK MCP Server - defines tools that run in-process
  #
  # This implements the control protocol used by the official TypeScript and Python SDKs.
  # When the CLI needs to execute a tool, it sends a `control_request` with `mcp_message`
  # subtype containing a JSON-RPC request. The SDK routes this to the appropriate server
  # instance and returns the result via `control_response`.
  #
  # **Known Limitation:** As of January 2025, there are known issues with SDK MCP server
  # integration in the Claude Code CLI (see GitHub Issue #7279). Tool discovery may work
  # but execution routing may fail in some CLI versions.
  #
  # **Example usage:**
  # ```
  # # Define a tool
  # greet_tool = ClaudeAgent.tool(
  #   name: "greet",
  #   description: "Greet a user by name",
  #   schema: {"name" => JSON::Any.new("string")}
  # ) do |args|
  #   name = args["name"].as_s
  #   ClaudeAgent::ToolResult.text("Hello, #{name}!")
  # end
  #
  # # Create SDK MCP server
  # server = ClaudeAgent.create_sdk_mcp_server(
  #   name: "my-tools",
  #   tools: [greet_tool]
  # )
  #
  # # Use with agent
  # options = ClaudeAgent::AgentOptions.new(
  #   mcp_servers: {"tools" => server},
  #   allowed_tools: ["mcp__tools__greet"]
  # )
  # ```
  class SDKMCPServer
    getter name : String
    getter version : String
    getter tools : Array(SDKTool)

    # MCP protocol version we support
    # Updated to 2025-03-26 to match official TypeScript/Python SDKs
    # See: https://github.com/modelcontextprotocol/typescript-sdk/issues/378
    PROTOCOL_VERSION = "2025-03-26"

    def initialize(@name : String, @version : String = "1.0.0", @tools : Array(SDKTool) = [] of SDKTool)
    end

    def add_tool(tool : SDKTool)
      @tools << tool
    end

    # Handle incoming JSON-RPC message from CLI
    # This is called when the CLI sends a control_request with mcp_message subtype
    def handle_jsonrpc(message : JSONRPCMessage) : JSONRPCResponse
      method = message.method

      case method
      when "initialize"
        handle_initialize(message)
      when "notifications/initialized"
        # Notification - no response needed, but return empty success
        JSONRPCResponse.new(id: message.id)
      when "tools/list"
        handle_list_tools(message)
      when "tools/call"
        handle_call_tool(message)
      when "ping"
        handle_ping(message)
      else
        JSONRPCResponse.error(
          message.id,
          JSONRPCError::METHOD_NOT_FOUND,
          "Method not found: #{method}"
        )
      end
    end

    # Handle MCP initialize handshake
    private def handle_initialize(message : JSONRPCMessage) : JSONRPCResponse
      result = {
        "protocolVersion" => JSON::Any.new(PROTOCOL_VERSION),
        "capabilities"    => JSON::Any.new({
          "tools" => JSON::Any.new({} of String => JSON::Any),
        }),
        "serverInfo" => JSON::Any.new({
          "name"    => JSON::Any.new(@name),
          "version" => JSON::Any.new(@version),
        }),
      }

      JSONRPCResponse.success(message.id, JSON::Any.new(result))
    end

    # Handle tools/list request
    private def handle_list_tools(message : JSONRPCMessage) : JSONRPCResponse
      tools_array = @tools.map do |tool|
        tool_obj = {
          "name"        => JSON::Any.new(tool.name),
          "description" => JSON::Any.new(tool.description),
          "inputSchema" => JSON::Any.new(tool.input_schema),
        }
        JSON::Any.new(tool_obj)
      end

      result = {
        "tools" => JSON::Any.new(tools_array),
      }

      JSONRPCResponse.success(message.id, JSON::Any.new(result))
    end

    # Handle tools/call request
    private def handle_call_tool(message : JSONRPCMessage) : JSONRPCResponse
      params = message.params
      unless params
        return JSONRPCResponse.error(
          message.id,
          JSONRPCError::INVALID_PARAMS,
          "Missing params for tools/call"
        )
      end

      tool_name = params["name"]?.try(&.as_s?)
      unless tool_name
        return JSONRPCResponse.error(
          message.id,
          JSONRPCError::INVALID_PARAMS,
          "Missing tool name in params"
        )
      end

      arguments = params["arguments"]?.try(&.as_h?) || {} of String => JSON::Any

      # Find the tool
      found_tool = @tools.find { |tool| tool.name == tool_name }
      unless found_tool
        return JSONRPCResponse.error(
          message.id,
          JSONRPCError::INVALID_PARAMS,
          "Unknown tool: #{tool_name}"
        )
      end

      # Execute the tool
      begin
        tool_result = found_tool.call(arguments)
        result = build_tool_result(tool_result)
        JSONRPCResponse.success(message.id, JSON::Any.new(result))
      rescue ex
        # Tool execution error - return as MCP error result, not JSON-RPC error
        # This allows the LLM to see the error and potentially retry
        error_result = {
          "content" => JSON::Any.new([
            JSON::Any.new({
              "type" => JSON::Any.new("text"),
              "text" => JSON::Any.new("Error: #{ex.message}"),
            }),
          ]),
          "isError" => JSON::Any.new(true),
        }
        JSONRPCResponse.success(message.id, JSON::Any.new(error_result))
      end
    end

    # Handle ping request
    private def handle_ping(message : JSONRPCMessage) : JSONRPCResponse
      JSONRPCResponse.success(message.id, JSON::Any.new({} of String => JSON::Any))
    end

    # Convert ToolResult to MCP response format
    private def build_tool_result(result : ToolResult) : Hash(String, JSON::Any)
      content_array = result.content.map do |content|
        content_obj = {"type" => JSON::Any.new(content.type)}
        content.text.try { |text| content_obj["text"] = JSON::Any.new(text) }
        content.data.try { |data| content_obj["data"] = JSON::Any.new(data) }
        content.mime_type.try { |mime| content_obj["mimeType"] = JSON::Any.new(mime) }
        JSON::Any.new(content_obj)
      end

      result_hash = {
        "content" => JSON::Any.new(content_array),
      }
      result_hash["isError"] = JSON::Any.new(true) if result.is_error?
      result_hash
    end

    # Convenience method for listing tools programmatically
    # Returns tool metadata for inspection or testing
    def handle_list_tools : Array(Hash(String, JSON::Any))
      @tools.map do |tool|
        {
          "name"        => JSON::Any.new(tool.name),
          "description" => JSON::Any.new(tool.description),
          "inputSchema" => JSON::Any.new(tool.input_schema),
        }
      end
    end

    # Convenience method for calling tools directly
    # Useful for testing tools outside of the CLI integration
    def handle_call_tool(tool_name : String, args : Hash(String, JSON::Any)) : ToolResult
      found_tool = @tools.find { |tool| tool.name == tool_name }
      raise Error.new("Tool not found: #{tool_name}") unless found_tool
      found_tool.call(args)
    end
  end

  # Helper to create SDK MCP servers
  def self.create_sdk_mcp_server(
    name : String,
    version : String = "1.0.0",
    tools : Array(SDKTool) = [] of SDKTool,
  ) : SDKMCPServer
    SDKMCPServer.new(name, version, tools)
  end
end
