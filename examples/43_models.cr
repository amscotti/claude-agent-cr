require "../src/claude-agent-cr"

# Example 43: Model IDs and live set_model
#
# AgentOptions#model accepts free-form strings. ClaudeAgent::Models exposes
# well-known IDs for discoverability; the CLI must support the chosen ID for
# your account. Availability varies by Claude Code version and plan.

options = ClaudeAgent::AgentOptions.new(
  model: ClaudeAgent::Models::SONNET_4_5,
  fallback_model: ClaudeAgent::Models::HAIKU_4_5,
  max_turns: 2,
  allowed_tools: [] of String,
)

puts "Known model constants (subset):"
[
  ClaudeAgent::Models::SONNET_5,
  ClaudeAgent::Models::OPUS_5,
  ClaudeAgent::Models::FABLE_5,
  ClaudeAgent::Models::MYTHOS_5,
  ClaudeAgent::Models::OPUS_4_8,
  ClaudeAgent::Models::OPUS_4_7,
  ClaudeAgent::Models::OPUS_4_6,
  ClaudeAgent::Models::SONNET_4_6,
  ClaudeAgent::Models::SONNET_4_5,
  ClaudeAgent::Models::HAIKU_4_5,
].each do |id|
  puts "  #{id}"
end

puts
puts "Opening session with #{options.model}..."

ClaudeAgent::AgentClient.open(options) do |client|
  if info = client.get_server_info
    puts "CLI advertised models:"
    info.models.first(8).each do |model|
      caps = [] of String
      caps << "effort" if model.supports_effort?
      caps << "adaptive_thinking" if model.supports_adaptive_thinking?
      caps << "fast_mode" if model.supports_fast_mode?
      suffix = caps.empty? ? "" : " (#{caps.join(", ")})"
      puts "  #{model.value}#{suffix}"
    end

    if reason = info.fast_mode_disabled_reason
      puts "Fast mode disabled: #{reason}"
    end
  end

  client.query("Reply with exactly: OK")
  client.each_response do |message|
    case message
    when ClaudeAgent::AssistantMessage
      print message.text if message.has_text?
    when ClaudeAgent::ResultMessage
      puts
      puts "First turn done (#{message.subtype})."
    end
  end

  # Live model swap — only succeeds when the CLI accepts the target ID.
  target = ClaudeAgent::Models::OPUS_4_7
  puts
  puts "Switching model to #{target} (requires CLI support)..."
  client.set_model(target)

  client.query("Reply with exactly: SWITCHED")
  client.each_response do |message|
    case message
    when ClaudeAgent::AssistantMessage
      print message.text if message.has_text?
    when ClaudeAgent::ResultMessage
      puts
      puts "Second turn done (#{message.subtype})."
    end
  end
end
