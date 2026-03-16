# Hook PermissionRequest Example
#
# Demonstrates the PermissionRequest hook event, which fires when a
# permission dialog would appear. This is distinct from PreToolUse -
# it provides visibility into permission events without blocking them.

require "../src/claude-agent-cr"

begin
  demo_file = File.join(Dir.current, "permission_request_demo.txt")
  hook_hits = [] of Bool

  puts "PermissionRequest hook demo"
  puts "=" * 50
  puts "If your Claude permissions already auto-approve this action, the hook may not fire."
  puts

  # PermissionRequest hook - log permission events
  log_permissions = ->(input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
    hook_hits << true
    puts "[PermissionRequest] Tool: #{input.tool_name}"
    puts "  tool_use_id: #{input.tool_use_id}"
    puts "  session_id: #{input.session_id}"
    puts "  permission_mode: #{input.permission_mode}"
    if suggestions = input.permission_suggestions
      puts "  suggestions: #{suggestions.map(&.to_json).join(", ")}"
    end
    ClaudeAgent::HookResult.permission_request({
      "type" => JSON::Any.new("allow"),
    })
  }

  hooks = ClaudeAgent::HookConfig.new(
    permission_request: [
      ClaudeAgent::HookMatcher.new(hooks: [log_permissions]),
    ],
  )

  options = ClaudeAgent::AgentOptions.new(
    hooks: hooks,
    permission_mode: ClaudeAgent::PermissionMode::Default,
    allowed_tools: ["Write"],
  )

  ClaudeAgent::AgentClient.open(options) do |client|
    client.query("Write the text 'permission hook demo' to permission_request_demo.txt and then say done.")

    client.each_response do |message|
      case message
      when ClaudeAgent::AssistantMessage
        puts "Claude: #{message.text}" if message.has_text?
      when ClaudeAgent::PermissionRequest
        puts "\n(Permission request for: #{message.tool_name})"
      end
    end
  end

  if hook_hits.empty?
    puts
    puts "PermissionRequest did not fire in this run."
    puts "Your current Claude permission settings likely auto-approved the action before a prompt was needed."
  end
rescue ex
  puts "Error: #{ex.message}"
ensure
  File.delete(demo_file) if demo_file && File.exists?(demo_file)
end
