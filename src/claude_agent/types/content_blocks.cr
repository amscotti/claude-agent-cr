require "json"

module ClaudeAgent
  alias ContentBlock = TextBlock | ToolUseBlock | ToolResultBlock | ThinkingBlock | RedactedThinkingBlock | UnknownBlock

  struct TextBlock
    include JSON::Serializable

    getter type : String = "text"
    getter text : String
  end

  struct ToolUseBlock
    include JSON::Serializable

    getter type : String = "tool_use"
    getter id : String
    getter name : String
    getter input : Hash(String, JSON::Any)
  end

  struct ToolResultBlock
    include JSON::Serializable

    getter type : String = "tool_result"
    getter tool_use_id : String
    getter content : String | Array(Hash(String, JSON::Any))?
    getter is_error : Bool?
  end

  struct ThinkingBlock
    include JSON::Serializable

    getter type : String = "thinking"
    getter thinking : String
    getter signature : String
  end

  struct RedactedThinkingBlock
    include JSON::Serializable

    getter type : String = "redacted_thinking"
    getter data : String
  end

  struct UnknownBlock
    include JSON::Serializable

    getter type : String
    @[JSON::Field(ignore: true)]
    getter raw_json : String = ""

    def initialize(@type : String, @raw_json : String = "")
    end
  end

  module ContentBlockConverter
    def self.from_json(pull : JSON::PullParser) : ContentBlock
      json = pull.read_raw
      data = JSON.parse(json)
      type = data["type"].as_s

      case type
      when "text"
        TextBlock.from_json(json)
      when "tool_use"
        ToolUseBlock.from_json(json)
      when "tool_result"
        ToolResultBlock.from_json(json)
      when "thinking"
        ThinkingBlock.from_json(json)
      when "redacted_thinking"
        RedactedThinkingBlock.from_json(json)
      else
        block = UnknownBlock.from_json(json)
        UnknownBlock.new(type: block.type, raw_json: json)
      end
    end
  end

  module ContentBlockArrayConverter
    def self.from_json(pull : JSON::PullParser) : Array(ContentBlock)
      ary = [] of ContentBlock
      pull.read_array do
        ary << ContentBlockConverter.from_json(pull)
      end
      ary
    end
  end
end
