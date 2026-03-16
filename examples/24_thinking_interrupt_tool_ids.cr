# Thinking Config, Interrupt, Tool ID, and Stop Reason Example
#
# Demonstrates three confirmed features from the official SDKs:
# 1. ThinkingConfig + effort - Control extended thinking behavior
# 2. ThinkingBlock - Access extended thinking content
# 3. Interrupt - Cancel an ongoing agent operation
# 4. Tool Use ID - Correlate tool calls with results
# 5. Result stop_reason - Inspect why a turn ended

require "../src/claude-agent-cr"

# Track tool calls for correlation
tool_calls = {} of String => Tuple(String, Hash(String, JSON::Any))

options = ClaudeAgent::AgentOptions.new(
  thinking: ClaudeAgent::ThinkingConfig.enabled(8_192),
  effort: ClaudeAgent::Effort::High,
  max_turns: 3,
)

begin
  ClaudeAgent::AgentClient.open(options) do |client|
    # Start a query that will trigger thinking and tool use
    client.query("Explain how recursion works, then list files in the current directory")

    # Set up interrupt after 5 seconds (simulating user cancellation)
    spawn do
      sleep 5.seconds
      puts "\n[User requested interrupt]"
      client.interrupt
    end

    client.each_response do |message|
      case message
      when ClaudeAgent::AssistantMessage
        message.content.each do |block|
          case block
          when ClaudeAgent::ThinkingBlock
            # Feature 1: Access thinking content
            puts "\n[Thinking] #{block.thinking[0..100]}..."
            puts "[Signature present: #{!block.signature.empty?}]"
          when ClaudeAgent::TextBlock
            puts "\n[Response] #{block.text[0..200]}..." if block.text.size > 0
          when ClaudeAgent::ToolUseBlock
            # Feature 3: Tool Use ID for correlation
            tool_calls[block.id] = {block.name, block.input}
            puts "\n[Tool Call] #{block.name} (ID: #{block.id})"
            puts "  Input: #{block.input.to_json[0..100]}..."
          end
        end
      when ClaudeAgent::CompactBoundaryMessage
        # Bonus: Show compact boundary detection
        puts "\n[Compact] Session compacted (#{message.compact_metadata.trigger})"
      when ClaudeAgent::ResultMessage
        puts "\n[Result] Turns: #{message.num_turns}, Success: #{message.success?}"
        puts "[Stop Reason] #{message.stop_reason || "(none)"}"

        # Feature 3: Show we can correlate tool results
        puts "\nTool calls made:"
        tool_calls.each do |id, (name, input)|
          puts "  #{id}: #{name}"
        end
      end
    end
  end
rescue ex
  puts "Error: #{ex.message}"
end

puts "\nDone!"

# Example output:
#
# [Thinking] The user wants me to explain recursion and then list files...
# [Signature present: true]
#
# [Response] Recursion is a programming concept where a function...
#
# [Tool Call] Bash (ID: toolu_01AbC123)
#   Input: {"command":"ls -la"}
#
# [Result] Turns: 3, Success: true
# [Stop Reason] end_turn
#
# Tool calls made:
#   toolu_01AbC123: Bash
