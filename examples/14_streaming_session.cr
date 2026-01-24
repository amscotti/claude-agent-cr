# Example 14: V2 Streaming Session Interface
#
# This example demonstrates the V2-style send/receive streaming interface
# that provides bidirectional communication with the agent.

require "../src/claude-agent-cr"

puts "V2 Streaming Session Example"
puts "=" * 40

# Create session options
options = ClaudeAgent::AgentOptions.new(
  system_prompt: "You are a helpful assistant. Keep responses brief.",
  max_turns: 3
)

# Method 1: Using the block form (recommended)
puts "\n--- Using block form ---"

ClaudeAgent::StreamingSession.open(options) do |session|
  # Send a message
  session.send("What is 2 + 2? Just give me the number.")

  # Iterate over responses
  session.each_message do |msg|
    case msg
    when ClaudeAgent::AssistantMessage
      puts "Assistant: #{msg.text}"
    when ClaudeAgent::ResultMessage
      puts "\n[Session ended]"
      if cost = msg.cost_usd
        puts "Cost: $#{cost}"
      end
    end
  end
end

# Method 2: Manual control (for complex interactions)
puts "\n--- Using manual control ---"

session = ClaudeAgent::StreamingSession.new(options)
begin
  session.start

  # Send first message
  session.send("Count from 1 to 3, one number per line.")

  # Process messages manually
  loop do
    msg = session.receive
    break unless msg

    case msg
    when ClaudeAgent::AssistantMessage
      puts "Assistant: #{msg.text}"
    when ClaudeAgent::ResultMessage
      puts "\n[Session ended]"
      break
    end
  end
ensure
  session.close
end

puts "\nDone!"
