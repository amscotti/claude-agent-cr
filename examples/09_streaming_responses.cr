# Example 09: Partial Streaming and Tool Use
#
# This example demonstrates partial streaming responses while also tracking
# tool usage, showing how to monitor the agent's actions in real time.

require "../src/claude-agent-cr"

options = ClaudeAgent::AgentOptions.new(
  allowed_tools: ["Read", "Glob", "Grep"],
  permission_mode: ClaudeAgent::PermissionMode::BypassPermissions,
  include_partial_messages: true,
  max_turns: 5
)

begin
  puts "Starting agent with streaming output...\n"
  puts "-" * 50

  tool_uses = [] of String
  stream_event_types = [] of String
  thinking_deltas = 0

  ClaudeAgent.query("Find all Crystal spec files and count the total number of test cases", options) do |message|
    case message
    when ClaudeAgent::StreamEvent
      event_type = message.event["type"]?.try(&.as_s?) || "unknown"
      stream_event_types << event_type

      if event_type == "content_block_delta"
        delta = message.event["delta"]?.try(&.as_h?)
        if delta && delta["type"]?.try(&.as_s?) == "thinking_delta"
          thinking_deltas += 1
        end
      end
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
      puts "  Stream Events Seen: #{stream_event_types.uniq.join(", ")}"
      puts "  Thinking Deltas: #{thinking_deltas}"
      if cost = message.total_cost_usd
        puts "  Total Cost: $#{cost.round(6)}"
      end
    end
  end
rescue ex
  puts "Error: #{ex.message}"
end
