require "../src/claude-agent-cr"

begin
  # Define a hook to block "rm" command
  block_rm_hook = ->(input : ClaudeAgent::HookInput, _tool_use_id : String, _ctx : ClaudeAgent::HookContext) {
    if input.tool_name == "Bash" && input.tool_input.try(&.["command"]?.try(&.as_s.includes?("rm")))
      ClaudeAgent::HookResult.deny("Removing files is not allowed via Bash.")
    else
      ClaudeAgent::HookResult.allow
    end
  }

  hooks = ClaudeAgent::HookConfig.new(
    pre_tool_use: [
      ClaudeAgent::HookMatcher.new(
        matcher: "Bash",
        hooks: [block_rm_hook]
      ),
    ]
  )

  options = ClaudeAgent::AgentOptions.new(
    hooks: hooks,
    # Ensure we are in a mode that asks for permissions so hooks can intercept?
    # Actually, hooks run on PermissionRequest. If permission_mode is Default, CLI asks.
    permission_mode: ClaudeAgent::PermissionMode::Default
  )

  ClaudeAgent::AgentClient.open(options) do |client|
    puts "Asking to remove a file..."
    client.query("Please run 'rm -rf /tmp/test'")

    client.each_response do |message|
      if message.is_a?(ClaudeAgent::AssistantMessage)
        puts "Claude: #{message.text}"
      elsif message.is_a?(ClaudeAgent::PermissionRequest)
        puts "Received permission request for #{message.tool_name}..."
        # If hook denied it, we might not see it here if logic returns early?
        # AgentClient logic:
        # if output.permission_decision == "deny" -> grant_permission(false) -> return.
        # So we won't see it yielded if denied.
      end
    end
  end
rescue ex
  puts "Error: #{ex.message}"
end
