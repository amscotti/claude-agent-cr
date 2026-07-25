require "./spec_helper"
require "file_utils"
require "uuid"

private class MinimalSessionStore < ClaudeAgent::SessionStore
  def append(key : ClaudeAgent::SessionKey, entries : Array(ClaudeAgent::SessionStoreEntry)) : Nil
  end

  def load(key : ClaudeAgent::SessionKey) : Array(ClaudeAgent::SessionStoreEntry)?
    nil
  end
end

private def mirror_entry(uuid : String, text : String = "hi")
  ClaudeAgent::SessionStoreEntry.from_hash({
    "type"      => JSON::Any.new("user"),
    "uuid"      => JSON::Any.new(uuid),
    "sessionId" => JSON::Any.new("sess"),
    "message"   => JSON::Any.new({
      "role"    => JSON::Any.new("user"),
      "content" => JSON::Any.new(text),
    }),
  })
end

describe ClaudeAgent::TranscriptMirrorBatcher do
  projects_dir = File.join(Dir.tempdir, "claude-mirror-spec-#{UUID.random}")
  project_key = "proj_key"
  session_id = UUID.random.to_s
  session_file = File.join(projects_dir, project_key, "#{session_id}.jsonl")

  before_each do
    FileUtils.rm_rf(projects_dir) if Dir.exists?(projects_dir)
    Dir.mkdir_p(File.dirname(session_file))
  end

  after_each do
    FileUtils.rm_rf(projects_dir) if Dir.exists?(projects_dir)
  end

  it "appends enqueued frames on flush" do
    store = ClaudeAgent::InMemorySessionStore.new
    errors = [] of String
    batcher = ClaudeAgent::TranscriptMirrorBatcher.new(
      store: store,
      projects_dir: projects_dir,
      on_error: ->(_key : ClaudeAgent::SessionKey?, msg : String) { errors << msg },
    )

    batcher.enqueue(session_file, [mirror_entry("u1"), mirror_entry("u2")])
    batcher.flush

    key = ClaudeAgent::SessionKey.new(project_key, session_id)
    loaded = store.load(key)
    loaded.should_not be_nil
    loaded.try(&.map(&.uuid)).should eq(["u1", "u2"])
    errors.should be_empty
  end

  it "coalesces multiple frames for the same file path" do
    store = ClaudeAgent::InMemorySessionStore.new
    batcher = ClaudeAgent::TranscriptMirrorBatcher.new(
      store: store,
      projects_dir: projects_dir,
      on_error: ->(_key : ClaudeAgent::SessionKey?, _msg : String) { },
    )

    batcher.enqueue(session_file, [mirror_entry("a")])
    batcher.enqueue(session_file, [mirror_entry("b")])
    batcher.flush

    key = ClaudeAgent::SessionKey.new(project_key, session_id)
    store.load(key).try(&.map(&.uuid)).should eq(["a", "b"])
  end

  it "reports errors for paths outside projects_dir" do
    store = ClaudeAgent::InMemorySessionStore.new
    errors = [] of String
    batcher = ClaudeAgent::TranscriptMirrorBatcher.new(
      store: store,
      projects_dir: projects_dir,
      on_error: ->(_key : ClaudeAgent::SessionKey?, msg : String) { errors << msg },
    )

    batcher.enqueue("/tmp/not-under-projects/x.jsonl", [mirror_entry("z")])
    batcher.flush

    errors.size.should eq(1)
    errors.first.should contain("not under projects_dir")
  end

  it "eager mode flushes on every enqueue when thresholds are zero" do
    store = ClaudeAgent::InMemorySessionStore.new
    batcher = ClaudeAgent::TranscriptMirrorBatcher.new(
      store: store,
      projects_dir: projects_dir,
      on_error: ->(_key : ClaudeAgent::SessionKey?, _msg : String) { },
      max_pending_entries: 0,
      max_pending_bytes: 0,
    )

    batcher.enqueue(session_file, [mirror_entry("eager-1")])
    # Background fiber may need a tick
    sleep 50.milliseconds
    batcher.flush # ensure drain completed

    key = ClaudeAgent::SessionKey.new(project_key, session_id)
    store.load(key).try(&.map(&.uuid)).should eq(["eager-1"])
  end
end

