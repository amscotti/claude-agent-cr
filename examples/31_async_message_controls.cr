require "uuid"
require "../src/claude-agent-cr"

# This example shows three TypeScript-parity session features on AgentClient:
# 1. settings - inspect the effective runtime settings
# 2. prompt suggestions - receive a prompt_suggestion message after a turn
# 3. cancel_async_message - cancel a queued user message by UUID before it runs

options = ClaudeAgent::AgentOptions.new(
  prompt_suggestions: true,
  max_turns: 6,
)

ClaudeAgent::AgentClient.open(options) do |client|
  settings = client.settings
  applied = settings["applied"]?.try(&.as_h?)

  puts "Effective settings"
  puts "=" * 50
  if applied
    puts "model: #{applied["model"]?.try(&.as_s?) || "(unknown)"}"
    puts "effort: #{applied["effort"]?.try(&.as_s?) || "(unknown)"}"
  else
    puts "No applied settings were returned."
  end

  puts
  puts "Running a short query with prompt suggestions enabled..."
  puts

  client.query("Answer with exactly: SUGGESTION_DEMO_OK")
  client.each_response do |message|
    case message
    when ClaudeAgent::AssistantMessage
      print message.text if message.has_text?
    when ClaudeAgent::PromptSuggestionMessage
      puts
      puts
      puts "Prompt suggestion: #{message.suggestion}"
    when ClaudeAgent::ResultMessage
      puts
      puts
      puts "Stop reason: #{message.stop_reason || "(none)"}"
    end
  end

  queued_uuid = UUID.random.to_s

  puts
  puts "Queueing a second message and attempting to cancel it before execution..."
  client.query("Think for a bit and then answer with exactly: FIRST_TURN_FINISHED")
  client.send_user_message("If you receive this queued message, answer with QUEUED_MESSAGE_EXECUTED", uuid: queued_uuid)
  cancelled = client.cancel_async_message(queued_uuid)
  puts "Queued message cancelled: #{cancelled}"

  client.each_response do |message|
    case message
    when ClaudeAgent::AssistantMessage
      print message.text if message.has_text?
    when ClaudeAgent::PromptSuggestionMessage
      puts
      puts
      puts "Prompt suggestion: #{message.suggestion}"
    when ClaudeAgent::ResultMessage
      puts
      puts
      puts "First turn complete."
    end
  end

  puts
  puts "Sending a final confirmation message..."
  client.query("Answer with exactly: SESSION_CONTINUES_OK")
  client.each_response do |message|
    case message
    when ClaudeAgent::AssistantMessage
      print message.text if message.has_text?
    when ClaudeAgent::PromptSuggestionMessage
      puts
      puts
      puts "Prompt suggestion: #{message.suggestion}"
    when ClaudeAgent::ResultMessage
      puts
      puts
      puts "Final turn complete."
    end
  end
end
