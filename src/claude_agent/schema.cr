require "json"

module ClaudeAgent
  # Type-safe JSON Schema builder for tool definitions.
  # Crystal's answer to Zod - uses the type system to generate schemas.
  #
  # Example:
  #   schema = Schema.object({
  #     "name" => Schema.string("User's name"),
  #     "age" => Schema.integer("User's age", minimum: 0, maximum: 150),
  #     "email" => Schema.string("Email address", format: "email"),
  #     "tags" => Schema.array(Schema.string, "List of tags"),
  #   }, required: ["name", "email"])
  #
  module Schema
    # Base schema type - using class instead of struct to allow recursive types
    abstract class SchemaType
      abstract def to_json_schema : Hash(String, JSON::Any)
    end

    # String schema
    class StringSchema < SchemaType
      getter description : String?
      getter min_length : Int32?
      getter max_length : Int32?
      getter pattern : String?
      getter format : String?
      getter enum_values : Array(String)?

      def initialize(
        @description : String? = nil,
        @min_length : Int32? = nil,
        @max_length : Int32? = nil,
        @pattern : String? = nil,
        @format : String? = nil,
        @enum_values : Array(String)? = nil,
      )
      end

      def to_json_schema : Hash(String, JSON::Any)
        schema = {"type" => JSON::Any.new("string")}
        @description.try { |desc| schema["description"] = JSON::Any.new(desc) }
        @min_length.try { |val| schema["minLength"] = JSON::Any.new(val.to_i64) }
        @max_length.try { |val| schema["maxLength"] = JSON::Any.new(val.to_i64) }
        @pattern.try { |val| schema["pattern"] = JSON::Any.new(val) }
        @format.try { |val| schema["format"] = JSON::Any.new(val) }
        @enum_values.try { |values| schema["enum"] = JSON::Any.new(values.map { |val| JSON::Any.new(val) }) }
        schema
      end
    end

    # Integer schema
    class IntegerSchema < SchemaType
      getter description : String?
      getter minimum : Int64?
      getter maximum : Int64?
      getter exclusive_minimum : Int64?
      getter exclusive_maximum : Int64?

      def initialize(
        @description : String? = nil,
        @minimum : Int64? = nil,
        @maximum : Int64? = nil,
        @exclusive_minimum : Int64? = nil,
        @exclusive_maximum : Int64? = nil,
      )
      end

      def to_json_schema : Hash(String, JSON::Any)
        schema = {"type" => JSON::Any.new("integer")}
        @description.try { |desc| schema["description"] = JSON::Any.new(desc) }
        @minimum.try { |val| schema["minimum"] = JSON::Any.new(val) }
        @maximum.try { |val| schema["maximum"] = JSON::Any.new(val) }
        @exclusive_minimum.try { |val| schema["exclusiveMinimum"] = JSON::Any.new(val) }
        @exclusive_maximum.try { |val| schema["exclusiveMaximum"] = JSON::Any.new(val) }
        schema
      end
    end

    # Number schema (float)
    class NumberSchema < SchemaType
      getter description : String?
      getter minimum : Float64?
      getter maximum : Float64?

      def initialize(
        @description : String? = nil,
        @minimum : Float64? = nil,
        @maximum : Float64? = nil,
      )
      end

      def to_json_schema : Hash(String, JSON::Any)
        schema = {"type" => JSON::Any.new("number")}
        @description.try { |desc| schema["description"] = JSON::Any.new(desc) }
        @minimum.try { |val| schema["minimum"] = JSON::Any.new(val) }
        @maximum.try { |val| schema["maximum"] = JSON::Any.new(val) }
        schema
      end
    end

    # Boolean schema
    class BooleanSchema < SchemaType
      getter description : String?

      def initialize(@description : String? = nil)
      end

      def to_json_schema : Hash(String, JSON::Any)
        schema = {"type" => JSON::Any.new("boolean")}
        @description.try { |desc| schema["description"] = JSON::Any.new(desc) }
        schema
      end
    end

    # Array schema
    class ArraySchema < SchemaType
      getter items : SchemaType
      getter description : String?
      getter min_items : Int32?
      getter max_items : Int32?
      getter unique_items : Bool?

      def initialize(
        @items : SchemaType,
        @description : String? = nil,
        @min_items : Int32? = nil,
        @max_items : Int32? = nil,
        @unique_items : Bool? = nil,
      )
      end

      def to_json_schema : Hash(String, JSON::Any)
        schema = {
          "type"  => JSON::Any.new("array"),
          "items" => JSON::Any.new(@items.to_json_schema),
        }
        @description.try { |desc| schema["description"] = JSON::Any.new(desc) }
        @min_items.try { |val| schema["minItems"] = JSON::Any.new(val.to_i64) }
        @max_items.try { |val| schema["maxItems"] = JSON::Any.new(val.to_i64) }
        unless @unique_items.nil?
          schema["uniqueItems"] = JSON::Any.new(@unique_items.as(Bool))
        end
        schema
      end
    end

    # Object schema
    class ObjectSchema < SchemaType
      getter properties : Hash(String, SchemaType)
      getter required : Array(String)?
      getter description : String?
      getter additional_properties : Bool?

      def initialize(
        @properties : Hash(String, SchemaType),
        @required : Array(String)? = nil,
        @description : String? = nil,
        @additional_properties : Bool? = nil,
      )
      end

      def to_json_schema : Hash(String, JSON::Any)
        props = {} of String => JSON::Any
        @properties.each do |key, prop_schema|
          props[key] = JSON::Any.new(prop_schema.to_json_schema)
        end

        schema = {
          "type"       => JSON::Any.new("object"),
          "properties" => JSON::Any.new(props),
        }
        @description.try { |desc| schema["description"] = JSON::Any.new(desc) }
        @required.try { |req| schema["required"] = JSON::Any.new(req.map { |item| JSON::Any.new(item) }) }
        unless @additional_properties.nil?
          schema["additionalProperties"] = JSON::Any.new(@additional_properties.as(Bool))
        end
        schema
      end
    end

    # Enum schema (for string literals)
    class EnumSchema < SchemaType
      getter values : Array(String)
      getter description : String?

      def initialize(@values : Array(String), @description : String? = nil)
      end

      def to_json_schema : Hash(String, JSON::Any)
        schema = {
          "type" => JSON::Any.new("string"),
          "enum" => JSON::Any.new(@values.map { |val| JSON::Any.new(val) }),
        }
        @description.try { |desc| schema["description"] = JSON::Any.new(desc) }
        schema
      end
    end

    # Null schema
    class NullSchema < SchemaType
      def to_json_schema : Hash(String, JSON::Any)
        {"type" => JSON::Any.new("null")}
      end
    end

    # Union schema (oneOf)
    class UnionSchema < SchemaType
      getter schemas : Array(SchemaType)
      getter description : String?

      def initialize(@schemas : Array(SchemaType), @description : String? = nil)
      end

      def to_json_schema : Hash(String, JSON::Any)
        schema = {
          "oneOf" => JSON::Any.new(@schemas.map { |child| JSON::Any.new(child.to_json_schema) }),
        }
        @description.try { |desc| schema["description"] = JSON::Any.new(desc) }
        schema
      end
    end

    # Factory methods for creating schemas

    def self.string(description : String? = nil, **options) : StringSchema
      StringSchema.new(
        description: description,
        min_length: options[:min_length]?,
        max_length: options[:max_length]?,
        pattern: options[:pattern]?,
        format: options[:format]?,
        enum_values: options[:enum]?
      )
    end

    def self.integer(description : String? = nil, **options) : IntegerSchema
      IntegerSchema.new(
        description: description,
        minimum: options[:minimum]?.try(&.to_i64),
        maximum: options[:maximum]?.try(&.to_i64),
        exclusive_minimum: options[:exclusive_minimum]?.try(&.to_i64),
        exclusive_maximum: options[:exclusive_maximum]?.try(&.to_i64)
      )
    end

    def self.number(description : String? = nil, **options) : NumberSchema
      NumberSchema.new(
        description: description,
        minimum: options[:minimum]?.try(&.to_f64),
        maximum: options[:maximum]?.try(&.to_f64)
      )
    end

    def self.boolean(description : String? = nil) : BooleanSchema
      BooleanSchema.new(description)
    end

    def self.array(items : SchemaType, description : String? = nil, **options) : ArraySchema
      ArraySchema.new(
        items: items,
        description: description,
        min_items: options[:min_items]?,
        max_items: options[:max_items]?,
        unique_items: options[:unique_items]?
      )
    end

    def self.object(
      properties : Hash(String, T),
      required : Array(String)? = nil,
      description : String? = nil,
      additional_properties : Bool? = nil,
    ) : ObjectSchema forall T
      # Convert to SchemaType hash for type compatibility
      typed_props = {} of String => SchemaType
      properties.each { |key, val| typed_props[key] = val }
      ObjectSchema.new(
        properties: typed_props,
        required: required,
        description: description,
        additional_properties: additional_properties
      )
    end

    def self.enum(values : Array(String), description : String? = nil) : EnumSchema
      EnumSchema.new(values, description)
    end

    def self.null : NullSchema
      NullSchema.new
    end

    def self.union(*schemas : SchemaType, description : String? = nil) : UnionSchema
      UnionSchema.new(schemas.to_a, description)
    end

    # Optional helper - creates a union with null
    def self.optional(schema : SchemaType) : UnionSchema
      UnionSchema.new([schema, NullSchema.new] of SchemaType)
    end
  end
end
