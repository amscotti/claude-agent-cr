require "../src/claude-agent-cr"

# This example creates a real Claude session, then uses the session mutation
# APIs to inspect, rename, tag, and clear metadata on the saved session file.

options = ClaudeAgent::AgentOptions.new(
  allowed_tools: ["Read", "Glob", "Grep"],
  max_turns: 3,
)

session_id = nil.as(String?)

puts "Running a real agent query..."
puts

ClaudeAgent.query("Answer with exactly: SESSION_MUTATION_OK", options) do |message|
  case message
  when ClaudeAgent::InitMessage
    session_id ||= message.session_id
  when ClaudeAgent::AssistantMessage
    print message.text if message.has_text?
  when ClaudeAgent::ResultMessage
    puts
    puts
    puts "Run complete."
  end
end

unless session_id
  puts "No session ID was captured."
  exit 1
end

captured_session_id = session_id.as(String)

puts
puts "Original session info:"
original = ClaudeAgent.get_session_info(captured_session_id, directory: Dir.current)
if original
  puts "  summary: #{original.summary}"
  puts "  custom_title: #{original.custom_title || "(none)"}"
  puts "  tag: #{original.tag || "(none)"}"
  puts "  created_at: #{original.created_at || 0}"
else
  puts "  session not found"
  exit 1
end

new_title = "Crystal SDK session mutation demo"
new_tag = "demo-session"

puts
puts "Renaming session..."
ClaudeAgent.rename_session(captured_session_id, new_title, directory: Dir.current)

puts "Tagging session..."
ClaudeAgent.tag_session(captured_session_id, new_tag, directory: Dir.current)

updated = ClaudeAgent.get_session_info(captured_session_id, directory: Dir.current)

puts
puts "Updated session info:"
if updated
  puts "  summary: #{updated.summary}"
  puts "  custom_title: #{updated.custom_title || "(none)"}"
  puts "  tag: #{updated.tag || "(none)"}"
else
  puts "  session not found"
  exit 1
end

puts
puts "Clearing session tag..."
ClaudeAgent.tag_session(captured_session_id, nil, directory: Dir.current)

cleared = ClaudeAgent.get_session_info(captured_session_id, directory: Dir.current)

puts "After clearing tag:"
if cleared
  puts "  summary: #{cleared.summary}"
  puts "  custom_title: #{cleared.custom_title || "(none)"}"
  puts "  tag: #{cleared.tag || "(none)"}"
end
