require "file_utils"
require "json"
require "uuid"
require "./spec_helper"

private def with_temp_claude_config(&)
  original = ENV["CLAUDE_CONFIG_DIR"]?
  root = "/tmp/claude-agent-cr-sessions-#{Process.pid}-#{Random.rand(1_000_000)}"
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

private def json_any(value) : JSON::Any
  case value
  when Hash
    result = {} of String => JSON::Any
    value.each do |key, nested|
      result[key.to_s] = json_any(nested)
    end
    JSON::Any.new(result)
  when Array
    JSON::Any.new(value.map { |nested| json_any(nested) })
  when String
    JSON::Any.new(value)
  when Int32, Int64
    JSON::Any.new(value.to_i64)
  when Bool
    JSON::Any.new(value)
  when Nil
    JSON::Any.new(nil)
  else
    JSON::Any.new(value.to_s)
  end
end

private def json_line(value : Hash) : String
  result = {} of String => JSON::Any
  value.each do |key, nested|
    result[key.to_s] = json_any(nested)
  end
  result.to_json
end

private def make_project_dir(config_dir : String, project_path : String) : String
  canonical = File.realpath(project_path)
  sanitized = ClaudeAgent::SessionStorage.sanitize_path(canonical)
  project_dir = File.join(config_dir, "projects", sanitized)
  FileUtils.mkdir_p(project_dir)
  project_dir
end

private def make_session_file(
  project_dir : String,
  session_id : String = UUID.random.to_s,
  first_prompt : String = "Hello Claude",
  summary : String? = nil,
  custom_title : String? = nil,
  git_branch : String? = nil,
  cwd : String? = nil,
  tag : String? = nil,
  timestamp : String? = nil,
  is_sidechain : Bool = false,
  is_meta_only : Bool = false,
) : String
  first_entry = {} of String => JSON::Any
  first_entry["type"] = JSON::Any.new("user")
  first_entry["message"] = json_any({"role" => "user", "content" => first_prompt})
  first_entry["cwd"] = JSON::Any.new(cwd) if cwd
  first_entry["gitBranch"] = JSON::Any.new(git_branch) if git_branch
  first_entry["timestamp"] = JSON::Any.new(timestamp) if timestamp
  first_entry["isSidechain"] = JSON::Any.new(true) if is_sidechain
  first_entry["isMeta"] = JSON::Any.new(true) if is_meta_only

  lines = [] of String
  lines << first_entry.to_json

  assistant_entry = {} of String => JSON::Any
  assistant_entry["type"] = JSON::Any.new("assistant")
  assistant_entry["message"] = json_any({"role" => "assistant", "content" => "Hi there!"})
  lines << assistant_entry.to_json

  tail_entry = {} of String => JSON::Any
  tail_entry["type"] = JSON::Any.new("summary")
  tail_entry["summary"] = JSON::Any.new(summary) if summary
  tail_entry["customTitle"] = JSON::Any.new(custom_title) if custom_title
  tail_entry["gitBranch"] = JSON::Any.new(git_branch) if git_branch
  tail_entry["tag"] = JSON::Any.new(tag) if tag
  lines << tail_entry.to_json

  file_path = File.join(project_dir, "#{session_id}.jsonl")
  File.write(file_path, lines.join('\n') + "\n")
  file_path
end

private def make_transcript_entry(
  entry_type : String,
  entry_uuid : String,
  parent_uuid : String?,
  session_id : String,
  content = nil,
  **extras,
) : String
  entry = {} of String => JSON::Any
  entry["type"] = JSON::Any.new(entry_type)
  entry["uuid"] = JSON::Any.new(entry_uuid)
  entry["parentUuid"] = parent_uuid ? JSON::Any.new(parent_uuid) : JSON::Any.new(nil)
  entry["sessionId"] = JSON::Any.new(session_id)

  if content
    role = {"user", "assistant"}.includes?(entry_type) ? entry_type : "user"
    entry["message"] = json_any({"role" => role, "content" => content})
  end

  extras.each do |key, value|
    entry[key.to_s] = json_any(value)
  end

  entry.to_json
end

private def write_transcript(project_dir : String, session_id : String, entries : Array(String)) : String
  file_path = File.join(project_dir, "#{session_id}.jsonl")
  File.write(file_path, entries.join('\n') + "\n")
  file_path
end

