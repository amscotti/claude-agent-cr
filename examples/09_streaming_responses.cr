# Example 09: Advanced Streaming with Tool Use
#
# This example demonstrates streaming responses while also tracking
# tool usage, showing how to monitor the agent's actions in real-time.

require "../src/claude-agent-cr"

options = ClaudeAgent::AgentOptions.new(
  allowed_tools: ["Read", "Glob", "Grep"],
  permission_mode: ClaudeAgent::PermissionMode::BypassPermissions,
  max_turns: 5
)

begin
  puts "Starting agent with streaming output...\n"
  puts "-" * 50

  tool_uses = [] of String

  ClaudeAgent.query("Find all Crystal spec files and count the total number of test cases", options) do |message|
    case message
    when ClaudeAgent::AssistantMessage
      message.content.each do |block|
        case block
        when ClaudeAgent::TextBlock
          print block.text
          STDOUT.flush
        when ClaudeAgent::ToolUseBlock
          tool_uses << block.name
          puts "\n[Using tool: #{block.name}]"
          puts "[Input: #{block.input}]"
        when ClaudeAgent::ToolResultBlock
          puts "[Tool result received]"
        end
      end
    when ClaudeAgent::ResultMessage
      puts "\n" + "-" * 50
      puts "Session Statistics:"
      puts "  Duration: #{message.duration_ms}ms"
      puts "  API Time: #{message.duration_api_ms}ms"
      puts "  Turns: #{message.num_turns}"
      puts "  Tools Used: #{tool_uses.join(", ")}"
      if cost = message.total_cost_usd
        puts "  Total Cost: $#{cost.round(6)}"
      end
    end
  end
rescue ex
  puts "Error: #{ex.message}"
end
