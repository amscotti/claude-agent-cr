# Example 06: Permission Callback
#
# This example demonstrates how to use a custom permission callback
# to programmatically control which tools the agent can use.

require "../src/claude-agent-cr"

# Define a permission callback that:
# - Allows Read and Glob tools
# - Denies Write and Edit tools
# - Logs all permission requests
permission_handler = ->(ctx : ClaudeAgent::PermissionContext) {
  puts "[Permission Check] Tool: #{ctx.tool_name}"
  puts "[Permission Check] Input: #{ctx.tool_input}"

  case ctx.tool_name
  when "Read", "Glob", "Grep"
    puts "[Permission Check] -> ALLOWED"
    ClaudeAgent::PermissionResult.new(allow: true)
  when "Write", "Edit"
    puts "[Permission Check] -> DENIED (write operations not allowed)"
    ClaudeAgent::PermissionResult.new(allow: false, reason: "Write operations are not permitted in this session")
  when "Bash"
    # Allow only safe bash commands
    command = ctx.tool_input["command"]?.try(&.as_s) || ""
    if command.includes?("rm") || command.includes?("sudo")
      puts "[Permission Check] -> DENIED (dangerous command)"
      ClaudeAgent::PermissionResult.new(allow: false, reason: "Dangerous commands are not allowed")
    else
      puts "[Permission Check] -> ALLOWED"
      ClaudeAgent::PermissionResult.new(allow: true)
    end
  else
    puts "[Permission Check] -> ALLOWED (default)"
    ClaudeAgent::PermissionResult.new(allow: true)
  end
}

options = ClaudeAgent::AgentOptions.new(
  can_use_tool: permission_handler,
  permission_mode: ClaudeAgent::PermissionMode::Default
)

begin
  ClaudeAgent::AgentClient.open(options) do |client|
    puts "Asking agent to read a file (should be allowed)..."
    client.query("Read the README.md file and summarize it briefly")

    client.each_response do |message|
      if message.is_a?(ClaudeAgent::AssistantMessage)
        puts "Claude: #{message.text}"
      end
    end
  end
rescue ex
  puts "Error: #{ex.message}"
end
