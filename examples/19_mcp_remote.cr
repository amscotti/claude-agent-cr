# Example 19: Remote MCP Server (HTTP)
#
# This example demonstrates connecting to a remote MCP server
# over HTTP. Remote servers are useful for cloud-hosted services
# and don't require local installation.
#
# This example uses the Claude Code documentation MCP server.
#

require "../src/claude-agent-cr"

puts "Remote HTTP MCP Server Example"
puts "=" * 50
puts

# Configure a remote HTTP MCP server
# No local installation required - connects over HTTP
docs_server = ClaudeAgent::ExternalMCPServerConfig.http(
  url: "https://code.claude.com/docs/mcp"
)

options = ClaudeAgent::AgentOptions.new(
  mcp_servers: {
    "claude-code-docs" => docs_server.as(ClaudeAgent::MCPServerConfig),
  } of String => ClaudeAgent::MCPServerConfig,
  # Allow all tools from this server
  allowed_tools: ["mcp__claude-code-docs__*"],
  permission_mode: ClaudeAgent::PermissionMode::Default,
  max_turns: 5
)

puts "Connecting to Claude Code docs MCP server..."
puts

begin
  ClaudeAgent.query(
    "Use the docs MCP server to explain what hooks are in Claude Code",
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
end
