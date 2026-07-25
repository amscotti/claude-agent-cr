require "./spec_helper"
require "file_utils"
require "uuid"

describe ClaudeAgent::SessionStoreConformance do
  it "passes against InMemorySessionStore" do
    store = ClaudeAgent::InMemorySessionStore.new
    count = ClaudeAgent::SessionStoreConformance.run(store)
    count.should be >= 10
  end

  it "passes against FileSessionStore" do
    root = File.join(Dir.tempdir, "file-store-conf-#{UUID.random}")
    begin
      store = ClaudeAgent::FileSessionStore.new(root)
      count = ClaudeAgent::SessionStoreConformance.run(store)
      count.should be >= 10
    ensure
      FileUtils.rm_rf(root) if Dir.exists?(root)
    end
  end
end

describe ClaudeAgent::FileSessionStore do
  it "persists across instances" do
    root = File.join(Dir.tempdir, "file-store-#{UUID.random}")
    begin
      key = ClaudeAgent::SessionKey.new("proj", UUID.random.to_s)
      entry = ClaudeAgent::SessionStoreEntry.from_hash({
        "type"    => JSON::Any.new("user"),
        "uuid"    => JSON::Any.new(UUID.random.to_s),
        "message" => JSON::Any.new({
          "role"    => JSON::Any.new("user"),
          "content" => JSON::Any.new("durable"),
        }),
      })

      ClaudeAgent::FileSessionStore.new(root).append(key, [entry])
      loaded = ClaudeAgent::FileSessionStore.new(root).load(key)
      loaded.should_not be_nil
      loaded.try(&.first.string_field("uuid")).should eq(entry.uuid)
    ensure
      FileUtils.rm_rf(root) if Dir.exists?(root)
    end
  end

  it "lists and deletes sessions" do
    root = File.join(Dir.tempdir, "file-store-list-#{UUID.random}")
    begin
      store = ClaudeAgent::FileSessionStore.new(root)
      sid = UUID.random.to_s
      key = ClaudeAgent::SessionKey.new("p1", sid)
      store.append(key, [
        ClaudeAgent::SessionStoreEntry.from_hash({"type" => JSON::Any.new("user")}),
      ])
      store.append(ClaudeAgent::SessionKey.new("p1", sid, "subagents/a"), [
        ClaudeAgent::SessionStoreEntry.from_hash({"type" => JSON::Any.new("assistant")}),
      ])

      store.list_sessions("p1").map(&.session_id).should contain(sid)
      store.list_subkeys(ClaudeAgent::SessionListSubkeysKey.new("p1", sid)).should contain("subagents/a")

      store.delete(key)
      store.load(key).should be_nil
      store.load(ClaudeAgent::SessionKey.new("p1", sid, "subagents/a")).should be_nil
    ensure
      FileUtils.rm_rf(root) if Dir.exists?(root)
    end
  end
end
