require "../src/claude-agent-cr"

begin
  options = ClaudeAgent::AgentOptions.new(
    allowed_tools: ["Read"] # Only allow reading files
  )

  ClaudeAgent.query("Read the README.md file.", options) do |message|
    if message.is_a?(ClaudeAgent::AssistantMessage)
      print message.text
    end
  end
  puts
rescue ex
  puts "Error: #{ex.message}"
end
