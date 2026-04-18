require "../src/claude-agent-cr"
require "file_utils"
require "uuid"

# Example 36: Transcript-level controls
#
# Demonstrates two transcript-related additions:
#
#   1. `should_query: false` on `send_user_message` / `query` - appends the
#      message to the transcript without triggering an assistant turn. Handy
#      for seeding context into a session before the real prompt.
#
#   2. `include_system_messages: true` on `ClaudeAgent.get_session_messages`
#      returns system entries in addition to the usual user/assistant chain,
#      so clients can surface tool results or status updates from the
#      transcript on replay.

# ---------------------------------------------------------------------------
# 1. Synthesise a session file with a system entry alongside user/assistant
#    so we can inspect the new filter behaviour without needing a live CLI.
# ---------------------------------------------------------------------------
ROOT       = "/tmp/claude-agent-cr-example-36-#{Process.pid}"
CONFIG_DIR = File.join(ROOT, ".claude")
PROJECT    = File.join(ROOT, "project")

FileUtils.mkdir_p(File.join(CONFIG_DIR, "projects"))
FileUtils.mkdir_p(PROJECT)
ENV["CLAUDE_CONFIG_DIR"] = CONFIG_DIR

canonical = File.realpath(PROJECT)
sanitized = ClaudeAgent::SessionStorage.sanitize_path(canonical)
project_dir = File.join(CONFIG_DIR, "projects", sanitized)
FileUtils.mkdir_p(project_dir)

session_id = UUID.random.to_s
user_uuid = UUID.random.to_s
sys_uuid = UUID.random.to_s
asst_uuid = UUID.random.to_s

def transcript_entry(type : String, uuid : String, parent : String?, session_id : String, content : String)
  role = type == "assistant" ? "assistant" : type == "system" ? "system" : "user"
  {
    "type"       => JSON::Any.new(type),
    "uuid"       => JSON::Any.new(uuid),
    "parentUuid" => parent ? JSON::Any.new(parent) : JSON::Any.new(nil),
    "sessionId"  => JSON::Any.new(session_id),
    "message"    => JSON::Any.new({
      "role"    => JSON::Any.new(role),
      "content" => JSON::Any.new(content),
    }),
    "timestamp" => JSON::Any.new(Time.utc.to_rfc3339),
  }.to_json
end

lines = [
  transcript_entry("user", user_uuid, nil, session_id, "plan a release"),
  transcript_entry("system", sys_uuid, user_uuid, session_id, "tool use: Read(README.md)"),
  transcript_entry("assistant", asst_uuid, sys_uuid, session_id, "I suggest bumping version..."),
]
File.write(File.join(project_dir, "#{session_id}.jsonl"), lines.join('\n') + "\n")

puts "Default get_session_messages (user/assistant only):"
ClaudeAgent.get_session_messages(session_id, directory: PROJECT).each do |msg|
  puts "  [#{msg.type}] #{msg.message["content"]?.try(&.as_s?) || "(no content)"}"
end
puts

puts "With include_system_messages: true:"
ClaudeAgent.get_session_messages(
  session_id,
  directory: PROJECT,
  include_system_messages: true,
).each do |msg|
  puts "  [#{msg.type}] #{msg.message["content"]?.try(&.as_s?) || "(no content)"}"
end
puts

# ---------------------------------------------------------------------------
# 2. Best-effort live demo of `should_query: false`. The first message is
#    appended without triggering a turn; the second message does trigger.
#    On unsupported CLIs the SDK still succeeds because `should_query` is
#    simply omitted from the JSON when true.
# ---------------------------------------------------------------------------
begin
  ClaudeAgent::AgentClient.open(ClaudeAgent::AgentOptions.new(max_turns: 2)) do |client|
    puts "Seeding context without an assistant turn..."
    client.send_user_message("Remember: my favourite colour is teal.", should_query: false)

    puts "Now asking a real question..."
    client.query("What is my favourite colour?")

    client.each_response do |message|
      case message
      when ClaudeAgent::AssistantMessage
        puts message.text if message.has_text?
      when ClaudeAgent::ResultMessage
        puts
        puts "Result: #{message.subtype}"
      end
    end
  end
rescue ex : ClaudeAgent::CLINotFoundError
  puts "Claude CLI not installed; skipped the live portion."
rescue ex
  puts "Live portion skipped: #{ex.message}"
end

FileUtils.rm_rf(ROOT)
