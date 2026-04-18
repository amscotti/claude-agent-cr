require "../src/claude-agent-cr"
require "file_utils"
require "uuid"

# Example 33: Session forks, subagent transcripts, and deletion
#
# Demonstrates the local session helpers that work without talking to the CLI:
#
#   * `ClaudeAgent.fork_session` - copy a session to a new UUID, optionally
#     slicing up to a specific message.
#   * `ClaudeAgent.list_subagents` - discover subagent IDs under a session.
#   * `ClaudeAgent.get_subagent_messages` - read a subagent's transcript.
#   * `ClaudeAgent.delete_session` - remove a session file plus its sibling
#     subagent transcript directory.
#
# To keep the example hermetic we synthesize a small session transcript on
# disk under a temporary `CLAUDE_CONFIG_DIR` and operate on it directly.

# ---------------------------------------------------------------------------
# Set up an isolated Claude config directory so we don't touch real sessions.
# ---------------------------------------------------------------------------
ROOT       = "/tmp/claude-agent-cr-example-33-#{Process.pid}"
CONFIG_DIR = File.join(ROOT, ".claude")
PROJECT    = File.join(ROOT, "project")

FileUtils.mkdir_p(File.join(CONFIG_DIR, "projects"))
FileUtils.mkdir_p(PROJECT)

ENV["CLAUDE_CONFIG_DIR"] = CONFIG_DIR

# Claude Code names project directories by sanitized path, matching what the
# SDK itself produces. `sanitize_path` is public so examples can reproduce it.
canonical_project = File.realpath(PROJECT)
sanitized = ClaudeAgent::SessionStorage.sanitize_path(canonical_project)
project_dir = File.join(CONFIG_DIR, "projects", sanitized)
FileUtils.mkdir_p(project_dir)

# ---------------------------------------------------------------------------
# Build a minimal two-turn transcript for the main session and one subagent.
# ---------------------------------------------------------------------------
session_id = UUID.random.to_s
user_uuid = UUID.random.to_s
asst_uuid = UUID.random.to_s
subagent_uuid = UUID.random.to_s

def entry(type : String, uuid : String, parent : String?, session_id : String, content : String)
  {
    "type"       => JSON::Any.new(type),
    "uuid"       => JSON::Any.new(uuid),
    "parentUuid" => parent ? JSON::Any.new(parent) : JSON::Any.new(nil),
    "sessionId"  => JSON::Any.new(session_id),
    "message"    => JSON::Any.new({
      "role"    => JSON::Any.new(type == "assistant" ? "assistant" : "user"),
      "content" => JSON::Any.new(content),
    }),
    "timestamp" => JSON::Any.new(Time.utc.to_rfc3339),
  }.to_json
end

main_transcript = [
  entry("user", user_uuid, nil, session_id, "plan a fork experiment"),
  entry("assistant", asst_uuid, user_uuid, session_id, "Here is my plan..."),
]
File.write(File.join(project_dir, "#{session_id}.jsonl"), main_transcript.join('\n') + "\n")

# Subagents live at <projectDir>/<sessionId>/subagents/agent-<id>.jsonl
subagents_dir = File.join(project_dir, session_id, "subagents")
FileUtils.mkdir_p(subagents_dir)

subagent_user_uuid = UUID.random.to_s
subagent_transcript = [
  entry("user", subagent_user_uuid, nil, session_id, "analyse repo layout"),
  entry("assistant", subagent_uuid, subagent_user_uuid, session_id, "I counted 42 source files."),
]
File.write(File.join(subagents_dir, "agent-analyser.jsonl"), subagent_transcript.join('\n') + "\n")

puts "Synthesised session #{session_id} in #{project_dir}"
puts

# ---------------------------------------------------------------------------
# 1. Walk the main session transcript.
# ---------------------------------------------------------------------------
puts "Main session messages:"
ClaudeAgent.get_session_messages(session_id, directory: PROJECT).each_with_index do |msg, i|
  role = msg.message["role"]?.try(&.as_s?) || msg.type
  text = msg.message["content"]?.try(&.as_s?) || ""
  puts "  #{i + 1}. [#{role}] #{text}"
end
puts

# ---------------------------------------------------------------------------
# 2. Discover subagents and read a transcript.
# ---------------------------------------------------------------------------
puts "Subagents attached to this session:"
ids = ClaudeAgent.list_subagents(session_id, directory: PROJECT)
ids.each { |id| puts "  - #{id}" }
puts

unless ids.empty?
  puts "Messages from subagent '#{ids.first}':"
  ClaudeAgent.get_subagent_messages(session_id, ids.first, directory: PROJECT).each_with_index do |msg, i|
    role = msg.message["role"]?.try(&.as_s?) || msg.type
    text = msg.message["content"]?.try(&.as_s?) || ""
    puts "  #{i + 1}. [#{role}] #{text}"
  end
  puts
end

# ---------------------------------------------------------------------------
# 3. Fork the session into a new branch with remapped UUIDs.
# ---------------------------------------------------------------------------
fork = ClaudeAgent.fork_session(session_id, directory: PROJECT, title: "Example 33 fork")
puts "Forked session: #{fork.session_id}"

forked_path = File.join(project_dir, "#{fork.session_id}.jsonl")
puts "  file: #{forked_path}"
puts "  size: #{File.size(forked_path)} bytes"

forked_info = ClaudeAgent.get_session_info(fork.session_id, directory: PROJECT)
if forked_info
  puts "  title: #{forked_info.custom_title || "(none)"}"
end
puts

# ---------------------------------------------------------------------------
# 4. Delete the original session; its subagent transcripts go with it.
# ---------------------------------------------------------------------------
puts "Deleting original session #{session_id}..."
ClaudeAgent.delete_session(session_id, directory: PROJECT)

puts "  session file still present? #{File.exists?(File.join(project_dir, "#{session_id}.jsonl"))}"
puts "  subagent directory still present? #{Dir.exists?(File.join(project_dir, session_id))}"
puts "  fork still present? #{File.exists?(forked_path)}"

# ---------------------------------------------------------------------------
# Clean up the temporary config root so the example leaves no residue.
# ---------------------------------------------------------------------------
FileUtils.rm_rf(ROOT)
