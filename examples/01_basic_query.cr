require "../src/claude-agent-cr"

begin
  ClaudeAgent.query("What is 2 + 2?") do |message|
    case message
    when ClaudeAgent::AssistantMessage
      message.content.each do |block|
        if block.is_a?(ClaudeAgent::TextBlock)
          print block.text
        end
      end
    when ClaudeAgent::ResultMessage
      puts "\nDone: #{message.subtype}"
    end
  end
rescue ex : ClaudeAgent::CLINotFoundError
  puts "Claude CLI not found. Please install it to run this example."
rescue ex
  puts "An error occurred: #{ex.message}"
end
