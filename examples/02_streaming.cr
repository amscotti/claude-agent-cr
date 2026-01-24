# Example 02: Streaming Responses
#
# This example demonstrates how to stream responses in real-time,
# showing each text block as it arrives from the agent.

require "../src/claude-agent-cr"

begin
  print "Claude: "

  ClaudeAgent.query("Write a haiku about programming") do |message|
    case message
    when ClaudeAgent::AssistantMessage
      # Stream each text block as it arrives
      message.content.each do |block|
        if block.is_a?(ClaudeAgent::TextBlock)
          print block.text
          STDOUT.flush
        end
      end
    when ClaudeAgent::ResultMessage
      puts "\n\n[Completed in #{message.duration_ms}ms]"
      if cost = message.total_cost_usd
        puts "[Cost: $#{cost.round(6)}]"
      end
    end
  end
rescue ex : ClaudeAgent::CLINotFoundError
  puts "Claude CLI not found. Please install it to run this example."
rescue ex
  puts "An error occurred: #{ex.message}"
end