describe "ClaudeAgent.validate_session_store_options!" do
  it "rejects session_store with enable_file_checkpointing" do
    opts = ClaudeAgent::AgentOptions.new(
      session_store: ClaudeAgent::InMemorySessionStore.new,
      enable_file_checkpointing: true,
    )
    expect_raises(ClaudeAgent::ConfigurationError, /checkpointing/) do
      ClaudeAgent.validate_session_store_options!(opts)
    end
  end

  it "rejects continue_conversation without list_sessions on store" do
    opts = ClaudeAgent::AgentOptions.new(
      session_store: MinimalSessionStore.new,
      continue_conversation: true,
    )
    expect_raises(ClaudeAgent::ConfigurationError, /list_sessions/) do
      ClaudeAgent.validate_session_store_options!(opts)
    end
  end

  it "accepts InMemorySessionStore with continue_conversation" do
    opts = ClaudeAgent::AgentOptions.new(
      session_store: ClaudeAgent::InMemorySessionStore.new,
      continue_conversation: true,
    )
    ClaudeAgent.validate_session_store_options!(opts)
  end
end

describe "ClaudeAgent.materialize_resume_session" do
  it "writes store entries into a temp CLAUDE_CONFIG_DIR layout" do
    store = ClaudeAgent::InMemorySessionStore.new
    directory = Dir.current
    project_key = ClaudeAgent.project_key_for_directory(directory)
    session_id = UUID.random.to_s
    key = ClaudeAgent::SessionKey.new(project_key, session_id)
    store.append(key, [
      ClaudeAgent::SessionStoreEntry.from_hash({
        "type"      => JSON::Any.new("user"),
        "uuid"      => JSON::Any.new(UUID.random.to_s),
        "sessionId" => JSON::Any.new(session_id),
        "message"   => JSON::Any.new({
          "role"    => JSON::Any.new("user"),
          "content" => JSON::Any.new("resume me"),
        }),
      }),
    ])

    opts = ClaudeAgent::AgentOptions.new(
      session_store: store,
      resume: session_id,
      cwd: directory,
    )
    materialized = ClaudeAgent.materialize_resume_session(opts)
    materialized.should_not be_nil

    if mat = materialized
      mat.resume_session_id.should eq(session_id)
      jsonl = File.join(mat.config_dir, "projects", project_key, "#{session_id}.jsonl")
      File.exists?(jsonl).should be_true
      File.read(jsonl).should contain("resume me")

      opts = ClaudeAgent.apply_materialized_options(opts, mat)
      opts.env.try(&.["CLAUDE_CONFIG_DIR"]).should eq(mat.config_dir)
      opts.resume.should eq(session_id)
      opts.continue_conversation?.should be_false

      mat.cleanup
      Dir.exists?(mat.config_dir).should be_false
    end
  end

  it "returns nil when store has no matching session" do
    opts = ClaudeAgent::AgentOptions.new(
      session_store: ClaudeAgent::InMemorySessionStore.new,
      resume: UUID.random.to_s,
      cwd: Dir.current,
    )
    ClaudeAgent.materialize_resume_session(opts).should be_nil
  end
end

describe "materialize_resume subkeys and auth" do
  it "writes subagent transcripts under the session directory" do
    store = ClaudeAgent::InMemorySessionStore.new
    directory = Dir.current
    project_key = ClaudeAgent.project_key_for_directory(directory)
    session_id = UUID.random.to_s
    main = ClaudeAgent::SessionKey.new(project_key, session_id)
    sub = ClaudeAgent::SessionKey.new(project_key, session_id, "subagents/worker")
    store.append(main, [
      ClaudeAgent::SessionStoreEntry.from_hash({
        "type"    => JSON::Any.new("user"),
        "uuid"    => JSON::Any.new(UUID.random.to_s),
        "message" => JSON::Any.new({"role" => JSON::Any.new("user"), "content" => JSON::Any.new("main")}),
      }),
    ])
    store.append(sub, [
      ClaudeAgent::SessionStoreEntry.from_hash({
        "type"    => JSON::Any.new("assistant"),
        "uuid"    => JSON::Any.new(UUID.random.to_s),
        "message" => JSON::Any.new({"role" => JSON::Any.new("assistant"), "content" => JSON::Any.new("sub")}),
      }),
    ])

    opts = ClaudeAgent::AgentOptions.new(session_store: store, resume: session_id, cwd: directory)
    mat = ClaudeAgent.materialize_resume_session(opts)
    mat.should_not be_nil
    if m = mat
      sub_path = File.join(m.config_dir, "projects", project_key, session_id, "subagents", "worker.jsonl")
      File.exists?(sub_path).should be_true
      File.read(sub_path).should contain("sub")
      m.cleanup
    end
  end
end
