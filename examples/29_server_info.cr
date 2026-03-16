require "../src/claude-agent-cr"

# This example connects to Claude, prints the initialization metadata exposed by
# the SDK, then runs a tiny query so you can see the session continue normally.

ClaudeAgent::AgentClient.open do |client|
  info = client.get_server_info

  puts "Claude server info"
  puts "=" * 50

  if info
    puts "Commands available: #{info.commands.size}"
    puts "Output style: #{info.output_style || "(unknown)"}"
    puts "Available output styles: #{info.available_output_styles.join(", ")}"
    puts "Supported agents: #{client.supported_agents.map(&.name).join(", ")}" unless client.supported_agents.empty?

    if first_command = info.commands.first?
      puts "First command: /#{first_command.name}"
      puts "  #{first_command.description}" if first_command.description
    end
  else
    puts "No initialization info was returned."
  end

  settings = client.settings
  applied = settings["applied"]?.try(&.as_h?)

  puts
  puts "Applied settings snapshot:"
  if applied
    puts "  model: #{applied["model"]?.try(&.as_s?) || "(unknown)"}"
    puts "  effort: #{applied["effort"]?.try(&.as_s?) || "(unknown)"}"
  else
    puts "  no applied settings returned"
  end

  puts
  puts "Sending a quick follow-up query..."
  puts

  client.query("Answer with exactly: OK")

  client.each_response do |message|
    case message
    when ClaudeAgent::AssistantMessage
      print message.text if message.has_text?
    when ClaudeAgent::ResultMessage
      puts
      puts
      puts "Done: #{message.subtype}"
    end
  end
end
