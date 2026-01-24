require "../src/claude-agent-cr"

begin
  ClaudeAgent::AgentClient.open do |client|
    puts "User: Hello, who are you?"
    client.query("Hello, who are you?")

    client.each_response do |message|
      if message.is_a?(ClaudeAgent::AssistantMessage)
        puts "Claude: #{message.text}"
      elsif message.is_a?(ClaudeAgent::ResultMessage)
        puts "\n[End of Turn]"
      end
    end

    puts "User: What is the capital of France?"
    client.send_user_message("What is the capital of France?")

    client.each_response do |message|
      if message.is_a?(ClaudeAgent::AssistantMessage)
        puts "Claude: #{message.text}"
      elsif message.is_a?(ClaudeAgent::ResultMessage)
        puts "\n[End of Turn]"
      end
    end
  end
rescue ex
  puts "Error: #{ex.message}"
end
