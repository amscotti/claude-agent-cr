require "../src/claude-agent-cr"

options = ClaudeAgent::AgentOptions.new(
  allowed_tools: ["Read", "Glob", "Grep", "Agent"],
  prompt_suggestions: true,
  agent_progress_summaries: true,
  max_turns: 4,
)

ClaudeAgent::AgentClient.open(options) do |client|
  client.query("Inspect this repository and suggest one testing improvement. Use the Agent tool if it helps.")

  client.each_response do |message|
    case message
    when ClaudeAgent::InitMessage
      puts "Session initialized: #{message.session_id}"
      puts "Output style: #{message.output_style || "(unknown)"}"
      puts "Slash commands: #{message.slash_commands.join(", ")}" unless message.slash_commands.empty?
      puts
    when ClaudeAgent::TaskStartedMessage
      puts "[task started] #{message.task_id}: #{message.description}"
    when ClaudeAgent::TaskProgressMessage
      tokens = message.usage.total_tokens || 0
      summary = message.summary ? " summary=#{message.summary}" : ""
      puts "[task progress] #{message.task_id}: #{message.description} (tokens=#{tokens})#{summary}"
    when ClaudeAgent::TaskNotificationMessage
      puts "[task #{message.status}] #{message.task_id}: #{message.summary || "(no summary)"}"
    when ClaudeAgent::RateLimitEvent
      info = message.rate_limit_info
      utilization = info.utilization.try { |value| (value * 100).round(1) }
      summary = utilization ? "#{utilization}% used" : info.status
      puts "[rate limit] #{info.status} (#{summary})"
    when ClaudeAgent::ElicitationCompleteMessage
      puts "[elicitation complete] #{message.mcp_server_name} id=#{message.elicitation_id}"
    when ClaudeAgent::PromptSuggestionMessage
      puts "[prompt suggestion] #{message.suggestion}"
    when ClaudeAgent::GenericSystemMessage
      puts "[system/#{message.subtype}] keys=#{message.data.keys.join(", ")}"
    when ClaudeAgent::UnknownMessage
      puts "[unknown/#{message.type}] keys=#{message.data.keys.join(", ")}"
    when ClaudeAgent::AssistantMessage
      print message.text if message.has_text?
    when ClaudeAgent::ResultMessage
      puts
      puts
      puts "Done: #{message.subtype}"
    end
  end
end
