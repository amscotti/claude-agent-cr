require "json"

module ClaudeAgent
  # JSON-RPC 2.0 message for MCP protocol
  struct JSONRPCMessage
    include JSON::Serializable

    getter jsonrpc : String = "2.0"
    getter id : JSON::Any? # Can be string, int, or null for notifications
    getter method : String?
    getter params : Hash(String, JSON::Any)?

    def initialize(
      @method : String? = nil,
      @params : Hash(String, JSON::Any)? = nil,
      @id : JSON::Any? = nil,
      @jsonrpc : String = "2.0",
    )
    end

    # Check if this is a notification (no id)
    def notification? : Bool
      id.nil?
    end
  end

  # JSON-RPC 2.0 error object
  struct JSONRPCError
    include JSON::Serializable

    property code : Int32
    property message : String
    property data : JSON::Any?

    def initialize(@code : Int32, @message : String, @data : JSON::Any? = nil)
    end

    # Standard JSON-RPC error codes
    PARSE_ERROR      = -32700
    INVALID_REQUEST  = -32600
    METHOD_NOT_FOUND = -32601
    INVALID_PARAMS   = -32602
    INTERNAL_ERROR   = -32603
  end

  # JSON-RPC 2.0 response
  struct JSONRPCResponse
    include JSON::Serializable

    property jsonrpc : String = "2.0"
    property id : JSON::Any?
    property result : JSON::Any?
    property error : JSONRPCError?

    def initialize(
      @id : JSON::Any? = nil,
      @result : JSON::Any? = nil,
      @error : JSONRPCError? = nil,
      @jsonrpc : String = "2.0",
    )
    end

    def self.success(id : JSON::Any?, result : JSON::Any) : JSONRPCResponse
      new(id: id, result: result)
    end

    def self.error(id : JSON::Any?, code : Int32, message : String, data : JSON::Any? = nil) : JSONRPCResponse
      new(id: id, error: JSONRPCError.new(code, message, data))
    end
  end

  # --- Control Request Subtypes ---

  # Initialize request (handshake)
  struct ControlInitializeRequest
    include JSON::Serializable

    getter subtype : String = "initialize"
    getter hooks : Hash(String, JSON::Any)?
    @[JSON::Field(key: "sdkMcpServers")]
    getter sdk_mcp_servers : Array(String)?
    @[JSON::Field(key: "jsonSchema")]
    getter json_schema : Hash(String, JSON::Any)?
    @[JSON::Field(key: "systemPrompt")]
    getter system_prompt : String?
    @[JSON::Field(key: "appendSystemPrompt")]
    getter append_system_prompt : String?
    getter agents : Hash(String, JSON::Any)?
  end

  # MCP message request (tool calls routed back to SDK)
  struct ControlMCPMessageRequest
    include JSON::Serializable

    getter subtype : String = "mcp_message"
    @[JSON::Field(key: "server_name")]
    getter server_name : String
    getter message : JSONRPCMessage
  end

  # Permission check request
  struct ControlPermissionRequest
    include JSON::Serializable

    getter subtype : String = "can_use_tool"
    @[JSON::Field(key: "tool_name")]
    getter tool_name : String
    getter input : Hash(String, JSON::Any)
  end

  # Interrupt request
  struct ControlInterruptRequest
    include JSON::Serializable

    getter subtype : String = "interrupt"
  end

  # Set permission mode request
  struct ControlSetPermissionModeRequest
    include JSON::Serializable

    getter subtype : String = "set_permission_mode"
    getter mode : String
  end

  # Hook callback request
  struct ControlHookCallbackRequest
    include JSON::Serializable

    getter subtype : String = "hook_callback"
    getter hook : String
    getter input : Hash(String, JSON::Any)?
  end

  # Rewind files request
  struct ControlRewindFilesRequest
    include JSON::Serializable

    getter subtype : String = "rewind_files"
    @[JSON::Field(key: "user_message_uuid")]
    getter user_message_uuid : String
  end

  # Union type for control request inner payload
  # Note: Crystal doesn't have true union types for JSON, so we parse manually
  alias ControlRequestInner = ControlInitializeRequest |
                              ControlMCPMessageRequest |
                              ControlPermissionRequest |
                              ControlInterruptRequest |
                              ControlSetPermissionModeRequest |
                              ControlHookCallbackRequest |
                              ControlRewindFilesRequest

  # Converter for parsing control request inner based on subtype
  module ControlRequestInnerConverter
    def self.from_json(pull : JSON::PullParser) : ControlRequestInner
      # First, read the raw JSON to peek at the subtype
      json_str = pull.read_raw
      data = JSON.parse(json_str)
      subtype = data["subtype"]?.try(&.as_s)

      case subtype
      when "initialize"
        ControlInitializeRequest.from_json(json_str)
      when "mcp_message"
        ControlMCPMessageRequest.from_json(json_str)
      when "can_use_tool"
        ControlPermissionRequest.from_json(json_str)
      when "interrupt"
        ControlInterruptRequest.from_json(json_str)
      when "set_permission_mode"
        ControlSetPermissionModeRequest.from_json(json_str)
      when "hook_callback"
        ControlHookCallbackRequest.from_json(json_str)
      when "rewind_files"
        ControlRewindFilesRequest.from_json(json_str)
      else
        raise Error.new("Unknown control request subtype: #{subtype}")
      end
    end

    def self.to_json(value : ControlRequestInner, builder : JSON::Builder)
      value.to_json(builder)
    end
  end

  # Note: ControlRequest is defined in messages.cr to avoid circular dependency
  # It inherits from Message and uses ControlRequestInner defined here

  # --- Control Response Types ---

  # Success response payload
  struct ControlResponseSuccess
    include JSON::Serializable

    getter subtype : String = "success"
    @[JSON::Field(key: "request_id")]
    property request_id : String
    property response : JSON::Any?

    def initialize(@request_id : String, @response : JSON::Any? = nil)
    end
  end

  # Error response payload
  struct ControlResponseError
    include JSON::Serializable

    getter subtype : String = "error"
    @[JSON::Field(key: "request_id")]
    property request_id : String
    property error : String

    def initialize(@request_id : String, @error : String)
    end
  end

  # Control response from SDK to CLI
  struct ControlResponse
    include JSON::Serializable

    property type : String = "control_response"
    property response : Hash(String, JSON::Any)

    def initialize(@response : Hash(String, JSON::Any))
    end

    # Create a success response
    def self.success(request_id : String, result : JSON::Any? = nil) : ControlResponse
      response = {
        "subtype"    => JSON::Any.new("success"),
        "request_id" => JSON::Any.new(request_id),
      }
      response["response"] = result if result
      new(response)
    end

    # Create an error response
    def self.error(request_id : String, error_message : String) : ControlResponse
      response = {
        "subtype"    => JSON::Any.new("error"),
        "request_id" => JSON::Any.new(request_id),
        "error"      => JSON::Any.new(error_message),
      }
      new(response)
    end

    # Create an MCP response (for mcp_message requests)
    def self.mcp_response(request_id : String, mcp_result : JSON::Any) : ControlResponse
      response = {
        "subtype"      => JSON::Any.new("success"),
        "request_id"   => JSON::Any.new(request_id),
        "mcp_response" => mcp_result,
      }
      new(response)
    end
  end
end
