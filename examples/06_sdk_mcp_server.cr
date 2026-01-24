# SDK MCP Server Example
#
# This example demonstrates how to create custom tools that run in-process
# using the SDK MCP server architecture. This is the same approach used by
# the official TypeScript and Python SDKs.
#
# **How it works:**
# 1. Define tools using ClaudeAgent.tool() or SDKTool.new()
# 2. Bundle tools into an SDK MCP server with create_sdk_mcp_server()
# 3. Pass the server to AgentOptions.mcp_servers
# 4. The CLI routes tool calls back to your Crystal process via control protocol
#
# **Known Limitation:**
# As of January 2025, there are known issues with SDK MCP server integration
# in the Claude Code CLI (GitHub Issue #7279). Tool discovery may work but
# execution routing may fail in some CLI versions.
#
# **Tool Naming Convention:**
# SDK MCP tools are named: mcp__<server_name>__<tool_name>
# For example, a tool "greet" in server "my-tools" becomes "mcp__my-tools__greet"

require "../src/claude-agent-cr"

# Define a simple greeting tool
greet_tool = ClaudeAgent.tool(
  name: "greet",
  description: "Greet a user by name",
  schema: ClaudeAgent::Schema.object({
    "name" => ClaudeAgent::Schema.string("The name to greet"),
  }, required: ["name"])
) do |args|
  name = args["name"]?.try(&.as_s?) || "World"
  ClaudeAgent::ToolResult.text("Hello, #{name}! Welcome to the Crystal SDK.")
end

# Define a calculator tool
add_tool = ClaudeAgent.tool(
  name: "add",
  description: "Add two numbers together",
  schema: ClaudeAgent::Schema.object({
    "a" => ClaudeAgent::Schema.number("First number"),
    "b" => ClaudeAgent::Schema.number("Second number"),
  }, required: ["a", "b"])
) do |args|
  a = args["a"]?.try(&.as_f?) || 0.0
  b = args["b"]?.try(&.as_f?) || 0.0
  result = a + b
  ClaudeAgent::ToolResult.text("#{a} + #{b} = #{result}")
end

# Create the SDK MCP server with our tools
calculator_server = ClaudeAgent.create_sdk_mcp_server(
  name: "calculator",
  version: "1.0.0",
  tools: [greet_tool, add_tool]
)

# Configure the agent with our SDK MCP server
# Note: Need to explicitly type the hash for the union type
mcp_config = {} of String => ClaudeAgent::MCPServerConfig
mcp_config["calc"] = calculator_server

options = ClaudeAgent::AgentOptions.new(
  model: "claude-sonnet-4-5-20250929",
  mcp_servers: mcp_config,
  # Allow the SDK tools to be used
  allowed_tools: [
    "mcp__calc__greet",
    "mcp__calc__add",
  ],
  permission_mode: ClaudeAgent::PermissionMode::AcceptEdits
)

puts "SDK MCP Server Example"
puts "=" * 50
puts "Registered tools:"
puts "  - mcp__calc__greet: Greet a user by name"
puts "  - mcp__calc__add: Add two numbers"
puts ""
puts "Note: Due to CLI bug #7279, tool execution may not work in all CLI versions."
puts ""

# Run a query that should trigger our tools
ClaudeAgent::AgentClient.open(options) do |client|
  client.query("Please greet Alice and then calculate 42 + 17")

  client.each_response do |message|
    case message
    when ClaudeAgent::AssistantMessage
      puts "Assistant: #{message.text}" unless message.text.empty?

      # Show which tools were used
      message.content.each do |block|
        if block.is_a?(ClaudeAgent::ToolUseBlock)
          puts "  [Tool: #{block.name}]"
        end
      end
    when ClaudeAgent::ResultMessage
      puts ""
      puts "=" * 50
      puts "Session completed"
      if cost = message.cost_usd
        puts "  Cost: $#{cost.round(6)}"
      end
      if total_cost = message.total_cost_usd
        puts "  Total Cost: $#{total_cost.round(6)}"
      end
      puts "  Turns: #{message.num_turns || "N/A"}"
    end
  end
end
