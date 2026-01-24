# Example 08: Interactive Permission Handling
#
# This example demonstrates how to handle permission requests interactively,
# allowing the user to approve or deny tool usage at runtime.

require "../src/claude-agent-cr"

options = ClaudeAgent::AgentOptions.new(
  permission_mode: ClaudeAgent::PermissionMode::Default
)

begin
  ClaudeAgent::AgentClient.open(options) do |client|
    puts "Asking agent to perform file operations..."
    puts "(You will be prompted to approve/deny each tool use)\n"

    client.query("List the files in the current directory and read the shard.yml file")

    client.each_response do |message|
      case message
      when ClaudeAgent::AssistantMessage
        puts "Claude: #{message.text}"
      when ClaudeAgent::PermissionRequest
        puts "\n" + "=" * 50
        puts "PERMISSION REQUEST"
        puts "=" * 50
        puts "Tool: #{message.tool_name}"
        puts "Input: #{message.tool_input}"
        puts "=" * 50

        print "Allow this action? (y/n): "
        response = gets

        if response && response.chomp.downcase == "y"
          puts "-> Granting permission\n"
          client.grant_permission(message.tool_use_id, true)
        else
          puts "-> Denying permission\n"
          client.grant_permission(message.tool_use_id, false, "User denied permission")
        end
      when ClaudeAgent::ResultMessage
        puts "\n[Session completed]"
      end
    end
  end
rescue ex
  puts "Error: #{ex.message}"
end
