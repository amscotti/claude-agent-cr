require "json"
require "./content_blocks"
require "./control_messages"

module ClaudeAgent
  # Base message type
  abstract struct Message
    def self.parse(json : String) : Message
      data = JSON.parse(json)
      type = data["type"]?.try(&.as_s)

      case type
      when "assistant"
        AssistantMessage.from_json(json)
      when "user"
        UserMessage.from_json(json)
      when "system"
        SystemMessage.from_json(json)
      when "result"
        ResultMessage.from_json(json)
      when "permission_request"
        PermissionRequest.from_json(json)
      when "user_question"
        UserQuestion.from_json(json)
      when "stream_event"
        StreamEvent.from_json(json)
      when "control_request"
        ControlRequest.from_json(json)
      when "control_response"
        # Control responses are acknowledgments of our requests - parse but handle specially
        ControlResponseMessage.from_json(json)
      else
        raise Error.new("Unknown message type: #{type}")
      end
    end
  end

  struct AssistantMessageBody
    include JSON::Serializable
    @[JSON::Field(converter: ClaudeAgent::ContentBlockArrayConverter)]
    getter content : Array(ContentBlock)

    getter model : String?
  end

  struct AssistantMessageError
    include JSON::Serializable
    getter type : String
    getter message : String

    def initialize(@type : String, @message : String)
    end
  end

  # Converter to handle error field that can be either a string or an object
  module ErrorConverter
    def self.from_json(pull : JSON::PullParser) : AssistantMessageError?
      case pull.kind
      when .null?
        pull.read_null
        nil
      when .string?
        # Error is a simple string like "unknown"
        error_str = pull.read_string
        AssistantMessageError.new(type: "error", message: error_str)
      when .begin_object?
        # Error is a full object with type and message
        AssistantMessageError.new(pull)
      else
        pull.raise "Expected null, string, or object for error field"
      end
    end

    def self.to_json(value : AssistantMessageError?, builder : JSON::Builder)
      if v = value
        v.to_json(builder)
      else
        builder.null
      end
    end
  end

  # Message from the assistant
  struct AssistantMessage < Message
    include JSON::Serializable

    getter type : String = "assistant"
    getter uuid : String
    getter session_id : String

    getter message : AssistantMessageBody
    @[JSON::Field(converter: ClaudeAgent::ErrorConverter)]
    getter error : AssistantMessageError?

    getter parent_tool_use_id : String?

    def content
      message.content
    end

    def model
      message.model
    end

    def text : String
      content.compact_map { |block| block.is_a?(TextBlock) ? block.text : nil }.join
    end

    # Returns tool names used in this message
    def tool_uses : Array(String)
      content.compact_map { |block| block.is_a?(ToolUseBlock) ? block.name : nil }
    end

    # Returns true if this message contains any text content
    def has_text? : Bool
      content.any? { |block| block.is_a?(TextBlock) && !block.text.empty? }
    end

    # Returns true if this message is from a subagent
    def from_subagent? : Bool
      !parent_tool_use_id.nil?
    end
  end

  struct PermissionRequest < Message
    include JSON::Serializable
    getter type : String = "permission_request"
    getter tool_use_id : String
    getter tool_name : String
    getter tool_input : Hash(String, JSON::Any)
  end

  struct UserQuestion < Message
    include JSON::Serializable
    getter type : String = "user_question"
    getter uuid : String
    getter message : String
  end

  # Message from the user
  struct UserMessage < Message
    include JSON::Serializable

    getter type : String = "user"
    getter uuid : String?
    getter session_id : String
    getter message : Hash(String, JSON::Any)
    getter parent_tool_use_id : String?
  end

  # System initialization message
  struct SystemMessage < Message
    include JSON::Serializable

    getter type : String = "system"
    getter subtype : String
    getter session_id : String
  end

  # Final result message
  struct ResultMessage < Message
    include JSON::Serializable

    getter type : String = "result"
    getter uuid : String
    getter session_id : String
    getter subtype : String
    getter result : String?
    getter cost_usd : Float64?
    getter duration_ms : Int64?
    getter duration_api_ms : Int64?
    getter is_error : Bool?
    getter num_turns : Int32?
    getter total_cost_usd : Float64?
    getter structured_output : JSON::Any?
    getter usage : Hash(String, JSON::Any)?

    # --- Structured Output Helpers ---

    # Check if the result was successful
    def success? : Bool
      subtype == "success"
    end

    # Check if structured output is present and not null
    def has_structured_output? : Bool
      so = structured_output
      return false if so.nil?
      # Try to check if it's null JSON value
      begin
        so.as_nil
        false # If as_nil succeeds, it IS null
      rescue
        true # If as_nil raises, it's NOT null (has actual value)
      end
    end

    # Get structured output as a Hash (returns nil if not an object)
    def structured_output_hash : Hash(String, JSON::Any)?
      structured_output.try(&.as_h?)
    end

    # Get structured output as an Array (returns nil if not an array)
    def structured_output_array : Array(JSON::Any)?
      structured_output.try(&.as_a?)
    end

    # Get a value from structured output by key
    def get_output(key : String) : JSON::Any?
      structured_output_hash.try(&.[key]?)
    end

    # Get a string value from structured output
    def get_output_string(key : String) : String?
      get_output(key).try(&.as_s?)
    end

    # Get an integer value from structured output
    def get_output_int(key : String) : Int64?
      get_output(key).try(&.as_i64?)
    end

    # Get a float value from structured output
    def get_output_float(key : String) : Float64?
      get_output(key).try(&.as_f?)
    end

    # Get a boolean value from structured output
    def get_output_bool(key : String) : Bool?
      get_output(key).try(&.as_bool?)
    end

    # Get an array value from structured output
    def get_output_array(key : String) : Array(JSON::Any)?
      get_output(key).try(&.as_a?)
    end

    # Get a nested object from structured output
    def get_output_hash(key : String) : Hash(String, JSON::Any)?
      get_output(key).try(&.as_h?)
    end

    # Iterate over structured output if it's an object
    def each_output(&)
      structured_output_hash.try(&.each { |key, value| yield key, value })
    end
  end

  # Streaming event for partial content (when include_partial_messages is true)
  struct StreamEvent < Message
    include JSON::Serializable

    getter type : String = "stream_event"
    getter uuid : String
    getter session_id : String
    getter event : Hash(String, JSON::Any)
    getter parent_tool_use_id : String?
  end

  # Control request from CLI to SDK (for SDK MCP server integration)
  # This message type is used by the CLI to route tool calls back to SDK MCP servers
  struct ControlRequest < Message
    include JSON::Serializable

    getter type : String = "control_request"
    @[JSON::Field(key: "request_id")]
    getter request_id : String
    @[JSON::Field(converter: ClaudeAgent::ControlRequestInnerConverter)]
    getter request : ControlRequestInner
  end

  # Control response from CLI (acknowledgment of our control requests)
  # These are responses to requests we sent, not requests for us to handle
  struct ControlResponseMessage < Message
    include JSON::Serializable

    getter type : String = "control_response"
    getter response : Hash(String, JSON::Any)
  end
end
