# Hook PreCompact Example
#
# Demonstrates the PreCompact hook with transcript archiving.
# The PreCompact hook fires before conversation compaction and
# provides transcript_path so you can archive the full conversation.

require "../src/claude-agent-cr"

begin
  # PreCompact hook - archive transcript before compaction
  pre_compact_hook = ->(input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
    puts "[PreCompact] Compaction triggered"
    puts "  session_id: #{input.session_id}"
    puts "  trigger: #{input.trigger}" # "manual" or "auto"
    puts "  hook_event_name: #{input.hook_event_name}"

    # transcript_path points to the JSONL file with the full conversation
    if path = input.transcript_path
      puts "  transcript_path: #{path}"

      # In a real application, you would archive the transcript:
      # File.copy(path, "/backups/#{input.session_id}_#{Time.utc.to_unix}.jsonl")
      puts "  (Would archive transcript before compaction)"
    else
      puts "  transcript_path: not provided"
    end

    if instructions = input.custom_instructions
      puts "  custom_instructions: #{instructions}"
    end

    ClaudeAgent::HookResult.allow
  }

  # Notification hook - forward status updates
  notification_hook = ->(input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
    puts "[Notification] #{input.notification_title}: #{input.notification_message}"
    # notification_type can be "permission_prompt", "idle_prompt",
    # "auth_success", "elicitation_dialog"
    if ntype = input.notification_type
      puts "  type: #{ntype}"
    end
    ClaudeAgent::HookResult.allow
  }

  hooks = ClaudeAgent::HookConfig.new(
    pre_compact: [pre_compact_hook],
    notification: [notification_hook],
  )

  options = ClaudeAgent::AgentOptions.new(
    hooks: hooks,
    max_turns: 3,
    permission_mode: ClaudeAgent::PermissionMode::Default,
  )

  # Note: PreCompact only fires when the conversation gets long enough
  # to trigger compaction, or when manually triggered. This example
  # shows the hook configuration - it won't fire in a short conversation.
  ClaudeAgent::AgentClient.open(options) do |client|
    client.query("Write a brief haiku about Crystal programming.")

    client.each_response do |message|
      if message.is_a?(ClaudeAgent::AssistantMessage) && message.has_text?
        puts "\nClaude: #{message.text}"
      end
    end
  end

  puts "\nDone! (PreCompact hook would fire during long conversations)"
rescue ex
  puts "Error: #{ex.message}"
end
