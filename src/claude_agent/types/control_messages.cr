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
    @[JSON::Field(key: "promptSuggestions")]
    getter prompt_suggestions : Bool?
    @[JSON::Field(key: "agentProgressSummaries")]
    getter agent_progress_summaries : Bool?
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
    @[JSON::Field(key: "permission_suggestions")]
    getter permission_suggestions : Array(JSON::Any)?
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

  # Set model request
  struct ControlSetModelRequest
    include JSON::Serializable

    getter subtype : String = "set_model"
    getter model : String?
  end

  struct ControlSetMaxThinkingTokensRequest
    include JSON::Serializable

    getter subtype : String = "set_max_thinking_tokens"
    @[JSON::Field(key: "max_thinking_tokens")]
    getter max_thinking_tokens : Int32?
  end

  struct ControlGetSettingsRequest
    include JSON::Serializable

    getter subtype : String = "get_settings"
  end

  struct ControlCancelAsyncMessageRequest
    include JSON::Serializable

    getter subtype : String = "cancel_async_message"
    @[JSON::Field(key: "message_uuid")]
    getter message_uuid : String
  end

  struct ControlApplyFlagSettingsRequest
    include JSON::Serializable

    getter subtype : String = "apply_flag_settings"
    getter settings : Hash(String, JSON::Any)
  end

  struct ControlRemoteControlRequest
    include JSON::Serializable

    getter subtype : String = "remote_control"
    getter? enabled : Bool
  end

  struct ControlSetProactiveRequest
    include JSON::Serializable

    getter subtype : String = "set_proactive"
    getter? enabled : Bool
  end

  struct ControlGenerateSessionTitleRequest
    include JSON::Serializable

    getter subtype : String = "generate_session_title"
    getter description : String
    getter? persist : Bool = false
  end

  # Query MCP status request
  struct ControlMCPStatusRequest
    include JSON::Serializable

    getter subtype : String = "mcp_status"
  end

  # Reconnect an MCP server request
  struct ControlMCPReconnectRequest
    include JSON::Serializable

    getter subtype : String = "mcp_reconnect"
    @[JSON::Field(key: "serverName")]
    getter server_name : String
  end

  # Enable/disable an MCP server request
  struct ControlMCPToggleRequest
    include JSON::Serializable

    getter subtype : String = "mcp_toggle"
    @[JSON::Field(key: "serverName")]
    getter server_name : String
    getter? enabled : Bool
  end

  # Stop a running task request
  struct ControlStopTaskRequest
    include JSON::Serializable

    getter subtype : String = "stop_task"
    @[JSON::Field(key: "task_id")]
    getter task_id : String
  end

  # Hook callback request
  struct ControlHookCallbackRequest
    include JSON::Serializable

    getter subtype : String = "hook_callback"
    @[JSON::Field(key: "callback_id")]
    getter callback_id : String
    getter input : Hash(String, JSON::Any)?
    @[JSON::Field(key: "tool_use_id")]
    getter tool_use_id : String?
  end

  struct ControlElicitationRequest
    include JSON::Serializable

    getter subtype : String = "elicitation"
    @[JSON::Field(key: "mcp_server_name")]
    getter mcp_server_name : String
    getter message : String
    getter mode : String?
    getter url : String?
    @[JSON::Field(key: "elicitation_id")]
    getter elicitation_id : String?
    @[JSON::Field(key: "requested_schema")]
    getter requested_schema : Hash(String, JSON::Any)?
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
                              ControlSetModelRequest |
                              ControlSetMaxThinkingTokensRequest |
                              ControlGetSettingsRequest |
                              ControlCancelAsyncMessageRequest |
                              ControlApplyFlagSettingsRequest |
                              ControlRemoteControlRequest |
                              ControlSetProactiveRequest |
                              ControlGenerateSessionTitleRequest |
                              ControlMCPStatusRequest |
                              ControlMCPReconnectRequest |
                              ControlMCPToggleRequest |
                              ControlStopTaskRequest |
                              ControlElicitationRequest |
                              ControlHookCallbackRequest |
                              ControlRewindFilesRequest

  # Converter for parsing control request inner based on subtype
  module ControlRequestInnerConverter
    PARSERS = {
      "initialize"              => ->(json : String) { ControlInitializeRequest.from_json(json).as(ControlRequestInner) },
      "mcp_message"             => ->(json : String) { ControlMCPMessageRequest.from_json(json).as(ControlRequestInner) },
      "can_use_tool"            => ->(json : String) { ControlPermissionRequest.from_json(json).as(ControlRequestInner) },
      "interrupt"               => ->(json : String) { ControlInterruptRequest.from_json(json).as(ControlRequestInner) },
      "set_permission_mode"     => ->(json : String) { ControlSetPermissionModeRequest.from_json(json).as(ControlRequestInner) },
      "set_model"               => ->(json : String) { ControlSetModelRequest.from_json(json).as(ControlRequestInner) },
      "set_max_thinking_tokens" => ->(json : String) { ControlSetMaxThinkingTokensRequest.from_json(json).as(ControlRequestInner) },
      "get_settings"            => ->(json : String) { ControlGetSettingsRequest.from_json(json).as(ControlRequestInner) },
      "cancel_async_message"    => ->(json : String) { ControlCancelAsyncMessageRequest.from_json(json).as(ControlRequestInner) },
      "apply_flag_settings"     => ->(json : String) { ControlApplyFlagSettingsRequest.from_json(json).as(ControlRequestInner) },
      "remote_control"          => ->(json : String) { ControlRemoteControlRequest.from_json(json).as(ControlRequestInner) },
      "set_proactive"           => ->(json : String) { ControlSetProactiveRequest.from_json(json).as(ControlRequestInner) },
      "generate_session_title"  => ->(json : String) { ControlGenerateSessionTitleRequest.from_json(json).as(ControlRequestInner) },
      "mcp_status"              => ->(json : String) { ControlMCPStatusRequest.from_json(json).as(ControlRequestInner) },
      "mcp_reconnect"           => ->(json : String) { ControlMCPReconnectRequest.from_json(json).as(ControlRequestInner) },
      "mcp_toggle"              => ->(json : String) { ControlMCPToggleRequest.from_json(json).as(ControlRequestInner) },
      "stop_task"               => ->(json : String) { ControlStopTaskRequest.from_json(json).as(ControlRequestInner) },
      "elicitation"             => ->(json : String) { ControlElicitationRequest.from_json(json).as(ControlRequestInner) },
      "hook_callback"           => ->(json : String) { ControlHookCallbackRequest.from_json(json).as(ControlRequestInner) },
      "rewind_files"            => ->(json : String) { ControlRewindFilesRequest.from_json(json).as(ControlRequestInner) },
    }

    def self.from_json(pull : JSON::PullParser) : ControlRequestInner
      json_str = pull.read_raw
      data = JSON.parse(json_str)
      subtype = data["subtype"]?.try(&.as_s)

      parser = subtype.try { |value| PARSERS[value]? }
      raise Error.new("Unknown control request subtype: #{subtype}") unless parser

      parser.call(json_str)
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

  struct MCPToolAnnotations
    include JSON::Serializable

    @[JSON::Field(key: "readOnly")]
    getter read_only : Bool?
    getter destructive : Bool?
    @[JSON::Field(key: "openWorld")]
    getter open_world : Bool?
  end

  struct MCPToolInfo
    include JSON::Serializable

    getter name : String
    getter description : String?
    getter annotations : MCPToolAnnotations?
  end

  struct MCPServerInfo
    include JSON::Serializable

    getter name : String
    getter version : String
  end

  struct MCPServerStatus
    include JSON::Serializable

    getter name : String
    getter status : String
    @[JSON::Field(key: "serverInfo")]
    getter server_info : MCPServerInfo?
    getter error : String?
    getter config : Hash(String, JSON::Any)?
    getter scope : String?
    getter tools : Array(MCPToolInfo)?
  end

  struct MCPStatusResponse
    include JSON::Serializable

    @[JSON::Field(key: "mcpServers")]
    getter mcp_servers : Array(MCPServerStatus)

    def initialize(@mcp_servers : Array(MCPServerStatus))
    end
  end
end
