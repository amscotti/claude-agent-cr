require "file_utils"
require "json"
require "uuid"
require "./spec_helper"

private def store_entry(
  type : String,
  uuid : String? = nil,
  timestamp : String? = "2024-01-01T00:00:00.000Z",
  **extra,
) : ClaudeAgent::SessionStoreEntry
  hash = {} of String => JSON::Any
  hash["type"] = JSON::Any.new(type)
  hash["uuid"] = JSON::Any.new(uuid) if uuid
  hash["timestamp"] = JSON::Any.new(timestamp) if timestamp
  extra.each do |key, value|
    hash[key.to_s] = case value
                     when String    then JSON::Any.new(value)
                     when Bool      then JSON::Any.new(value)
                     when Int32     then JSON::Any.new(value.to_i64)
                     when Int64     then JSON::Any.new(value)
                     when Nil       then JSON::Any.new(nil)
                     when JSON::Any then value
                     else
                       JSON::Any.new(value.to_s)
                     end
  end
  ClaudeAgent::SessionStoreEntry.from_hash(hash)
end

private def user_entry(
  text : String,
  uuid : String,
  session_id : String,
  parent : String? = nil,
) : ClaudeAgent::SessionStoreEntry
  message = {
    "role"    => JSON::Any.new("user"),
    "content" => JSON::Any.new(text),
  }
  hash = {
    "type"      => JSON::Any.new("user"),
    "uuid"      => JSON::Any.new(uuid),
    "sessionId" => JSON::Any.new(session_id),
    "timestamp" => JSON::Any.new("2024-01-01T00:00:00.000Z"),
    "message"   => JSON::Any.new(message),
  } of String => JSON::Any
  hash["parentUuid"] = parent ? JSON::Any.new(parent) : JSON::Any.new(nil)
  ClaudeAgent::SessionStoreEntry.from_hash(hash)
end

private def assistant_entry(
  text : String,
  uuid : String,
  session_id : String,
  parent : String,
) : ClaudeAgent::SessionStoreEntry
  content = [{"type" => "text", "text" => text}]
  message = {
    "role"    => JSON::Any.new("assistant"),
    "content" => JSON.parse(content.to_json),
  }
  ClaudeAgent::SessionStoreEntry.from_hash({
    "type"       => JSON::Any.new("assistant"),
    "uuid"       => JSON::Any.new(uuid),
    "parentUuid" => JSON::Any.new(parent),
    "sessionId"  => JSON::Any.new(session_id),
    "timestamp"  => JSON::Any.new("2024-01-01T00:00:01.000Z"),
    "message"    => JSON::Any.new(message),
  })
end

private def with_temp_claude_config(&)
  original = ENV["CLAUDE_CONFIG_DIR"]?
  root = "/tmp/claude-agent-cr-store-#{Process.pid}-#{Random.rand(1_000_000)}"
  config_dir = File.join(root, ".claude")
  FileUtils.mkdir_p(File.join(config_dir, "projects"))
  ENV["CLAUDE_CONFIG_DIR"] = config_dir

  yield config_dir
ensure
  if original
    ENV["CLAUDE_CONFIG_DIR"] = original
  else
    ENV.delete("CLAUDE_CONFIG_DIR")
  end
  FileUtils.rm_rf(root) if root
end

describe ClaudeAgent::SessionKey do
  it "builds storage keys with and without subpath" do
    main = ClaudeAgent::SessionKey.new("proj", "sess")
    main.storage_key.should eq("proj/sess")
    main.main?.should be_true

    sub = ClaudeAgent::SessionKey.new("proj", "sess", "subagents/agent-1")
    sub.storage_key.should eq("proj/sess/subagents/agent-1")
    sub.main?.should be_false
  end
end

describe ClaudeAgent::SessionStoreEntry do
  it "round-trips through to_h with type first and unmapped fields" do
    entry = ClaudeAgent::SessionStoreEntry.from_hash({
      "type"      => JSON::Any.new("user"),
      "uuid"      => JSON::Any.new("u-1"),
      "sessionId" => JSON::Any.new("s-1"),
      "timestamp" => JSON::Any.new("2024-01-01T00:00:00Z"),
    })
    entry.type.should eq("user")
    entry.uuid.should eq("u-1")
    entry.string_field("sessionId").should eq("s-1")
    entry.to_h["type"].as_s.should eq("user")
    entry.to_h["sessionId"].as_s.should eq("s-1")
  end
end

