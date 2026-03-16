require "../src/claude-agent-cr"

# This example uses a real streaming agent session, then changes the live
# permission mode and model before sending follow-up work.

options = ClaudeAgent::AgentOptions.new(
  allowed_tools: ["Read", "Glob", "Grep"],
  permission_mode: ClaudeAgent::PermissionMode::Default,
  model: "claude-sonnet-4-5",
  max_turns: 4,
)

ClaudeAgent::AgentClient.open(options) do |client|
  puts "Initial query with default permissions..."
  puts

  client.query("Give me a short overview of this repository.")
  client.each_response do |message|
    case message
    when ClaudeAgent::AssistantMessage
      print message.text if message.has_text?
    when ClaudeAgent::ResultMessage
      puts
      puts
      puts "Initial run finished."
    end
  end

  puts
  puts "Switching permission mode to plan..."
  client.set_permission_mode(ClaudeAgent::PermissionMode::Plan)

  puts "Switching model to claude-sonnet-4-5..."
  client.set_model("claude-sonnet-4-5")

  puts
  puts "Sending a planning follow-up under the new control settings..."
  puts

  client.query("Without using tools, give two concise test-suite improvements for this SDK in one sentence.")
  client.each_response do |message|
    case message
    when ClaudeAgent::AssistantMessage
      print message.text if message.has_text?
    when ClaudeAgent::ResultMessage
      puts
      puts
      puts "Planning run finished."
    end
  end

  puts
  puts "Current MCP server status:"
  status = client.get_mcp_status

  if status.mcp_servers.empty?
    puts "  No MCP servers are configured for this session."
  else
    status.mcp_servers.each do |server|
      puts "  #{server.name}: #{server.status}"
      puts "    error: #{server.error}" if server.error
    end
  end

  puts
  puts "Applying flag settings..."
  client.apply_flag_settings({
    "verbose" => JSON::Any.new(true),
  })

  puts "Generating a session title..."
  title = client.generate_session_title(
    "Repository overview and test improvement planning",
    persist: false,
  )
  puts "  Generated title: #{title || "(none returned)"}"

  puts
  puts "All dynamic controls exercised."
end
