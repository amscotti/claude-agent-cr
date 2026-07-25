require "../src/claude-agent-cr"

# Demonstrates InMemorySessionStore append/load, store-backed helpers, and
# how to enable live transcript mirroring with AgentClient:
#
#   options = ClaudeAgent::AgentOptions.new(
#     session_store: store,
#     session_store_flush: "batched", # or "eager"
#     # resume: existing_session_id, # materializes from the store into a temp dir
#   )
#   ClaudeAgent::AgentClient.open(options) do |client|
#     client.query("...")
#     client.each_response { |msg| ... }
#   end
#
# The CLI is started with --session-mirror; transcript_mirror frames are peeled
# off the stream and appended to the store (not yielded to each_response).

store = ClaudeAgent::InMemorySessionStore.new
directory = Dir.current
project_key = ClaudeAgent.project_key_for_directory(directory)
session_id = UUID.random.to_s
key = ClaudeAgent::SessionKey.new(project_key, session_id)

user_uuid = UUID.random.to_s
assistant_uuid = UUID.random.to_s

puts "Appending a short transcript to InMemorySessionStore..."
store.append(key, [
  ClaudeAgent::SessionStoreEntry.from_hash({
    "type"      => JSON::Any.new("user"),
    "uuid"      => JSON::Any.new(user_uuid),
    "sessionId" => JSON::Any.new(session_id),
    "timestamp" => JSON::Any.new(Time.utc.to_rfc3339),
    "message"   => JSON::Any.new({
      "role"    => JSON::Any.new("user"),
      "content" => JSON::Any.new("Hello from SessionStore"),
    }),
  }),
  ClaudeAgent::SessionStoreEntry.from_hash({
    "type"       => JSON::Any.new("assistant"),
    "uuid"       => JSON::Any.new(assistant_uuid),
    "parentUuid" => JSON::Any.new(user_uuid),
    "sessionId"  => JSON::Any.new(session_id),
    "timestamp"  => JSON::Any.new(Time.utc.to_rfc3339),
    "message"    => JSON::Any.new({
      "role"    => JSON::Any.new("assistant"),
      "content" => JSON.parse(%([{"type":"text","text":"Stored reply"}])),
    }),
  }),
])

loaded = store.load(key)
puts "Loaded #{loaded.try(&.size) || 0} entries"

ClaudeAgent.rename_session_via_store(store, session_id, "SessionStore demo", directory: directory)
ClaudeAgent.tag_session_via_store(store, session_id, "example", directory: directory)

messages = ClaudeAgent.get_session_messages_from_store(store, session_id, directory: directory)
puts "Messages: #{messages.size}"
messages.each do |msg|
  puts "  #{msg.type}: #{msg.uuid}"
end

info = ClaudeAgent.get_session_info_from_store(store, session_id, directory: directory)
if info
  puts "Summary: #{info.summary}"
  puts "Title:   #{info.custom_title}"
  puts "Tag:     #{info.tag}"
end

sessions = ClaudeAgent.list_sessions_from_store(store, directory: directory)
puts "Listed #{sessions.size} session(s) for project_key=#{project_key}"

# Idempotent re-append of the same uuid is a no-op for InMemorySessionStore.
before = store.get_entries(key).size
store.append(key, [
  ClaudeAgent::SessionStoreEntry.from_hash({
    "type"      => JSON::Any.new("user"),
    "uuid"      => JSON::Any.new(user_uuid),
    "sessionId" => JSON::Any.new(session_id),
    "message"   => JSON::Any.new({
      "role"    => JSON::Any.new("user"),
      "content" => JSON::Any.new("duplicate"),
    }),
  }),
])
puts "Entries after duplicate uuid append: #{store.get_entries(key).size} (was #{before})"

ClaudeAgent.delete_session_via_store(store, session_id, directory: directory)
puts "After delete, load is nil: #{store.load(key).nil?}"
