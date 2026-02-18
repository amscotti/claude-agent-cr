# Hook Lifecycle Example
#
# Demonstrates the full hook lifecycle with all event-specific fields.
# Each hook input now includes common context fields (session_id,
# transcript_path, cwd, permission_mode, hook_event_name) plus
# event-specific fields.

require "../src/claude-agent-cr"

begin
  # SessionStart hook - fires when the session begins
  session_start_hook = ->(input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
    puts "[SessionStart] Session #{input.session_id} started"
    puts "  cwd: #{input.cwd}"
    puts "  permission_mode: #{input.permission_mode}"
    # input.source will be "startup", "resume", "clear", or "compact"
    # when dispatched via control protocol
    if source = input.source
      puts "  source: #{source}"
    end
    ClaudeAgent::HookResult.allow
  }

  # SessionEnd hook - fires when the session ends
  session_end_hook = ->(input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
    puts "[SessionEnd] Session #{input.session_id} ended"
    # input.session_end_reason may be "clear", "logout", "prompt_input_exit", etc.
    if reason = input.session_end_reason
      puts "  reason: #{reason}"
    end
    ClaudeAgent::HookResult.allow
  }

  # Stop hook - fires when the agent finishes
  stop_hook = ->(input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
    puts "[Stop] Agent stopped (session: #{input.session_id})"
    # input.stop_hook_active prevents infinite loops
    if input.stop_hook_active
      puts "  stop_hook_active: true (another stop hook is running)"
    end
    ClaudeAgent::HookResult.allow
  }

  # UserPromptSubmit hook - fires when a prompt is sent
  prompt_hook = ->(input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
    puts "[UserPromptSubmit] Prompt: #{input.user_prompt}"
    ClaudeAgent::HookResult.allow
  }

  hooks = ClaudeAgent::HookConfig.new(
    session_start: [session_start_hook],
    session_end: [session_end_hook],
    stop: [stop_hook],
    user_prompt_submit: [prompt_hook],
  )

  options = ClaudeAgent::AgentOptions.new(
    hooks: hooks,
    max_turns: 1,
    permission_mode: ClaudeAgent::PermissionMode::Default,
  )

  ClaudeAgent::AgentClient.open(options) do |client|
    client.query("What is 2 + 2? Answer briefly.")

    client.each_response do |message|
      if message.is_a?(ClaudeAgent::AssistantMessage) && message.has_text?
        puts "\nClaude: #{message.text}"
      end
    end
  end

  puts "\nDone!"
rescue ex
  puts "Error: #{ex.message}"
end
