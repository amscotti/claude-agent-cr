# Example 18: External MCP Server - GitHub
#
# This example demonstrates connecting to the GitHub MCP server
# to interact with repositories, issues, and pull requests.
#
# Prerequisites:
#   Set GITHUB_TOKEN environment variable with a personal access token
#   https://github.com/settings/tokens (needs 'repo' scope)
#
# The server will be downloaded automatically via npx on first run.
#
# NOTE: This example may hit the CLI bug #20508 (duplicate tool_use IDs)
# when the agent makes multiple tool calls. The MCP connection itself works.

require "../src/claude-agent-cr"

puts "GitHub MCP Server Example"
puts "=" * 50
puts

# Check for GitHub token
github_token = ENV["GITHUB_TOKEN"]?
unless github_token
  puts "Error: GITHUB_TOKEN environment variable not set"
  puts
  puts "Create a personal access token at:"
  puts "  https://github.com/settings/tokens"
  puts
  puts "Then run:"
  puts "  export GITHUB_TOKEN=ghp_xxxxxxxxxxxx"
  exit 1
end

# Configure the GitHub MCP server
github_server = ClaudeAgent::ExternalMCPServerConfig.stdio(
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-github"],
  env: {"GITHUB_TOKEN" => github_token}
)

options = ClaudeAgent::AgentOptions.new(
  mcp_servers: {
    "github" => github_server.as(ClaudeAgent::MCPServerConfig),
  } of String => ClaudeAgent::MCPServerConfig,
  # Only allow listing issues (read-only)
  allowed_tools: ["mcp__github__list_issues", "mcp__github__search_issues"],
  permission_mode: ClaudeAgent::PermissionMode::Default,
  max_turns: 5
)

puts "Connecting to GitHub MCP server..."
puts

begin
  ClaudeAgent.query(
    "List the 3 most recent open issues in the anthropics/claude-code repository",
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
