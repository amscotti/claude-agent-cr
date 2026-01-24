# Example 12: SDK MCP Server
#
# This example demonstrates how to create an in-process MCP server
# with multiple custom tools that can be used by the agent.

require "../src/claude-agent-cr"

# Create custom tools for our MCP server

# A tool to get the current time
time_tool = ClaudeAgent.tool(
  name: "get_time",
  description: "Get the current date and time",
  schema: ClaudeAgent::Schema.object(
    {"timezone" => ClaudeAgent::Schema.string("Optional timezone (default: UTC)")},
    [] of String
  )
) do |args|
  timezone = args["timezone"]?.try(&.as_s) || "UTC"
  current_time = Time.utc.to_s("%Y-%m-%d %H:%M:%S")
  ClaudeAgent::ToolResult.text("Current time (#{timezone}): #{current_time}")
end

# A tool to generate random numbers
random_tool = ClaudeAgent.tool(
  name: "random_number",
  description: "Generate a random number within a specified range",
  schema: ClaudeAgent::Schema.object(
    {
      "min" => ClaudeAgent::Schema.integer("Minimum value (inclusive)"),
      "max" => ClaudeAgent::Schema.integer("Maximum value (inclusive)"),
    },
    ["min", "max"]
  )
) do |args|
  min = args["min"].as_i
  max = args["max"].as_i

  if min > max
    next ClaudeAgent::ToolResult.error("min must be less than or equal to max")
  end

  result = Random.rand(min..max)
  ClaudeAgent::ToolResult.text("Random number: #{result}")
end

# A tool to convert text to uppercase/lowercase
text_transform_tool = ClaudeAgent.tool(
  name: "transform_text",
  description: "Transform text to uppercase, lowercase, or title case",
  schema: ClaudeAgent::Schema.object(
    {
      "text"      => ClaudeAgent::Schema.string("The text to transform"),
      "transform" => ClaudeAgent::Schema.string("The transformation: upper, lower, or title"),
    },
    ["text", "transform"]
  )
) do |args|
  text = args["text"].as_s
  transform = args["transform"].as_s

  result = case transform
           when "upper" then text.upcase
           when "lower" then text.downcase
           when "title" then text.split.map(&.capitalize).join(" ")
           else
             next ClaudeAgent::ToolResult.error("Unknown transform: #{transform}. Use: upper, lower, or title")
           end

  ClaudeAgent::ToolResult.text(result)
end

# Create the SDK MCP server with our tools
server = ClaudeAgent.create_sdk_mcp_server(
  name: "utility-tools",
  version: "1.0.0",
  tools: [time_tool, random_tool, text_transform_tool]
)

puts "Created MCP Server: #{server.name} v#{server.version}"
puts "Available tools:"
server.handle_list_tools.each do |tool_info|
  puts "  - #{tool_info["name"].as_s}: #{tool_info["description"].as_s}"
end

puts "\n" + "-" * 50
puts "Testing tools via MCP server interface:"
puts "-" * 50

# Test calling tools through the server
puts "\nget_time:"
result = server.handle_call_tool("get_time", {} of String => JSON::Any)
puts "  #{result.content[0].text}"

puts "\nrandom_number (1-100):"
result = server.handle_call_tool("random_number", {
  "min" => JSON::Any.new(1_i64),
  "max" => JSON::Any.new(100_i64),
})
puts "  #{result.content[0].text}"

puts "\ntransform_text (title case):"
result = server.handle_call_tool("transform_text", {
  "text"      => JSON::Any.new("hello world from crystal"),
  "transform" => JSON::Any.new("title"),
})
puts "  #{result.content[0].text}"

# Note: To use this server with the agent, you would configure it in AgentOptions:
#
# options = ClaudeAgent::AgentOptions.new(
#   mcp_servers: {"utils" => server},
#   allowed_tools: ["mcp__utils__get_time", "mcp__utils__random_number", "mcp__utils__transform_text"]
# )
