# Hook Tool Audit Example
#
# Demonstrates PostToolUse and PostToolUseFailure hooks for
# auditing tool executions. Shows the new event-specific fields:
# tool_use_id, tool_input, tool_response, error, is_interrupt.

require "../src/claude-agent-cr"

begin
  # PostToolUse hook - log successful tool executions
  audit_success = ->(input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
    puts "[Audit] Tool succeeded: #{input.tool_name}"
    puts "  tool_use_id: #{input.tool_use_id}"
    if tool_input = input.tool_input
      puts "  input: #{tool_input.to_json}"
    end
    # tool_result and tool_response are both available (same value)
    if result = input.tool_result
      preview = result.size > 100 ? "#{result[0..100]}..." : result
      puts "  result: #{preview}"
    end
    ClaudeAgent::HookResult.allow
  }

  # PostToolUseFailure hook - log failed tool executions
  audit_failure = ->(input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
    puts "[Audit] Tool FAILED: #{input.tool_name}"
    puts "  tool_use_id: #{input.tool_use_id}"
    if error = input.error
      puts "  error: #{error}"
    end
    if input.is_interrupt
      puts "  (failure was from user interruption)"
    end
    ClaudeAgent::HookResult.allow
  }

  hooks = ClaudeAgent::HookConfig.new(
    post_tool_use: [
      ClaudeAgent::HookMatcher.new(hooks: [audit_success]),
    ],
    post_tool_use_failure: [
      ClaudeAgent::HookMatcher.new(hooks: [audit_failure]),
    ],
  )

  options = ClaudeAgent::AgentOptions.new(
    hooks: hooks,
    allowed_tools: ["Bash", "Read"],
    permission_mode: ClaudeAgent::PermissionMode::AcceptEdits,
  )

  ClaudeAgent::AgentClient.open(options) do |client|
    client.query("Run 'echo hello' and then try to read a non-existent file /tmp/does_not_exist_12345.txt")

    client.each_response do |message|
      if message.is_a?(ClaudeAgent::AssistantMessage) && message.has_text?
        puts "\nClaude: #{message.text}"
      end
    end
  end
rescue ex
  puts "Error: #{ex.message}"
end
