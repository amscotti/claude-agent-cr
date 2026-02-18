# Hook PermissionRequest Example
#
# Demonstrates the PermissionRequest hook event, which fires when a
# permission dialog would appear. This is distinct from PreToolUse -
# it provides visibility into permission events without blocking them.

require "../src/claude-agent-cr"

begin
  # PreToolUse hook - block dangerous commands
  block_dangerous = ->(input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
    if input.tool_name == "Bash"
      command = input.tool_input.try(&.["command"]?.try(&.as_s)) || ""
      if command.includes?("rm") || command.includes?("sudo")
        puts "[PreToolUse] BLOCKED: #{command}"
        puts "  tool_use_id: #{input.tool_use_id}"
        return ClaudeAgent::HookResult.deny("Dangerous command blocked by policy.")
      end
    end
    ClaudeAgent::HookResult.allow
  }

  # PermissionRequest hook - log permission events
  log_permissions = ->(input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
    puts "[PermissionRequest] Tool: #{input.tool_name}"
    puts "  tool_use_id: #{input.tool_use_id}"
    puts "  session_id: #{input.session_id}"
    puts "  permission_mode: #{input.permission_mode}"
    if suggestions = input.permission_suggestions
      puts "  suggestions: #{suggestions.map(&.to_json).join(", ")}"
    end
    ClaudeAgent::HookResult.allow
  }

  hooks = ClaudeAgent::HookConfig.new(
    pre_tool_use: [
      ClaudeAgent::HookMatcher.new(matcher: "Bash", hooks: [block_dangerous]),
    ],
    permission_request: [
      ClaudeAgent::HookMatcher.new(hooks: [log_permissions]),
    ],
  )

  options = ClaudeAgent::AgentOptions.new(
    hooks: hooks,
    permission_mode: ClaudeAgent::PermissionMode::Default,
  )

  ClaudeAgent::AgentClient.open(options) do |client|
    client.query("Run 'echo hello world' in the terminal")

    client.each_response do |message|
      case message
      when ClaudeAgent::AssistantMessage
        puts "Claude: #{message.text}" if message.has_text?
      when ClaudeAgent::PermissionRequest
        puts "\n(Permission request for: #{message.tool_name})"
      end
    end
  end
rescue ex
  puts "Error: #{ex.message}"
end
