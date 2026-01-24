# Example 11: Custom Tool Definition
#
# This example demonstrates how to define custom tools using the SDK's
# tool definition helpers and Schema module.

require "../src/claude-agent-cr"

# Define a simple greeting tool
greet_tool = ClaudeAgent.tool(
  name: "greet",
  description: "Greet a user by name with a customizable greeting style",
  schema: ClaudeAgent::Schema.object(
    {
      "name"  => ClaudeAgent::Schema.string("The name of the person to greet"),
      "style" => ClaudeAgent::Schema.string("The greeting style: formal, casual, or enthusiastic"),
    },
    ["name"] # required fields
  )
) do |args|
  name = args["name"].as_s
  style = args["style"]?.try(&.as_s) || "casual"

  greeting = case style
             when "formal"
               "Good day, #{name}. It is a pleasure to make your acquaintance."
             when "enthusiastic"
               "Hey #{name}!!! SO GREAT to meet you! This is AWESOME!"
             else
               "Hey #{name}, nice to meet you!"
             end

  ClaudeAgent::ToolResult.text(greeting)
end

# Define a calculator tool
calculator_tool = ClaudeAgent.tool(
  name: "calculate",
  description: "Perform basic arithmetic operations",
  schema: ClaudeAgent::Schema.object(
    {
      "operation" => ClaudeAgent::Schema.string("The operation: add, subtract, multiply, divide"),
      "a"         => ClaudeAgent::Schema.integer("First number"),
      "b"         => ClaudeAgent::Schema.integer("Second number"),
    },
    ["operation", "a", "b"]
  )
) do |args|
  op = args["operation"].as_s
  a = args["a"].as_i
  b = args["b"].as_i

  result = case op
           when "add"      then a + b
           when "subtract" then a - b
           when "multiply" then a * b
           when "divide"
             if b == 0
               next ClaudeAgent::ToolResult.error("Cannot divide by zero")
             end
             a / b
           else
             next ClaudeAgent::ToolResult.error("Unknown operation: #{op}")
           end

  ClaudeAgent::ToolResult.text("Result: #{result}")
end

# Test the tools locally
puts "Testing tools locally:"
puts "-" * 30

puts "\nGreet tool (casual):"
result = greet_tool.call({"name" => JSON::Any.new("Alice")})
puts result.content[0].text

puts "\nGreet tool (formal):"
result = greet_tool.call({"name" => JSON::Any.new("Bob"), "style" => JSON::Any.new("formal")})
puts result.content[0].text

puts "\nCalculator tool (add):"
result = calculator_tool.call({
  "operation" => JSON::Any.new("add"),
  "a"         => JSON::Any.new(15_i64),
  "b"         => JSON::Any.new(27_i64),
})
puts result.content[0].text

puts "\nCalculator tool (divide by zero):"
result = calculator_tool.call({
  "operation" => JSON::Any.new("divide"),
  "a"         => JSON::Any.new(10_i64),
  "b"         => JSON::Any.new(0_i64),
})
puts result.content[0].text
puts "(is_error: #{result.is_error?})"
