require "json"

module ClaudeAgent
  struct ToolResultContent
    include JSON::Serializable
    property type : String
    property text : String?
    property data : String? # base64 for images
    property mime_type : String?

    def initialize(@type : String, @text : String? = nil, @data : String? = nil, @mime_type : String? = nil)
    end
  end

  struct ToolResult
    getter content : Array(ToolResultContent)
    getter? is_error : Bool

    def initialize(@content : Array(ToolResultContent), @is_error : Bool = false)
    end

    def self.text(text : String) : ToolResult
      new([ToolResultContent.new(type: "text", text: text)])
    end

    def self.error(message : String) : ToolResult
      new([ToolResultContent.new(type: "text", text: message)], is_error: true)
    end
  end

  struct SDKTool
    getter name : String
    getter description : String
    getter input_schema : Hash(String, JSON::Any)
    getter handler : Proc(Hash(String, JSON::Any), ToolResult)

    def initialize(
      @name : String,
      @description : String,
      @input_schema : Hash(String, JSON::Any),
      @handler : Proc(Hash(String, JSON::Any), ToolResult),
    )
    end

    def call(args : Hash(String, JSON::Any)) : ToolResult
      @handler.call(args)
    end
  end

  # Tool definition helper - accepts Hash schema directly
  def self.tool(
    name : String,
    description : String,
    schema : Hash(String, JSON::Any),
    &block : Hash(String, JSON::Any) -> ToolResult
  ) : SDKTool
    SDKTool.new(
      name: name,
      description: description,
      input_schema: schema,
      handler: block
    )
  end

  # Tool definition helper - accepts Schema::SchemaType (type-safe)
  def self.tool(
    name : String,
    description : String,
    schema : Schema::SchemaType,
    &block : Hash(String, JSON::Any) -> ToolResult
  ) : SDKTool
    SDKTool.new(
      name: name,
      description: description,
      input_schema: schema.to_json_schema,
      handler: block
    )
  end
end
