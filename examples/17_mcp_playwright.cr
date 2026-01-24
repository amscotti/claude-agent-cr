# Example 17: External MCP Server - Playwright
#
# This example demonstrates connecting to the Playwright MCP server
# to automate browser interactions. Claude can navigate websites,
# take screenshots, fill forms, and extract information.
#

require "../src/claude-agent-cr"

puts "Playwright MCP Server Example"
puts "=" * 50
puts

# Configure the Playwright MCP server
# Using stdio transport - runs as a local process
playwright_server = ClaudeAgent::ExternalMCPServerConfig.stdio(
  command: "npx",
  args: ["-y", "@playwright/mcp@latest"]
)

options = ClaudeAgent::AgentOptions.new(
  mcp_servers: {
    "playwright" => playwright_server.as(ClaudeAgent::MCPServerConfig),
  } of String => ClaudeAgent::MCPServerConfig,
  # Allow all Playwright tools - they follow the pattern mcp__playwright__*
  allowed_tools: ["mcp__playwright__*"],
  permission_mode: ClaudeAgent::PermissionMode::AcceptEdits,
  max_turns: 10
)

puts "Connecting to Playwright MCP server..."
puts

begin
  ClaudeAgent::AgentClient.open(options) do |client|
    client.query("Use Playwright to navigate to https://example.com and tell me what the main heading says.")

    client.each_response do |message|
      case message
      when ClaudeAgent::AssistantMessage
        # Show tool usage
        message.tool_uses.each do |tool|
          puts "[Tool: #{tool}]"
        end
        # Show text responses
        if message.has_text?
          puts message.text
        end
      when ClaudeAgent::PermissionRequest
        # Auto-grant permissions for this example
        puts "[Permission requested for: #{message.tool_name}]"
        client.grant_permission(message.tool_use_id, true)
      when ClaudeAgent::ResultMessage
        puts
        puts "=" * 50
        if cost = message.cost_usd
          puts "Cost: $#{cost.round(6)}"
        end
      end
    end
  end
rescue ex
  puts "Error: #{ex.message}"
end
