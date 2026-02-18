# Example 19: Remote MCP Server (SSE)
#
# This example demonstrates connecting to a remote MCP server
# using Server-Sent Events (SSE) transport. SSE is used by many
# hosted MCP servers including Context7 for documentation search.
#
# The Context7 MCP server provides access to library documentation
# and code examples for many popular programming languages and frameworks.
#

require "../src/claude-agent-cr"

puts "Remote SSE MCP Server Example"
puts "=" * 50
puts

# Context7 MCP server - provides documentation search for libraries
# Uses SSE (Server-Sent Events) transport
context7_server = ClaudeAgent::ExternalMCPServerConfig.sse(
  url: "https://mcp.context7.com/mcp"
)

options = ClaudeAgent::AgentOptions.new(
  mcp_servers: {
    "context7" => context7_server.as(ClaudeAgent::MCPServerConfig),
  } of String => ClaudeAgent::MCPServerConfig,
  # Allow all tools from this server
  allowed_tools: ["mcp__context7__*"],
  permission_mode: ClaudeAgent::PermissionMode::Default,
  max_turns: 5
)

puts "Connecting to Context7 MCP server..."
puts "(Provides documentation search for libraries)"
puts

begin
  ClaudeAgent.query(
    "Search Context7 for information about React hooks and explain the useEffect hook",
    options
  ) do |message|
    case message
    when ClaudeAgent::AssistantMessage
      message.tool_uses.each do |tool|
        puts "[Tool: #{tool}]"
      end
      if message.has_text?
        puts message.text
      end
    when ClaudeAgent::ResultMessage
      puts
      puts "=" * 50
      if cost = message.cost_usd
        puts "Cost: $#{cost.round(6)}"
      end
    end
  end
rescue ex
  puts "Error: #{ex.message}"
  puts
  puts "Note: The Context7 server requires SSE transport support."
  puts "Make sure your network allows SSE connections."
end
