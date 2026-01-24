require "./spec_helper"

describe ClaudeAgent::Schema do
  describe ".string" do
    it "creates a basic string schema" do
      schema = ClaudeAgent::Schema.string("A name")
      json = schema.to_json_schema

      json["type"].should eq(JSON::Any.new("string"))
      json["description"].should eq(JSON::Any.new("A name"))
    end

    it "supports all string options" do
      schema = ClaudeAgent::Schema.string(
        "An email",
        min_length: 5,
        max_length: 100,
        pattern: "^[a-z]+$",
        format: "email"
      )
      json = schema.to_json_schema

      json["type"].should eq(JSON::Any.new("string"))
      json["description"].should eq(JSON::Any.new("An email"))
      json["minLength"].should eq(JSON::Any.new(5_i64))
      json["maxLength"].should eq(JSON::Any.new(100_i64))
      json["pattern"].should eq(JSON::Any.new("^[a-z]+$"))
      json["format"].should eq(JSON::Any.new("email"))
    end

    it "supports enum values" do
      schema = ClaudeAgent::Schema.string("Color", enum: ["red", "green", "blue"])
      json = schema.to_json_schema

      json["type"].should eq(JSON::Any.new("string"))
      enum_values = json["enum"].as_a
      enum_values.map(&.as_s).should eq(["red", "green", "blue"])
    end
  end

  describe ".integer" do
    it "creates a basic integer schema" do
      schema = ClaudeAgent::Schema.integer("An age")
      json = schema.to_json_schema

      json["type"].should eq(JSON::Any.new("integer"))
      json["description"].should eq(JSON::Any.new("An age"))
    end

    it "supports min/max bounds" do
      schema = ClaudeAgent::Schema.integer("Age", minimum: 0, maximum: 150)
      json = schema.to_json_schema

      json["minimum"].should eq(JSON::Any.new(0_i64))
      json["maximum"].should eq(JSON::Any.new(150_i64))
    end

    it "supports exclusive bounds" do
      schema = ClaudeAgent::Schema.integer(
        "Value",
        exclusive_minimum: 0,
        exclusive_maximum: 100
      )
      json = schema.to_json_schema

      json["exclusiveMinimum"].should eq(JSON::Any.new(0_i64))
      json["exclusiveMaximum"].should eq(JSON::Any.new(100_i64))
    end
  end

  describe ".number" do
    it "creates a number schema with bounds" do
      schema = ClaudeAgent::Schema.number("Temperature", minimum: -273.15, maximum: 1000.0)
      json = schema.to_json_schema

      json["type"].should eq(JSON::Any.new("number"))
      json["minimum"].should eq(JSON::Any.new(-273.15))
      json["maximum"].should eq(JSON::Any.new(1000.0))
    end
  end

  describe ".boolean" do
    it "creates a boolean schema" do
      schema = ClaudeAgent::Schema.boolean("Is active")
      json = schema.to_json_schema

      json["type"].should eq(JSON::Any.new("boolean"))
      json["description"].should eq(JSON::Any.new("Is active"))
    end
  end

  describe ".array" do
    it "creates an array schema with item type" do
      schema = ClaudeAgent::Schema.array(
        ClaudeAgent::Schema.string("Tag"),
        "List of tags"
      )
      json = schema.to_json_schema

      json["type"].should eq(JSON::Any.new("array"))
      json["description"].should eq(JSON::Any.new("List of tags"))

      items = json["items"].as_h
      items["type"].should eq(JSON::Any.new("string"))
    end

    it "supports array constraints" do
      schema = ClaudeAgent::Schema.array(
        ClaudeAgent::Schema.integer,
        min_items: 1,
        max_items: 10,
        unique_items: true
      )
      json = schema.to_json_schema

      json["minItems"].should eq(JSON::Any.new(1_i64))
      json["maxItems"].should eq(JSON::Any.new(10_i64))
      json["uniqueItems"].should eq(JSON::Any.new(true))
    end

    it "supports nested arrays" do
      schema = ClaudeAgent::Schema.array(
        ClaudeAgent::Schema.array(ClaudeAgent::Schema.integer),
        "Matrix"
      )
      json = schema.to_json_schema

      json["type"].should eq(JSON::Any.new("array"))
      items = json["items"].as_h
      items["type"].should eq(JSON::Any.new("array"))
      inner_items = items["items"].as_h
      inner_items["type"].should eq(JSON::Any.new("integer"))
    end
  end

  describe ".object" do
    it "creates an object schema with properties" do
      schema = ClaudeAgent::Schema.object({
        "name"  => ClaudeAgent::Schema.string("User name"),
        "age"   => ClaudeAgent::Schema.integer("User age"),
        "admin" => ClaudeAgent::Schema.boolean("Is admin"),
      }, required: ["name"])
      json = schema.to_json_schema

      json["type"].should eq(JSON::Any.new("object"))

      props = json["properties"].as_h
      props["name"].as_h["type"].should eq(JSON::Any.new("string"))
      props["age"].as_h["type"].should eq(JSON::Any.new("integer"))
      props["admin"].as_h["type"].should eq(JSON::Any.new("boolean"))

      required = json["required"].as_a
      required.map(&.as_s).should eq(["name"])
    end

    it "supports nested objects" do
      schema = ClaudeAgent::Schema.object({
        "user" => ClaudeAgent::Schema.object({
          "name" => ClaudeAgent::Schema.string("Name"),
        }),
      })
      json = schema.to_json_schema

      props = json["properties"].as_h
      user = props["user"].as_h
      user["type"].should eq(JSON::Any.new("object"))

      user_props = user["properties"].as_h
      user_props["name"].as_h["type"].should eq(JSON::Any.new("string"))
    end

    it "supports additional_properties flag" do
      schema = ClaudeAgent::Schema.object(
        {} of String => ClaudeAgent::Schema::SchemaType,
        additional_properties: false
      )
      json = schema.to_json_schema

      json["additionalProperties"].should eq(JSON::Any.new(false))
    end
  end

  describe ".enum" do
    it "creates an enum schema" do
      schema = ClaudeAgent::Schema.enum(["small", "medium", "large"], "Size options")
      json = schema.to_json_schema

      json["type"].should eq(JSON::Any.new("string"))
      json["description"].should eq(JSON::Any.new("Size options"))

      enum_values = json["enum"].as_a
      enum_values.map(&.as_s).should eq(["small", "medium", "large"])
    end
  end

  describe ".null" do
    it "creates a null schema" do
      schema = ClaudeAgent::Schema.null
      json = schema.to_json_schema

      json["type"].should eq(JSON::Any.new("null"))
    end
  end

  describe ".union" do
    it "creates a union schema (oneOf)" do
      schema = ClaudeAgent::Schema.union(
        ClaudeAgent::Schema.string,
        ClaudeAgent::Schema.integer,
        description: "String or integer"
      )
      json = schema.to_json_schema

      json["description"].should eq(JSON::Any.new("String or integer"))

      one_of = json["oneOf"].as_a
      one_of.size.should eq(2)
      one_of[0].as_h["type"].should eq(JSON::Any.new("string"))
      one_of[1].as_h["type"].should eq(JSON::Any.new("integer"))
    end
  end

  describe ".optional" do
    it "creates a union with null" do
      schema = ClaudeAgent::Schema.optional(ClaudeAgent::Schema.string("Name"))
      json = schema.to_json_schema

      one_of = json["oneOf"].as_a
      one_of.size.should eq(2)
      one_of[0].as_h["type"].should eq(JSON::Any.new("string"))
      one_of[1].as_h["type"].should eq(JSON::Any.new("null"))
    end
  end
end
