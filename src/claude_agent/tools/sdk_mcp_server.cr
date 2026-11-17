require "json"
require "./sdk_tool"
require "../errors"
require "../version"
require "../types/control_messages"

module ClaudeAgent
  # Reserved JavaScript Object.prototype property names rejected as MCP server
  # names to match upstream TypeScript SDK / CLI validation.
  RESERVED_MCP_SERVER_NAMES = Set{
    "__proto__",
    "__defineGetter__",
    "__defineSetter__",
    "__lookupGetter__",
    "__lookupSetter__",
  }

  # Validate an MCP server name, raising `ConfigurationError` if it is reserved.
  def self.validate_mcp_server_name!(name : String) : Nil
    if RESERVED_MCP_SERVER_NAMES.includes?(name)
      raise ConfigurationError.new(
        "Invalid MCP server name #{name.inspect}: reserved property names are not allowed.",
      )
    end
  end

  # Per-tool permission policy for an MCP server.
  # Matches TypeScript `McpServerToolPolicy`: wire keys are snake_case
  # (`permission_policy`, `org_max_permission`).
  struct MCPServerToolPolicy
    include JSON::Serializable

    property name : String
    property permission_policy : String? = nil
    property org_max_permission : String? = nil

    def initialize(
      @name : String,
      @permission_policy : String? = nil,
      @org_max_permission : String? = nil,
    )
    end
  end

  # SDK MCP Server - defines tools that run in-process
  #
  # This implements the control protocol used by the official Claude Code SDKs.
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
    getter timeout : Int32?
    getter tool_policies : Array(MCPServerToolPolicy)?

    # MCP protocol version we support
    # Updated to 2025-03-26 to match official Claude Code SDKs
    # See: https://github.com/modelcontextprotocol/typescript-sdk/issues/378
    PROTOCOL_VERSION = "2025-03-26"

    def initialize(
      @name : String,
      @version : String = "1.0.0",
      @tools : Array(SDKTool) = [] of SDKTool,
      @timeout : Int32? = nil,
      @tool_policies : Array(MCPServerToolPolicy)? = nil,
    )
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

    # Build an in-process startup manifest by running internal `initialize` and
    # `tools/list` JSON-RPC calls. Returns `{"initializeResult" => ..., "toolsListResult" => ...}`
    # (omitting any tool whose `input_schema` serialization fails, invoking `logger` if provided).
    def build_manifest(logger : Proc(String, Nil)? = nil) : Hash(String, JSON::Any)
      manifest = {} of String => JSON::Any

      init_result = capture_initialize_manifest(logger)
      return manifest unless init_result

      manifest["initializeResult"] = init_result
      handle_jsonrpc(JSONRPCMessage.new(method: "notifications/initialized"))

      if tools_list = capture_tools_list_manifest(init_result, logger)
        manifest["toolsListResult"] = tools_list
      end

      manifest
    end

    private def capture_initialize_manifest(logger : Proc(String, Nil)?) : JSON::Any?
      init_response = handle_jsonrpc(
        JSONRPCMessage.new(
          method: "initialize",
          id: JSON::Any.new("manifest-initialize"),
          params: {
            "protocolVersion" => JSON::Any.new(PROTOCOL_VERSION),
            "capabilities"    => JSON::Any.new({} of String => JSON::Any),
            "clientInfo"      => JSON::Any.new({
              "name"    => JSON::Any.new("claude-agent-cr"),
              "version" => JSON::Any.new(VERSION),
            }),
          },
        )
      )
      init_result = init_response.result
      if init_response.error || init_result.nil?
        logger.try(&.call(
          "SDK MCP server #{@name.inspect} initialize failed during manifest capture: " \
          "#{init_response.error.try(&.message) || "missing result"}",
        ))
        return
      end

      init_result
    end

    private def capture_tools_list_manifest(
      init_result : JSON::Any,
      logger : Proc(String, Nil)?,
    ) : JSON::Any?
      capabilities = init_result.as_h?.try(&.["capabilities"]?.try(&.as_h?))
      tools_cap = capabilities.try(&.["tools"]?)
      return if tools_cap.nil? || tools_cap.raw.nil?

      tools_response = handle_jsonrpc(
        JSONRPCMessage.new(
          method: "tools/list",
          id: JSON::Any.new("manifest-tools-list"),
        )
      )
      tools_result = tools_response.result
      if tools_response.error || tools_result.nil?
        logger.try(&.call(
          "SDK MCP server #{@name.inspect} tools/list failed during manifest capture: " \
          "#{tools_response.error.try(&.message) || "missing result"}",
        ))
        return
      end

      tools_hash = tools_result.as_h?
      return unless tools_hash

      next_cursor = tools_hash["nextCursor"]?
      return if next_cursor && !next_cursor.raw.nil?

      sanitize_tools_list_result(tools_hash, logger)
    end

    private def sanitize_tools_list_result(
      tools_hash : Hash(String, JSON::Any),
      logger : Proc(String, Nil)?,
    ) : JSON::Any
      tools = tools_hash["tools"]?.try(&.as_a?)
      return JSON::Any.new(tools_hash) unless tools

      valid_tools = [] of JSON::Any
      tools.each do |entry|
        tool_name = entry.as_h?.try(&.["name"]?.try(&.as_s?)) || "<unknown>"
        begin
          entry.to_json
          valid_tools << entry
        rescue ex
          logger.try(&.call(
            "Tool #{tool_name.inspect} on SDK MCP server #{@name.inspect} was omitted from " \
            "the manifest because its input_schema serialization failed: #{ex.message}",
          ))
        end
      end

      sanitized = tools_hash.dup
      sanitized["tools"] = JSON::Any.new(valid_tools)
      JSON::Any.new(sanitized)
    end
  end

  # Helper to create SDK MCP servers
  def self.create_sdk_mcp_server(
    name : String,
    version : String = "1.0.0",
    tools : Array(SDKTool) = [] of SDKTool,
    timeout : Int32? = nil,
    tool_policies : Array(MCPServerToolPolicy)? = nil,
  ) : SDKMCPServer
    SDKMCPServer.new(
      name: name,
      version: version,
      tools: tools,
      timeout: timeout,
      tool_policies: tool_policies,
    )
  end
end
