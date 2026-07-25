require "../../src/claude-agent-cr"
require "file_utils"
require "uuid"

# Durable FileSessionStore demo + conformance.
#
#   crystal run examples/session-stores/file_demo.cr

root = File.join(Dir.tempdir, "claude-file-store-demo-#{UUID.random}")
Dir.mkdir_p(root)

begin
  store = ClaudeAgent::FileSessionStore.new(root)
  puts "Running SessionStoreConformance on FileSessionStore…"
  n = ClaudeAgent::SessionStoreConformance.run(store)
  puts "  #{n} checks passed"

  project = ClaudeAgent.project_key_for_directory(Dir.current)
  sid = UUID.random.to_s
  key = ClaudeAgent::SessionKey.new(project, sid)

  store.append(key, [
    ClaudeAgent::SessionStoreEntry.from_hash({
      "type"      => JSON::Any.new("user"),
      "uuid"      => JSON::Any.new(UUID.random.to_s),
      "sessionId" => JSON::Any.new(sid),
      "message"   => JSON::Any.new({
        "role"    => JSON::Any.new("user"),
        "content" => JSON::Any.new("persisted to disk"),
      }),
    }),
  ])

  reopened = ClaudeAgent::FileSessionStore.new(root)
  loaded = reopened.load(key)
  puts "Reopened store has #{loaded.try(&.size) || 0} entr(y/ies)"
  puts "Listed sessions: #{reopened.list_sessions(project).map(&.session_id)}"
ensure
  FileUtils.rm_rf(root) if Dir.exists?(root)
end