describe ClaudeAgent::InMemorySessionStore do
  it "appends and loads entries in order" do
    store = ClaudeAgent::InMemorySessionStore.new
    key = ClaudeAgent::SessionKey.new("proj", "sess-a")
    e1 = store_entry("user", "u1")
    e2 = store_entry("assistant", "a1")

    store.append(key, [e1, e2])
    loaded = store.load(key)
    loaded.should_not be_nil
    if entries = loaded
      entries.map(&.uuid).should eq(["u1", "a1"])
    end
  end

  it "returns nil for never-written keys" do
    store = ClaudeAgent::InMemorySessionStore.new
    store.load(ClaudeAgent::SessionKey.new("p", "missing")).should be_nil
  end

  it "treats uuid as an idempotency key" do
    store = ClaudeAgent::InMemorySessionStore.new
    key = ClaudeAgent::SessionKey.new("proj", "sess-idemp")
    first = store_entry("user", "same-uuid", content_marker: "first")
    second = store_entry("user", "same-uuid", content_marker: "second")
    third = store_entry("user", "other-uuid")

    store.append(key, [first, second, third])
    store.append(key, [second]) # re-append duplicate

    entries = store.get_entries(key)
    entries.size.should eq(2)
    entries.map(&.uuid).should eq(["same-uuid", "other-uuid"])
  end

  it "appends entries without uuid without dedup" do
    store = ClaudeAgent::InMemorySessionStore.new
    key = ClaudeAgent::SessionKey.new("proj", "sess-title")
    title = store_entry("custom-title", nil)
    store.append(key, [title, title])
    store.get_entries(key).size.should eq(2)
  end

  it "lists main sessions only for a project_key" do
    store = ClaudeAgent::InMemorySessionStore.new
    store.append(ClaudeAgent::SessionKey.new("proj", "a"), [store_entry("x", "1")])
    store.append(ClaudeAgent::SessionKey.new("proj", "b"), [store_entry("x", "2")])
    store.append(ClaudeAgent::SessionKey.new("other", "c"), [store_entry("x", "3")])
    store.append(
      ClaudeAgent::SessionKey.new("proj", "a", "subagents/agent-1"),
      [store_entry("x", "4")],
    )

    listed = store.list_sessions("proj")
    listed.map(&.session_id).sort!.should eq(["a", "b"])
    store.size.should eq(3) # a, b, c main transcripts
  end

  it "cascades delete of main key to subkeys" do
    store = ClaudeAgent::InMemorySessionStore.new
    main = ClaudeAgent::SessionKey.new("proj", "sess")
    sub = ClaudeAgent::SessionKey.new("proj", "sess", "subagents/agent-1")
    store.append(main, [store_entry("user", "u1")])
    store.append(sub, [store_entry("user", "u2")])

    store.delete(main)
    store.load(main).should be_nil
    store.load(sub).should be_nil
    store.list_subkeys(ClaudeAgent::SessionListSubkeysKey.new("proj", "sess")).should be_empty
  end

  it "targeted subpath delete leaves main transcript" do
    store = ClaudeAgent::InMemorySessionStore.new
    main = ClaudeAgent::SessionKey.new("proj", "sess")
    sub = ClaudeAgent::SessionKey.new("proj", "sess", "subagents/agent-1")
    store.append(main, [store_entry("user", "u1")])
    store.append(sub, [store_entry("user", "u2")])

    store.delete(sub)
    remaining = store.load(main)
    remaining.should_not be_nil
    remaining.try(&.size).should eq(1)
    store.load(sub).should be_nil
  end

  it "folds session summaries on append" do
    store = ClaudeAgent::InMemorySessionStore.new
    sid = UUID.random.to_s
    key = ClaudeAgent::SessionKey.new("proj", sid)
    store.append(key, [
      user_entry("Hello store", "u1", sid),
      store_entry("custom-title", "t1", customTitle: "My Title"),
    ])

    summaries = store.list_session_summaries("proj")
    summaries.size.should eq(1)
    summaries.first.session_id.should eq(sid)
    summaries.first.data["first_prompt"]?.try(&.as_s?).should eq("Hello store")
    summaries.first.data["custom_title"]?.try(&.as_s?).should eq("My Title")
  end
end

