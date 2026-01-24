require "../src/claude-agent-cr"

puts "Claude Agent Chatbot (Type 'exit' to quit)"
puts "-----------------------------------------"

begin
  ClaudeAgent::AgentClient.open do |client|
    loop do
      print "You: "
      input = gets
      break if input.nil? || input.chomp.downcase == "exit"
      break if input.chomp.empty?

      # For the first message we use query, subsequent ones we use send_user_message if we were maintaining state manually,
      # but Client usually expects a query to start.
      # Actually, AgentClient#query sends a 'user' message.
      # If we are in a loop, we should check if it's the first turn or not?
      # The CLI handles session state.
      # `query` sends a message. `send_user_message` sends a message.
      # They are effectively the same wrappers in CLIClient.

      client.send_user_message(input.chomp)

      print "Claude: "
      client.each_response do |message|
        if message.is_a?(ClaudeAgent::AssistantMessage)
          print message.text
        end
      end
      puts
    end
  end
rescue ex
  puts "Error: #{ex.message}"
end
