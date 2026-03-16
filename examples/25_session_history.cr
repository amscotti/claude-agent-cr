require "../src/claude-agent-cr"

# This example creates a real session with Claude, then inspects it using the
# session utilities exposed by the Crystal SDK.

options = ClaudeAgent::AgentOptions.new(
  allowed_tools: ["Read", "Glob", "Grep"],
  max_turns: 3,
)

session_id = nil.as(String?)

puts "Running a real agent query..."
puts

ClaudeAgent.query("Summarize the purpose of this repository in 2 sentences.", options) do |message|
  case message
  when ClaudeAgent::SystemMessage
    session_id ||= message.session_id if message.subtype == "init"
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
puts "Recent sessions for #{Dir.current}:"
ClaudeAgent.list_sessions(directory: Dir.current, limit: 5).each_with_index do |session, index|
  puts "#{index + 1}. #{session.summary}"
  puts "   session_id: #{session.session_id}"
  puts "   cwd: #{session.cwd || "(unknown)"}"
  puts "   last_modified: #{session.last_modified}"
end

puts
puts "Messages from session #{captured_session_id}:"
ClaudeAgent.get_session_messages(captured_session_id, directory: Dir.current).each_with_index do |message, index|
  role = message.message["role"]?.try(&.as_s?) || message.type
  content = message.message["content"]?
  rendered = content ? content.to_json : "null"

  puts "#{index + 1}. #{role} (#{message.uuid})"
  puts "   #{rendered}"
end
