require "../src/claude-agent-cr"

begin
  options = ClaudeAgent::AgentOptions.new(
    system_prompt: "You are a helpful assistant that always speaks like a pirate."
  )

  ClaudeAgent.query("Say hello!", options) do |message|
    if message.is_a?(ClaudeAgent::AssistantMessage)
      print message.text
    end
  end
  puts
rescue ex
  puts "Error: #{ex.message}"
end
