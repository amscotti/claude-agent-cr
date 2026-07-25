require "../src/claude-agent-cr"

# Example 39: New hook events
#
# Registers callbacks for three hook events exposed by recent Claude Code
# CLI releases:
#
#   * `TeammateIdle`   - a background agent is idle and available
#   * `TaskCompleted`  - a background task finished (id, status, summary)
#   * `ConfigChange`   - a settings/permission mutation happened mid-session
#
# The callbacks just print the payload they receive. On older CLIs the
# events simply never fire; the registration is harmless.

observed = [] of String

handle = ->(input : ClaudeAgent::HookInput, _tool_use_id : String, _ctx : ClaudeAgent::HookContext) do
  event = input.hook_event_name || "?"

  case event
  when "TaskCompleted"
    observed << "TaskCompleted id=#{input.task_id} status=#{input.task_status} summary=#{input.task_summary.try(&.[0..60])}"
  when "TeammateIdle"
    observed << "TeammateIdle agent_id=#{input.agent_id || "?"} type=#{input.agent_type || "?"}"
  when "ConfigChange"
    observed << "ConfigChange source=#{input.config_change_source || "?"} diff_keys=#{input.config_change_diff.try(&.keys.join(",")) || "(none)"}"
  end

  ClaudeAgent::HookResult.allow
end

hooks = ClaudeAgent::HookConfig.new(
  teammate_idle: [handle.as(ClaudeAgent::HookCallback)],
  task_completed: [handle.as(ClaudeAgent::HookCallback)],
  config_change: [handle.as(ClaudeAgent::HookCallback)],
)

options = ClaudeAgent::AgentOptions.new(
  allowed_tools: [] of String,
  max_turns: 1,
  append_system_prompt: "Respond with one word.",
  hooks: hooks,
)

puts "Registered hooks: TeammateIdle, TaskCompleted, ConfigChange"
puts "Running a tiny query; the events only fire on CLI versions that emit them."
puts

begin
  ClaudeAgent::AgentClient.open(options) do |client|
    client.query("Reply with OK.")
    client.each_response do |message|
      case message
      when ClaudeAgent::AssistantMessage
        puts "assistant: #{message.text}" if message.has_text?
      when ClaudeAgent::ResultMessage
        puts "result: #{message.subtype}"
      end
    end
  end
rescue ClaudeAgent::CLINotFoundError
  puts "Claude CLI not installed; skipping live run."
rescue ex
  puts "Live run skipped: #{ex.message}"
end

puts
if observed.empty?
  puts "(no new-hook events observed on this CLI version)"
else
  puts "Observed #{observed.size} event(s):"
  observed.each { |line| puts "  - #{line}" }
end