describe "SessionStore helpers" do
  it "imports a local session file into the store" do
    with_temp_claude_config do |config_dir|
      project_path = File.tempname("store-import-proj")
      FileUtils.mkdir_p(project_path)
      begin
        sanitized = ClaudeAgent::SessionStorage.sanitize_path(File.realpath(project_path))
        project_dir = File.join(config_dir, "projects", sanitized)
        FileUtils.mkdir_p(project_dir)

        session_id = "550e8400-e29b-41d4-a716-446655440000"
        lines = [
          %({"type":"user","uuid":"u1","sessionId":"#{session_id}","timestamp":"2024-01-01T00:00:00Z","message":{"role":"user","content":"import me"}}),
          %({"type":"assistant","uuid":"a1","parentUuid":"u1","sessionId":"#{session_id}","timestamp":"2024-01-01T00:00:01Z","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}),
        ]
        File.write(File.join(project_dir, "#{session_id}.jsonl"), lines.join("\n") + "\n")

        store = ClaudeAgent::InMemorySessionStore.new
        ClaudeAgent.import_session_to_store(session_id, store, directory: project_path)

        key = ClaudeAgent::SessionKey.new(sanitized, session_id)
        entries = store.get_entries(key)
        entries.size.should eq(2)
        entries.map(&.uuid).should eq(["u1", "a1"])
        entries.first.type.should eq("user")
      ensure
        FileUtils.rm_rf(project_path)
      end
    end
  end

  it "raises on missing session import" do
    store = ClaudeAgent::InMemorySessionStore.new
    expect_raises(File::NotFoundError) do
      ClaudeAgent.import_session_to_store(
        "550e8400-e29b-41d4-a716-446655440099",
        store,
        directory: Dir.current,
      )
    end
  end

  it "reads messages and mutates via store helpers" do
    store = ClaudeAgent::InMemorySessionStore.new
    dir = "/workspace/project"
    project_key = ClaudeAgent.project_key_for_directory(dir)
    sid = UUID.random.to_s
    key = ClaudeAgent::SessionKey.new(project_key, sid)

    u1 = UUID.random.to_s
    a1 = UUID.random.to_s
    store.append(key, [
      user_entry("prompt zero", u1, sid),
      assistant_entry("reply zero", a1, sid, u1),
    ])

    messages = ClaudeAgent.get_session_messages_from_store(store, sid, directory: dir)
    messages.size.should eq(2)
    messages.first.type.should eq("user")

    info = ClaudeAgent.get_session_info_from_store(store, sid, directory: dir)
    info.should_not be_nil
    info.try(&.first_prompt).should eq("prompt zero")

    ClaudeAgent.rename_session_via_store(store, sid, "Renamed", directory: dir)
    ClaudeAgent.tag_session_via_store(store, sid, "demo", directory: dir)

    listed = ClaudeAgent.list_sessions_from_store(store, directory: dir)
    listed.map(&.session_id).should contain(sid)

    forked = ClaudeAgent.fork_session_via_store(store, sid, directory: dir, title: "Fork title")
    forked.session_id.should_not eq(sid)
    forked_msgs = ClaudeAgent.get_session_messages_from_store(store, forked.session_id, directory: dir)
    forked_msgs.size.should eq(2)

    ClaudeAgent.delete_session_via_store(store, sid, directory: dir)
    store.load(key).should be_nil
  end

  it "lists subagents from store subkeys" do
    store = ClaudeAgent::InMemorySessionStore.new
    dir = "/workspace/project"
    project_key = ClaudeAgent.project_key_for_directory(dir)
    sid = UUID.random.to_s
    store.append(
      ClaudeAgent::SessionKey.new(project_key, sid),
      [user_entry("hi", UUID.random.to_s, sid)],
    )
    store.append(
      ClaudeAgent::SessionKey.new(project_key, sid, "subagents/agent-abc"),
      [user_entry("sub", UUID.random.to_s, sid)],
    )

    ClaudeAgent.list_subagents_from_store(store, sid, directory: dir).should eq(["abc"])
  end
end

describe ClaudeAgent::SessionStoreFlushMode do
  it "parses batched and eager" do
    ClaudeAgent::SessionStoreFlushMode.parse("batched").should eq(ClaudeAgent::SessionStoreFlushMode::Batched)
    ClaudeAgent::SessionStoreFlushMode.parse("eager").should eq(ClaudeAgent::SessionStoreFlushMode::Eager)
    ClaudeAgent::SessionStoreFlushMode::Batched.to_s.should eq("batched")
  end
end

describe "fold_session_summary" do
  it "latches first_prompt and last-wins title fields" do
    key = ClaudeAgent::SessionKey.new("p", "s")
    entries = [
      user_entry("First prompt here", "u1", "s"),
      store_entry("custom-title", "t1", customTitle: "Title A"),
      store_entry("custom-title", "t2", customTitle: "Title B"),
    ]
    summary = ClaudeAgent.fold_session_summary(nil, key, entries)
    summary.data["first_prompt"]?.try(&.as_s?).should eq("First prompt here")
    summary.data["custom_title"]?.try(&.as_s?).should eq("Title B")
  end
end
