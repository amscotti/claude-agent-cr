require "../src/claude-agent-cr"

# Example 41: Adaptive Thinking Display and Hook Event Streaming
#
# Demonstrates several features from the latest Claude Code releases:
#
#   1. Configuring adaptive thinking with thinking display override:
#      ThinkingConfig.adaptive(display: "summarized") to see Claude's thinking process.
#
#   2. Enabling `include_hook_events: true` so hook lifecycle events
#      are emitted by the CLI and parsed as HookEventMessage.
#
#   3. Replacing tool output via updated_tool_output in a PostToolUse hook.

puts "Starting Claude Agent with Adaptive Thinking (display: summarized)..."
puts

# Register a PostToolUse hook that overrides the output of the Read tool
post_tool_hook = ->(input : ClaudeAgent::HookInput, _tool_use_id : String, _ctx : ClaudeAgent::HookContext) do
  event = input.hook_event_name || "?"
  if event == "PostToolUse" && input.tool_name == "Read"
    puts ">>> PostToolUse hook: replacing output of Read tool!"
    # Replace tool output before it is delivered to the model
    return ClaudeAgent::HookResult.new(
      hook_specific_output: ClaudeAgent::HookSpecificOutput.new(
        hook_event_name: "PostToolUse",
        updated_tool_output: JSON::Any.new({
          "stdout"      => JSON::Any.new("Overridden content from Crystal hook!"),
          "stderr"      => JSON::Any.new(""),
          "interrupted" => JSON::Any.new(false),
        })
      )
    )
  end
  ClaudeAgent::HookResult.allow
end

hooks = ClaudeAgent::HookConfig.new(
  post_tool_use: [ClaudeAgent::HookMatcher.new(matcher: "Read", hooks: [post_tool_hook])]
)

# Configure the agent options
options = ClaudeAgent::AgentOptions.new(
  append_system_prompt: "Read CLAUDE.md and summarize it.",
  max_turns: 2,
  include_hook_events: true,
  thinking: ClaudeAgent::ThinkingConfig.adaptive(display: "summarized"),
  hooks: hooks
)

begin
  ClaudeAgent::AgentClient.open(options) do |client|
    client.query("Please read the CLAUDE.md file.")
    client.each_response do |message|
      case message
      when ClaudeAgent::AssistantMessage
        # Print thinking block and text content
        message.content.each do |block|
          if block.is_a?(ClaudeAgent::ThinkingBlock)
            puts "[Claude Thinking]: #{block.thinking[0..80]}..."
          elsif block.is_a?(ClaudeAgent::TextBlock)
            puts "Claude: #{block.text}"
          end
        end
      when ClaudeAgent::HookEventMessage
        puts "[Hook Event]: #{message.subtype} - #{message.hook_event_name}"
      when ClaudeAgent::ResultMessage
        puts "Result: #{message.subtype}"
        if deferred = message.deferred_tool_use
          puts "Deferred tool use: #{deferred.name} (ID: #{deferred.id})"
        end
      end
    end
  end
rescue ex : ClaudeAgent::CLINotFoundError
  puts "Claude CLI not installed; skipping live run."
rescue ex
  puts "Live run skipped: #{ex.message}"
end