describe "ClaudeAgent session utilities" do
  it "lists sessions for a project" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-project-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)
      session_id = UUID.random.to_s

      make_session_file(
        project_dir,
        session_id: session_id,
        first_prompt: "What is 2+2?",
        git_branch: "main",
        cwd: File.realpath(project_path),
      )

      sessions = ClaudeAgent.list_sessions(directory: project_path, include_worktrees: false)
      sessions.size.should eq(1)
      sessions.first.session_id.should eq(session_id)
      sessions.first.summary.should eq("What is 2+2?")
      sessions.first.first_prompt.should eq("What is 2+2?")
      sessions.first.git_branch.should eq("main")
      sessions.first.cwd.should eq(File.realpath(project_path))

      FileUtils.rm_rf(project_path)
    end
  end

  it "prefers custom title over summary and first prompt" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-project-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)

      make_session_file(
        project_dir,
        first_prompt: "original question",
        summary: "auto summary",
        custom_title: "My Custom Title",
      )

      sessions = ClaudeAgent.list_sessions(directory: project_path, include_worktrees: false)
      sessions.size.should eq(1)
      sessions.first.summary.should eq("My Custom Title")
      sessions.first.custom_title.should eq("My Custom Title")
      sessions.first.first_prompt.should eq("original question")

      FileUtils.rm_rf(project_path)
    end
  end

  it "filters sidechain and invalid session files" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-project-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)

      make_session_file(project_dir, first_prompt: "normal")
      make_session_file(project_dir, first_prompt: "sidechain", is_sidechain: true)
      File.write(File.join(project_dir, "not-a-uuid.jsonl"), json_line({"type" => "user"}) + "\n")

      sessions = ClaudeAgent.list_sessions(directory: project_path, include_worktrees: false)
      sessions.size.should eq(1)
      sessions.first.first_prompt.should eq("normal")

      FileUtils.rm_rf(project_path)
    end
  end

  it "lists sessions across all projects and keeps the newest duplicate" do
    with_temp_claude_config do |config_dir|
      project_one = "/tmp/claude-agent-cr-project-one-#{Random.rand(1_000_000)}"
      project_two = "/tmp/claude-agent-cr-project-two-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_one)
      FileUtils.mkdir_p(project_two)

      dir_one = make_project_dir(config_dir, project_one)
      dir_two = make_project_dir(config_dir, project_two)
      shared_id = UUID.random.to_s

      make_session_file(dir_one, session_id: shared_id, first_prompt: "older")
      sleep 10.milliseconds
      make_session_file(dir_two, session_id: shared_id, first_prompt: "newer")

      sessions = ClaudeAgent.list_sessions
      sessions.size.should eq(1)
      sessions.first.first_prompt.should eq("newer")

      FileUtils.rm_rf(project_one)
      FileUtils.rm_rf(project_two)
    end
  end

  it "supports offset pagination for list_sessions" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-project-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)

      make_session_file(project_dir, first_prompt: "first")
      sleep 10.milliseconds
      make_session_file(project_dir, first_prompt: "second")
      sleep 10.milliseconds
      make_session_file(project_dir, first_prompt: "third")

      sessions = ClaudeAgent.list_sessions(directory: project_path, limit: 1, offset: 1, include_worktrees: false)
      sessions.size.should eq(1)
      sessions.first.first_prompt.should eq("second")

      ClaudeAgent.list_sessions(directory: project_path, offset: 100, include_worktrees: false).should eq([] of ClaudeAgent::SDKSessionInfo)

      FileUtils.rm_rf(project_path)
    end
  end

  it "includes tag and created_at metadata when present" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-project-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)

      make_session_file(
        project_dir,
        first_prompt: "tagged session",
        tag: "experiment",
        timestamp: "2026-01-15T10:30:00.000Z",
      )

      sessions = ClaudeAgent.list_sessions(directory: project_path, include_worktrees: false)
      sessions.size.should eq(1)
      sessions.first.tag.should eq("experiment")
      sessions.first.created_at.should eq(1_768_473_000_000)

      FileUtils.rm_rf(project_path)
    end
  end

  it "treats empty tag as cleared" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-project-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)
      session_id = UUID.random.to_s
      file_path = make_session_file(project_dir, session_id: session_id, first_prompt: "hello")

      File.open(file_path, "a") do |file|
        file << %({"type":"tag","tag":"old","sessionId":"#{session_id}"}\n)
        file << %({"type":"tag","tag":"","sessionId":"#{session_id}"}\n)
      end

      sessions = ClaudeAgent.list_sessions(directory: project_path, include_worktrees: false)
      sessions.first.tag.should be_nil

      FileUtils.rm_rf(project_path)
    end
  end

  it "returns session info for a single session" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-project-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)
      session_id = UUID.random.to_s

      make_session_file(
        project_dir,
        session_id: session_id,
        first_prompt: "single session",
        custom_title: "Single Title",
        tag: "focus",
        timestamp: "2026-01-15T10:30:00+00:00",
      )

      info = ClaudeAgent.get_session_info(session_id, directory: project_path)
      info.should_not be_nil
      info.try(&.summary).should eq("Single Title")
      info.try(&.tag).should eq("focus")
      info.try(&.created_at).should eq(1_768_473_000_000)

      FileUtils.rm_rf(project_path)
    end
  end

  it "returns nil session info for invalid or missing sessions" do
    with_temp_claude_config do
      ClaudeAgent.get_session_info("not-a-uuid").should be_nil
      ClaudeAgent.get_session_info(UUID.random.to_s).should be_nil
    end
  end

  it "renames a session by appending a custom title entry" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-project-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)
      session_id = UUID.random.to_s
      file_path = make_session_file(project_dir, session_id: session_id, first_prompt: "rename me")

      ClaudeAgent.rename_session(session_id, "  My New Title  ", directory: project_path)

      lines = File.read(file_path).strip.split("\n")
      lines.last.should eq(%({"type":"custom-title","customTitle":"My New Title","sessionId":"#{session_id}"}))

      sessions = ClaudeAgent.list_sessions(directory: project_path, include_worktrees: false)
      sessions.first.custom_title.should eq("My New Title")
      sessions.first.summary.should eq("My New Title")

      FileUtils.rm_rf(project_path)
    end
  end

  it "validates rename_session inputs" do
    with_temp_claude_config do
      expect_raises(ArgumentError, /Invalid session_id/) do
        ClaudeAgent.rename_session("not-a-uuid", "title")
      end

      expect_raises(ArgumentError, /title must be non-empty/) do
        ClaudeAgent.rename_session(UUID.random.to_s, "   ")
      end
    end
  end

  it "tags a session and sanitizes unicode" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-project-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)
      session_id = UUID.random.to_s
      file_path = make_session_file(project_dir, session_id: session_id, first_prompt: "tag me")

      ClaudeAgent.tag_session(session_id, " clean\u200btag\ufeff ", directory: project_path)

      lines = File.read(file_path).strip.split("\n")
      lines.last.should eq(%({"type":"tag","tag":"cleantag","sessionId":"#{session_id}"}))

      sessions = ClaudeAgent.list_sessions(directory: project_path, include_worktrees: false)
      sessions.first.tag.should eq("cleantag")

      FileUtils.rm_rf(project_path)
    end
  end

  it "clears a session tag when nil is provided" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-project-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)
      session_id = UUID.random.to_s
      file_path = make_session_file(project_dir, session_id: session_id, first_prompt: "tag me")

      ClaudeAgent.tag_session(session_id, "first-tag", directory: project_path)
      ClaudeAgent.tag_session(session_id, nil, directory: project_path)

      lines = File.read(file_path).strip.split("\n")
      lines.last.should eq(%({"type":"tag","tag":"","sessionId":"#{session_id}"}))

      sessions = ClaudeAgent.list_sessions(directory: project_path, include_worktrees: false)
      sessions.first.tag.should be_nil

      FileUtils.rm_rf(project_path)
    end
  end

  it "validates tag_session inputs" do
    with_temp_claude_config do
      expect_raises(ArgumentError, /Invalid session_id/) do
        ClaudeAgent.tag_session("not-a-uuid", "tag")
      end

      expect_raises(ArgumentError, /tag must be non-empty/) do
        ClaudeAgent.tag_session(UUID.random.to_s, "\u200b\ufeff")
      end
    end
  end

  it "returns empty session lists for missing directories" do
    with_temp_claude_config do
      project_path = "/tmp/claude-agent-cr-missing-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)

      ClaudeAgent.list_sessions(directory: project_path, include_worktrees: false).should eq([] of ClaudeAgent::SDKSessionInfo)

      FileUtils.rm_rf(project_path)
    end
  end

  it "returns empty for invalid session ids" do
    with_temp_claude_config do
      ClaudeAgent.get_session_messages("not-a-uuid").should eq([] of ClaudeAgent::SessionMessage)
    end
  end

  it "reconstructs a simple transcript chain in chronological order" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-project-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)
      session_id = UUID.random.to_s
      u1 = UUID.random.to_s
      a1 = UUID.random.to_s
      u2 = UUID.random.to_s
      a2 = UUID.random.to_s

      write_transcript(project_dir, session_id, [
        make_transcript_entry("user", u1, nil, session_id, content: "hello"),
        make_transcript_entry("assistant", a1, u1, session_id, content: "hi!"),
        make_transcript_entry("user", u2, a1, session_id, content: "thanks"),
        make_transcript_entry("assistant", a2, u2, session_id, content: "welcome"),
      ])

      messages = ClaudeAgent.get_session_messages(session_id, directory: project_path)
      messages.map(&.uuid).should eq([u1, a1, u2, a2])
      messages.first.message["content"].as_s.should eq("hello")
      messages.last.message["content"].as_s.should eq("welcome")

      FileUtils.rm_rf(project_path)
    end
  end

  it "filters meta and progress entries from visible messages" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-project-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)
      session_id = UUID.random.to_s
      u1 = UUID.random.to_s
      meta = UUID.random.to_s
      progress = UUID.random.to_s
      a1 = UUID.random.to_s

      write_transcript(project_dir, session_id, [
        make_transcript_entry("user", u1, nil, session_id, content: "hello"),
        make_transcript_entry("user", meta, u1, session_id, content: "meta", isMeta: true),
        make_transcript_entry("progress", progress, meta, session_id),
        make_transcript_entry("assistant", a1, progress, session_id, content: "hi"),
      ])

      messages = ClaudeAgent.get_session_messages(session_id, directory: project_path)
      messages.map(&.uuid).should eq([u1, a1])

      FileUtils.rm_rf(project_path)
    end
  end

  it "keeps compact summary messages in the returned chain" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-project-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)
      session_id = UUID.random.to_s
      u1 = UUID.random.to_s
      a1 = UUID.random.to_s

      write_transcript(project_dir, session_id, [
        make_transcript_entry("user", u1, nil, session_id, content: "compact summary", isCompactSummary: true),
        make_transcript_entry("assistant", a1, u1, session_id, content: "hi"),
      ])

      messages = ClaudeAgent.get_session_messages(session_id, directory: project_path)
      messages.map(&.uuid).should eq([u1, a1])

      FileUtils.rm_rf(project_path)
    end
  end

  it "supports offset and limit pagination" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-project-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)
      session_id = UUID.random.to_s
      ids = Array.new(6) { UUID.random.to_s }

      entries = ids.map_with_index do |id, index|
        parent = index.zero? ? nil : ids[index - 1]
        type = index.even? ? "user" : "assistant"
        make_transcript_entry(type, id, parent, session_id, content: "m#{index}")
      end

      write_transcript(project_dir, session_id, entries)

      ClaudeAgent.get_session_messages(session_id, directory: project_path, limit: 2).map(&.uuid).should eq(ids[0, 2])
      ClaudeAgent.get_session_messages(session_id, directory: project_path, limit: 2, offset: 2).map(&.uuid).should eq(ids[2, 2])
      ClaudeAgent.get_session_messages(session_id, directory: project_path, offset: 4).map(&.uuid).should eq(ids[4, 2])
      ClaudeAgent.get_session_messages(session_id, directory: project_path, offset: 100).should eq([] of ClaudeAgent::SessionMessage)

      FileUtils.rm_rf(project_path)
    end
  end

  it "prefers the latest main leaf when multiple leaves exist" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-project-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)
      session_id = UUID.random.to_s
      root = UUID.random.to_s
      old_leaf = UUID.random.to_s
      new_leaf = UUID.random.to_s

      write_transcript(project_dir, session_id, [
        make_transcript_entry("user", root, nil, session_id, content: "root"),
        make_transcript_entry("assistant", old_leaf, root, session_id, content: "old"),
        make_transcript_entry("assistant", new_leaf, root, session_id, content: "new"),
      ])

      messages = ClaudeAgent.get_session_messages(session_id, directory: project_path)
      messages.map(&.uuid).should eq([root, new_leaf])

      FileUtils.rm_rf(project_path)
    end
  end

  it "returns an empty message list for cyclic transcript graphs" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-project-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)
      session_id = UUID.random.to_s
      u1 = UUID.random.to_s
      a1 = UUID.random.to_s

      write_transcript(project_dir, session_id, [
        make_transcript_entry("user", u1, a1, session_id, content: "hi"),
        make_transcript_entry("assistant", a1, u1, session_id, content: "hello"),
      ])

      ClaudeAgent.get_session_messages(session_id, directory: project_path).should eq([] of ClaudeAgent::SessionMessage)

      FileUtils.rm_rf(project_path)
    end
  end

  it "skips corrupt transcript lines" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-project-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)
      session_id = UUID.random.to_s
      u1 = UUID.random.to_s
      a1 = UUID.random.to_s

      file_path = File.join(project_dir, "#{session_id}.jsonl")
      File.write(file_path, [
        make_transcript_entry("user", u1, nil, session_id, content: "hi"),
        "not valid json {{{",
        make_transcript_entry("assistant", a1, u1, session_id, content: "hello"),
      ].join("\n") + "\n")

      messages = ClaudeAgent.get_session_messages(session_id, directory: project_path)
      messages.map(&.uuid).should eq([u1, a1])

      FileUtils.rm_rf(project_path)
    end
  end

  it "returns top-level session messages with nil parent tool use id" do
    message = ClaudeAgent::SessionMessage.new(
      type: "user",
      uuid: "abc",
      session_id: "sess",
      message: {"role" => JSON::Any.new("user"), "content" => JSON::Any.new("hi")},
    )

    message.parent_tool_use_id.should be_nil
  end

  it "parses parent_tool_use_id from transcript entries" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-project-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)
      session_id = UUID.random.to_s
      user_id = UUID.random.to_s
      assistant_id = UUID.random.to_s

      write_transcript(project_dir, session_id, [
        make_transcript_entry("user", user_id, nil, session_id, content: "hello"),
        make_transcript_entry("assistant", assistant_id, user_id, session_id, content: "hi", parentToolUseId: "tool-123"),
      ])

      messages = ClaudeAgent.get_session_messages(session_id, directory: project_path)
      messages.last.parent_tool_use_id.should eq("tool-123")

      FileUtils.rm_rf(project_path)
    end
  end

  it "deletes a session and its subagent transcript directory" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-project-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)
      session_id = UUID.random.to_s

      make_session_file(project_dir, session_id: session_id)
      subagent_dir = File.join(project_dir, session_id, "subagents")
      FileUtils.mkdir_p(subagent_dir)
      File.write(File.join(subagent_dir, "agent-abc.jsonl"), "{}\n")

      ClaudeAgent.delete_session(session_id, directory: project_path)

      File.exists?(File.join(project_dir, "#{session_id}.jsonl")).should be_false
      Dir.exists?(File.join(project_dir, session_id)).should be_false

      FileUtils.rm_rf(project_path)
    end
  end

  it "lists subagents from the session's subagents directory" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-project-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)
      session_id = UUID.random.to_s

      make_session_file(project_dir, session_id: session_id)
      subagent_dir = File.join(project_dir, session_id, "subagents")
      FileUtils.mkdir_p(File.join(subagent_dir, "workflows"))
      File.write(File.join(subagent_dir, "agent-top.jsonl"), "{}\n")
      File.write(File.join(subagent_dir, "workflows", "agent-nested.jsonl"), "{}\n")

      ids = ClaudeAgent.list_subagents(session_id, directory: project_path)
      ids.sort.should eq(["nested", "top"])

      FileUtils.rm_rf(project_path)
    end
  end

  it "reads subagent conversation messages" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-project-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)
      session_id = UUID.random.to_s
      agent_id = "abc"
      user_id = UUID.random.to_s
      assistant_id = UUID.random.to_s

      make_session_file(project_dir, session_id: session_id)
      subagent_dir = File.join(project_dir, session_id, "subagents")
      FileUtils.mkdir_p(subagent_dir)
      File.write(
        File.join(subagent_dir, "agent-#{agent_id}.jsonl"),
        [
          make_transcript_entry("user", user_id, nil, session_id, content: "plan"),
          make_transcript_entry("assistant", assistant_id, user_id, session_id, content: "ack"),
        ].join('\n') + "\n"
      )

      messages = ClaudeAgent.get_subagent_messages(session_id, agent_id, directory: project_path)
      messages.size.should eq(2)
      messages.first.type.should eq("user")
      messages.last.type.should eq("assistant")

      FileUtils.rm_rf(project_path)
    end
  end

  it "forks a session into a new JSONL file with remapped UUIDs" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-project-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)
      session_id = UUID.random.to_s
      user_id = UUID.random.to_s
      assistant_id = UUID.random.to_s

      write_transcript(project_dir, session_id, [
        make_transcript_entry("user", user_id, nil, session_id, content: "hi"),
        make_transcript_entry("assistant", assistant_id, user_id, session_id, content: "hello"),
      ])

      result = ClaudeAgent.fork_session(session_id, directory: project_path)
      result.session_id.should_not eq(session_id)

      fork_path = File.join(project_dir, "#{result.session_id}.jsonl")
      File.exists?(fork_path).should be_true

      entries = File.read(fork_path).each_line.compact_map do |line|
        JSON.parse(line.strip).as_h?
      end.to_a

      # Expect at least 2 user/assistant entries + custom-title footer.
      entries.size.should be >= 3
      entries.first["sessionId"].as_s.should eq(result.session_id)
      entries.first["uuid"].as_s.should_not eq(user_id)

      FileUtils.rm_rf(project_path)
    end
  end
end
