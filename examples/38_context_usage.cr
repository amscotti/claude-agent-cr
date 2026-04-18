require "../src/claude-agent-cr"

# Example 38: Context usage inspection + subprocess pre-warming
#
# `ClaudeAgent.startup` spins up the Claude Code subprocess without sending
# a prompt. The returned `AgentClient` has already paid the startup cost,
# so the next call to `#query` runs without boot latency. This is useful
# when you expect the first prompt to arrive shortly after construction.
#
# `AgentClient#get_context_usage` calls the `get_context_usage` control
# subtype (CLI 2.1.86+) and returns a typed `ContextUsageResponse` with
# per-category token usage, model info, and autocompact thresholds. That
# mirrors the numbers shown by the `/context` slash command.

options = ClaudeAgent::AgentOptions.new(
  allowed_tools: [] of String,
  max_turns: 1,
  append_system_prompt: "Be extremely brief.",
)

# ---------------------------------------------------------------------------
# 1. Pre-warm: start the subprocess in the background while we do other work.
# ---------------------------------------------------------------------------
puts "Pre-warming Claude Code..."
started_at = Time.instant

client = begin
  ClaudeAgent.startup(options)
rescue ex : ClaudeAgent::CLINotFoundError
  puts "Claude CLI not installed; cannot demo startup / get_context_usage."
  exit 0
end

puts "  ready in #{(Time.instant - started_at).total_milliseconds.round(1)}ms"

begin
  # -------------------------------------------------------------------------
  # 2. Fire a tiny query so the session is actually active. Ask the model
  #    for a single word so the assistant turn is fast.
  # -------------------------------------------------------------------------
  client.query("Return the word READY and nothing else.")
  client.each_response do |message|
    case message
    when ClaudeAgent::AssistantMessage
      puts "  assistant: #{message.text}" if message.has_text?
    when ClaudeAgent::ResultMessage
      puts "  result: #{message.subtype}"
    end
  end

  # -------------------------------------------------------------------------
  # 3. Ask the CLI for a context usage breakdown.
  # -------------------------------------------------------------------------
  usage = client.get_context_usage

  puts
  puts "Context usage for model #{usage.model}:"
  puts "  total: #{usage.total_tokens} / #{usage.max_tokens} (raw max #{usage.raw_max_tokens})"
  puts "  utilisation: #{usage.percentage.round(2)}%"
  puts "  auto-compact enabled? #{usage.auto_compact_enabled?}"

  unless usage.categories.empty?
    puts "  categories:"
    usage.categories.each do |category|
      puts "    - #{category.name.ljust(20)} #{category.tokens} tokens"
    end
  end
rescue ex
  # Older CLIs that do not implement `get_context_usage` surface an error
  # on the control channel. Treat that as informational.
  puts "Context usage not available on this CLI version: #{ex.message}"
ensure
  client.stop
end
