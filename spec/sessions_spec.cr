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

  it "returns top-level session messages with nil parent tool use id and parent agent id" do
    message = ClaudeAgent::SessionMessage.new(
      type: "user",
      uuid: "abc",
      session_id: "sess",
      message: {"role" => JSON::Any.new("user"), "content" => JSON::Any.new("hi")},
    )

    message.parent_tool_use_id.should be_nil
    message.parent_agent_id.should be_nil
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
      messages.last.parent_agent_id.should be_nil

      FileUtils.rm_rf(project_path)
    end
  end

  it "parses parent_agent_id from subagent transcript entries (camel and snake)" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-project-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)
      session_id = UUID.random.to_s
      parent_agent = "top-level-agent"
      nested_agent = "nested-worker"

      make_session_file(project_dir, session_id: session_id)
      subagent_dir = File.join(project_dir, session_id, "subagents")
      FileUtils.mkdir_p(subagent_dir)

      user_id = UUID.random.to_s
      assistant_id = UUID.random.to_s
      File.write(
        File.join(subagent_dir, "agent-#{nested_agent}.jsonl"),
        [
          make_transcript_entry(
            "user",
            user_id,
            nil,
            session_id,
            content: "nested task",
            parentAgentId: parent_agent,
          ),
          make_transcript_entry(
            "assistant",
            assistant_id,
            user_id,
            session_id,
            content: "done",
            parent_agent_id: parent_agent,
          ),
        ].join('\n') + "\n"
      )

      messages = ClaudeAgent.get_subagent_messages(session_id, nested_agent, directory: project_path)
      messages.size.should eq(2)
      messages.first.parent_agent_id.should eq(parent_agent)
      messages.last.parent_agent_id.should eq(parent_agent)

      # Depth-2 tree reconstruction: nested agent → parent agent id.
      tree = ClaudeAgent.list_subagents(session_id, directory: project_path).map do |agent_id|
        msgs = ClaudeAgent.get_subagent_messages(session_id, agent_id, directory: project_path)
        {agent_id, msgs.first?.try(&.parent_agent_id)}
      end
      tree.should contain({nested_agent, parent_agent})

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

  it "recovers parent ids from the .meta.json sidecar (Python 0.2.140 parity)" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-project-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)
      session_id = UUID.random.to_s
      agent_id = "worker"
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
      File.write(
        File.join(subagent_dir, "agent-#{agent_id}.meta.json"),
        {"toolUseId" => "tool-parent", "parentAgentId" => "agent-top"}.to_json
      )

      messages = ClaudeAgent.get_subagent_messages(session_id, agent_id, directory: project_path)
      messages.size.should eq(2)
      messages.each do |message|
        message.parent_tool_use_id.should eq("tool-parent")
        message.parent_agent_id.should eq("agent-top")
      end

      FileUtils.rm_rf(project_path)
    end
  end

  it "leaves parent ids nil for missing or corrupt sidecars" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-project-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)
      session_id = UUID.random.to_s
      user_id = UUID.random.to_s

      make_session_file(project_dir, session_id: session_id)
      subagent_dir = File.join(project_dir, session_id, "subagents")
      FileUtils.mkdir_p(subagent_dir)

      File.write(
        File.join(subagent_dir, "agent-missing.jsonl"),
        [make_transcript_entry("user", user_id, nil, session_id, content: "plan")].join('\n') + "\n"
      )
      messages = ClaudeAgent.get_subagent_messages(session_id, "missing", directory: project_path)
      messages.size.should eq(1)
      messages.first.parent_tool_use_id.should be_nil
      messages.first.parent_agent_id.should be_nil

      File.write(
        File.join(subagent_dir, "agent-broken.jsonl"),
        [make_transcript_entry("user", user_id, nil, session_id, content: "plan")].join('\n') + "\n"
      )
      File.write(File.join(subagent_dir, "agent-broken.meta.json"), "not json {{{")
      broken = ClaudeAgent.get_subagent_messages(session_id, "broken", directory: project_path)
      broken.size.should eq(1)
      broken.first.parent_tool_use_id.should be_nil

      File.write(
        File.join(subagent_dir, "agent-array.jsonl"),
        [make_transcript_entry("user", user_id, nil, session_id, content: "plan")].join('\n') + "\n"
      )
      File.write(File.join(subagent_dir, "agent-array.meta.json"), "[1, 2]")
      arrayed = ClaudeAgent.get_subagent_messages(session_id, "array", directory: project_path)
      arrayed.size.should eq(1)
      arrayed.first.parent_tool_use_id.should be_nil

      FileUtils.rm_rf(project_path)
    end
  end

  it "prefers transcript entry ids over the sidecar" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-project-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)
      session_id = UUID.random.to_s
      agent_id = "explicit"
      user_id = UUID.random.to_s

      make_session_file(project_dir, session_id: session_id)
      subagent_dir = File.join(project_dir, session_id, "subagents")
      FileUtils.mkdir_p(subagent_dir)
      File.write(
        File.join(subagent_dir, "agent-#{agent_id}.jsonl"),
        [
          make_transcript_entry(
            "user", user_id, nil, session_id,
            content: "plan", parentToolUseId: "tool-entry", parentAgentId: "agent-entry"
          ),
        ].join('\n') + "\n"
      )
      File.write(
        File.join(subagent_dir, "agent-#{agent_id}.meta.json"),
        {"toolUseId" => "tool-sidecar", "parentAgentId" => "agent-sidecar"}.to_json
      )

      messages = ClaudeAgent.get_subagent_messages(session_id, agent_id, directory: project_path)
      messages.size.should eq(1)
      messages.first.parent_tool_use_id.should eq("tool-entry")
      messages.first.parent_agent_id.should eq("agent-entry")

      FileUtils.rm_rf(project_path)
    end
  end

  it "recovers parent ids from store agent_metadata entries, last wins" do
    store = ClaudeAgent::InMemorySessionStore.new
    project_key = ClaudeAgent::SessionStorage.project_key_for_directory(nil)
    session_id = UUID.random.to_s
    user_id = UUID.random.to_s
    assistant_id = UUID.random.to_s

    entries = [
      ClaudeAgent::SessionStoreEntry.from_hash({
        "type"          => JSON::Any.new("agent_metadata"),
        "toolUseId"     => JSON::Any.new("tool-old"),
        "parentAgentId" => JSON::Any.new("agent-old"),
      } of String => JSON::Any),
      ClaudeAgent::SessionStoreEntry.from_hash({
        "type"      => JSON::Any.new("user"),
        "uuid"      => JSON::Any.new(user_id),
        "sessionId" => JSON::Any.new(session_id),
        "message"   => json_any({"role" => "user", "content" => "plan"}),
      } of String => JSON::Any),
      ClaudeAgent::SessionStoreEntry.from_hash({
        "type"          => JSON::Any.new("agent_metadata"),
        "toolUseId"     => JSON::Any.new("tool-new"),
        "parentAgentId" => JSON::Any.new("agent-new"),
      } of String => JSON::Any),
      ClaudeAgent::SessionStoreEntry.from_hash({
        "type"       => JSON::Any.new("assistant"),
        "uuid"       => JSON::Any.new(assistant_id),
        "parentUuid" => JSON::Any.new(user_id),
        "sessionId"  => JSON::Any.new(session_id),
        "message"    => json_any({"role" => "assistant", "content" => "ack"}),
      } of String => JSON::Any),
    ]
    store.append(ClaudeAgent::SessionKey.new(project_key, session_id, "subagents/agent-w1"), entries)

    messages = ClaudeAgent::SessionStorage.get_subagent_messages_from_store(
      store, session_id, "w1", directory: nil
    )
    messages.should_not be_empty
    messages.each do |message|
      message.parent_tool_use_id.should eq("tool-new")
      message.parent_agent_id.should eq("agent-new")
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

  # ---------------------------------------------------------------------------
  # Session edge cases — equivalent to Python's `test_sessions.py` helpers
  # that exercise UUID validation, path sanitization, filter semantics, and
  # invalid-input handling. These run on synthetic JSONL and touch no CLI.
  # ---------------------------------------------------------------------------

  it "rejects invalid UUIDs in delete_session / fork_session / get_session_messages" do
    with_temp_claude_config do
      # Synchronous validators raise ArgumentError on malformed UUIDs.
      expect_raises(ArgumentError, /Invalid session_id/) do
        ClaudeAgent.delete_session("not-a-uuid")
      end

      expect_raises(ArgumentError, /Invalid session_id/) do
        ClaudeAgent.fork_session("also-not-a-uuid")
      end

      # Read-side helpers silently return empty collections for invalid input.
      ClaudeAgent.get_session_messages("bad-uuid").should be_empty
      ClaudeAgent.list_subagents("bad-uuid").should be_empty
      ClaudeAgent.get_subagent_messages("bad-uuid", "agent-1").should be_empty
    end
  end

  it "fork_session rejects empty up_to_message_id and missing non-UUID up_to_message_id" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-fork-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)
      session_id = UUID.random.to_s
      user_id = UUID.random.to_s

      write_transcript(project_dir, session_id, [
        make_transcript_entry("user", user_id, nil, session_id, content: "hi"),
      ])

      expect_raises(ArgumentError, /Invalid up_to_message_id/) do
        ClaudeAgent.fork_session(
          session_id,
          directory: project_path,
          up_to_message_id: "   ",
        )
      end

      expect_raises(ArgumentError, /not found in session/) do
        ClaudeAgent.fork_session(
          session_id,
          directory: project_path,
          up_to_message_id: "missing-delivery-id",
        )
      end

      FileUtils.rm_rf(project_path)
    end
  end

  it "delete_session raises when the session file is missing" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-del-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      make_project_dir(config_dir, project_path)

      expect_raises(File::NotFoundError) do
        ClaudeAgent.delete_session(UUID.random.to_s, directory: project_path)
      end

      FileUtils.rm_rf(project_path)
    end
  end

  it "sanitize_path produces a hash-suffixed form for long paths" do
    long_path = "/" + ("a" * 220)
    sanitized = ClaudeAgent::SessionStorage.sanitize_path(long_path)

    # Claude Code caps project-dir names at ~200 chars and appends a short
    # hash to keep the mapping collision-resistant. The resulting name
    # must never collide between distinct long paths.
    sanitized.size.should be < long_path.size
    sanitized.should_not contain("/")
    # The hash suffix is appended via a trailing `-hexdigits` sequence.
    sanitized.matches?(/-[a-z0-9]+\z/).should be_true

    other = ClaudeAgent::SessionStorage.sanitize_path("/" + ("b" * 220))
    sanitized.should_not eq(other)
  end

  it "sanitize_path is stable across calls for the same input" do
    path = "/home/user/projects/my-project"
    a = ClaudeAgent::SessionStorage.sanitize_path(path)
    b = ClaudeAgent::SessionStorage.sanitize_path(path)
    a.should eq(b)
  end

  it "list_sessions filters out zero-byte files" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-empty-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)

      # A zero-byte JSONL with a UUID filename must not appear in listings —
      # that's how Claude Code marks abandoned / never-started sessions.
      empty_session_id = UUID.random.to_s
      File.write(File.join(project_dir, "#{empty_session_id}.jsonl"), "")

      real_session_id = UUID.random.to_s
      make_session_file(project_dir, session_id: real_session_id)

      ids = ClaudeAgent.list_sessions(directory: project_path).map(&.session_id)
      ids.should contain(real_session_id)
      ids.should_not contain(empty_session_id)

      FileUtils.rm_rf(project_path)
    end
  end

  it "list_sessions ignores non-UUID .jsonl filenames" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-nouuid-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)

      File.write(File.join(project_dir, "not-a-uuid.jsonl"), "content")
      File.write(File.join(project_dir, "README.md"), "not a session")
      real_session_id = UUID.random.to_s
      make_session_file(project_dir, session_id: real_session_id)

      ids = ClaudeAgent.list_sessions(directory: project_path).map(&.session_id)
      ids.should eq([real_session_id])

      FileUtils.rm_rf(project_path)
    end
  end

  it "rename_session / tag_session reject invalid session IDs" do
    with_temp_claude_config do
      expect_raises(ArgumentError, /Invalid session_id/) do
        ClaudeAgent.rename_session("not-a-uuid", "my title")
      end
      expect_raises(ArgumentError, /Invalid session_id/) do
        ClaudeAgent.tag_session("not-a-uuid", "my-tag")
      end
    end
  end

  it "get_session_messages respects offset and limit" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-pag-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)
      session_id = UUID.random.to_s

      # Build a linear 5-turn transcript so the returned list has
      # predictable ordering.
      entries = [] of String
      previous_uuid : String? = nil
      5.times do |i|
        type = i.even? ? "user" : "assistant"
        uuid = UUID.random.to_s
        entries << make_transcript_entry(type, uuid, previous_uuid, session_id, content: "msg-#{i}")
        previous_uuid = uuid
      end
      write_transcript(project_dir, session_id, entries)

      full = ClaudeAgent.get_session_messages(session_id, directory: project_path)
      full.size.should eq(5)

      offset = ClaudeAgent.get_session_messages(session_id, directory: project_path, offset: 2)
      offset.size.should eq(3)

      limited = ClaudeAgent.get_session_messages(
        session_id,
        directory: project_path,
        limit: 2,
      )
      limited.size.should eq(2)

      page = ClaudeAgent.get_session_messages(
        session_id,
        directory: project_path,
        offset: 1,
        limit: 2,
      )
      page.size.should eq(2)

      # An offset past the end returns an empty list rather than raising.
      ClaudeAgent.get_session_messages(
        session_id,
        directory: project_path,
        offset: 100,
      ).should be_empty

      FileUtils.rm_rf(project_path)
    end
  end

  it "fork_session with up_to_message_id slices at the cutoff message" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-slice-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)
      session_id = UUID.random.to_s

      uuids = Array.new(5) { UUID.random.to_s }
      entries = uuids.each_with_index.map do |uuid, i|
        parent = i == 0 ? nil : uuids[i - 1]
        type = i.even? ? "user" : "assistant"
        make_transcript_entry(type, uuid, parent, session_id, content: "m-#{i}")
      end.to_a
      write_transcript(project_dir, session_id, entries)

      # Fork only the first 3 messages (0..2).
      cutoff = uuids[2]
      result = ClaudeAgent.fork_session(
        session_id,
        directory: project_path,
        up_to_message_id: cutoff,
      )

      messages = ClaudeAgent.get_session_messages(
        result.session_id,
        directory: project_path,
      )

      # 3 sliced messages; `custom-title` + `fork_header` are non-visible.
      messages.size.should eq(3)

      FileUtils.rm_rf(project_path)
    end
  end

  it "fork_session accepts an explicit title that overrides derived title" do
    with_temp_claude_config do |config_dir|
      project_path = "/tmp/claude-agent-cr-ftitle-#{Random.rand(1_000_000)}"
      FileUtils.mkdir_p(project_path)
      project_dir = make_project_dir(config_dir, project_path)
      session_id = UUID.random.to_s
      user_id = UUID.random.to_s

      write_transcript(project_dir, session_id, [
        make_transcript_entry("user", user_id, nil, session_id, content: "hi"),
      ])

      result = ClaudeAgent.fork_session(
        session_id,
        directory: project_path,
        title: "my fork title",
      )

      info = ClaudeAgent.get_session_info(result.session_id, directory: project_path)
      info.should_not be_nil
      info.try(&.custom_title).should eq("my fork title")

      FileUtils.rm_rf(project_path)
    end
  end

  describe "via_store / import helpers" do
    it "imports a disk session and reads messages from the store" do
      with_temp_claude_config do |config_dir|
        project_path = "/tmp/claude-agent-cr-import-#{Random.rand(1_000_000)}"
        FileUtils.mkdir_p(project_path)
        project_dir = make_project_dir(config_dir, project_path)
        session_id = UUID.random.to_s
        user_id = UUID.random.to_s
        assistant_id = UUID.random.to_s

        write_transcript(project_dir, session_id, [
          make_transcript_entry("user", user_id, nil, session_id, content: "store import"),
          make_transcript_entry("assistant", assistant_id, user_id, session_id, content: "ack"),
        ])

        store = ClaudeAgent::InMemorySessionStore.new
        ClaudeAgent.import_session_to_store(session_id, store, directory: project_path)

        messages = ClaudeAgent.get_session_messages_from_store(
          store, session_id, directory: project_path
        )
        messages.size.should eq(2)
        messages.first.message["content"]?.try(&.as_s?).should eq("store import")

        ClaudeAgent.delete_session_via_store(store, session_id, directory: project_path)
        project_key = ClaudeAgent.project_key_for_directory(project_path)
        store.load(ClaudeAgent::SessionKey.new(project_key, session_id)).should be_nil

        FileUtils.rm_rf(project_path)
      end
    end

    it "rename/tag_session_via_store append metadata entries" do
      store = ClaudeAgent::InMemorySessionStore.new
      dir = "/tmp/via-store-meta"
      project_key = ClaudeAgent.project_key_for_directory(dir)
      session_id = UUID.random.to_s
      key = ClaudeAgent::SessionKey.new(project_key, session_id)
      user_id = UUID.random.to_s

      store.append(key, [
        ClaudeAgent::SessionStoreEntry.from_hash({
          "type"      => JSON::Any.new("user"),
          "uuid"      => JSON::Any.new(user_id),
          "sessionId" => JSON::Any.new(session_id),
          "timestamp" => JSON::Any.new("2024-01-01T00:00:00Z"),
          "message"   => JSON::Any.new({
            "role"    => JSON::Any.new("user"),
            "content" => JSON::Any.new("hello"),
          }),
        }),
      ])

      ClaudeAgent.rename_session_via_store(store, session_id, "Via Store Title", directory: dir)
      ClaudeAgent.tag_session_via_store(store, session_id, "via-tag", directory: dir)

      types = store.get_entries(key).map(&.type)
      types.should contain("custom-title")
      types.should contain("tag")

      info = ClaudeAgent.get_session_info_from_store(store, session_id, directory: dir)
      info.should_not be_nil
      info.try(&.custom_title).should eq("Via Store Title")
      info.try(&.tag).should eq("via-tag")
      info.try(&.archived).should be_nil
    end
  end

  describe "archive_session / unarchive_session & SDKSessionInfo#archived" do
    it "writes archived.json sidecar with permissions and updates session info" do
      with_temp_claude_config do |config_dir|
        project_path = "/tmp/claude-agent-cr-arch-#{Random.rand(1_000_000)}"
        FileUtils.mkdir_p(project_path)
        project_dir = make_project_dir(config_dir, project_path)
        session_id = UUID.random.to_s

        make_session_file(project_dir, session_id: session_id, first_prompt: "archive me")

        # Without sidecar, archived is nil
        ClaudeAgent.get_session_info(session_id, directory: project_path).try(&.archived).should be_nil

        ClaudeAgent.archive_session(session_id, directory: project_path)

        sidecar_dir = File.join(project_dir, session_id)
        sidecar_path = File.join(sidecar_dir, "archived.json")
        File.exists?(sidecar_path).should be_true
        File.info(sidecar_dir).permissions.value.should eq(0o700)
        File.info(sidecar_path).permissions.value.should eq(0o600)

        sidecar = JSON.parse(File.read(sidecar_path)).as_h
        sidecar["archived"].as_bool.should be_true
        sidecar["by"].as_s.should eq("sdk")
        sidecar["at"].as_s.should_not be_empty

        ClaudeAgent.get_session_info(session_id, directory: project_path).try(&.archived).should be_true
        ClaudeAgent.list_sessions(directory: project_path, include_worktrees: false).first.archived.should be_true

        ClaudeAgent.unarchive_session(session_id, directory: project_path)
        ClaudeAgent.get_session_info(session_id, directory: project_path).try(&.archived).should be_false

        FileUtils.rm_rf(project_path)
      end
    end

    it "validates session_id and raises File::NotFoundError when missing" do
      with_temp_claude_config do
        expect_raises(ArgumentError, /Invalid session_id/) do
          ClaudeAgent.archive_session("bad-id")
        end
        expect_raises(ArgumentError, /Invalid session_id/) do
          ClaudeAgent.unarchive_session("bad-id")
        end
        expect_raises(File::NotFoundError) do
          ClaudeAgent.archive_session(UUID.random.to_s)
        end
        expect_raises(File::NotFoundError) do
          ClaudeAgent.unarchive_session(UUID.random.to_s)
        end
      end
    end

    it "auto-unarchives when a newer non-tool_result user or queued_command prompt arrives" do
      with_temp_claude_config do |config_dir|
        project_path = "/tmp/claude-agent-cr-autounarch-#{Random.rand(1_000_000)}"
        FileUtils.mkdir_p(project_path)
        project_dir = make_project_dir(config_dir, project_path)
        session_id = UUID.random.to_s
        file_path = make_session_file(
          project_dir,
          session_id: session_id,
          first_prompt: "initial",
          timestamp: "2026-01-01T00:00:00.000Z",
        )

        ClaudeAgent.archive_session(session_id, directory: project_path)
        sidecar_path = File.join(project_dir, session_id, "archived.json")
        File.write(
          sidecar_path,
          %({"archived":true,"at":"2026-01-01T10:00:00.000Z","by":"sdk"}),
        )

        # Newer tool_result does not unarchive
        File.open(file_path, "a") do |file|
          file << make_transcript_entry(
            "user",
            UUID.random.to_s,
            nil,
            session_id,
            content: [{"type" => "tool_result", "tool_use_id" => "t1", "content" => "ok"}],
            timestamp: "2026-01-01T11:00:00.000Z",
          ) << "\n"
          # Newer non-human origin does not unarchive
          file << make_transcript_entry(
            "user",
            UUID.random.to_s,
            nil,
            session_id,
            content: "bg done",
            timestamp: "2026-01-01T11:05:00.000Z",
            origin: {"kind" => "task-notification"},
          ) << "\n"
        end
        ClaudeAgent.get_session_info(session_id, directory: project_path).try(&.archived).should be_true

        # Newer non-tool_result user prompt auto-unarchives
        File.open(file_path, "a") do |file|
          file << make_transcript_entry(
            "user",
            UUID.random.to_s,
            nil,
            session_id,
            content: "follow up prompt",
            timestamp: "2026-01-01T12:00:00.000Z",
          ) << "\n"
        end
        ClaudeAgent.get_session_info(session_id, directory: project_path).try(&.archived).should be_false

        # Also test queued_command auto-unarchive
        session_two = UUID.random.to_s
        file_two = make_session_file(
          project_dir,
          session_id: session_two,
          first_prompt: "initial two",
          timestamp: "2026-01-01T00:00:00.000Z",
        )
        ClaudeAgent.archive_session(session_two, directory: project_path)
        File.write(
          File.join(project_dir, session_two, "archived.json"),
          %({"archived":true,"at":"2026-01-01T10:00:00.000Z","by":"sdk"}),
        )
        File.open(file_two, "a") do |file|
          file << {
            "type"       => JSON::Any.new("attachment"),
            "uuid"       => JSON::Any.new(UUID.random.to_s),
            "sessionId"  => JSON::Any.new(session_two),
            "timestamp"  => JSON::Any.new("2026-01-01T10:30:00.000Z"),
            "attachment" => json_any({"type" => "queued_command", "prompt" => "queued follow-up"}),
          }.to_json << "\n"
        end
        ClaudeAgent.get_session_info(session_two, directory: project_path).try(&.archived).should be_false

        # Oversized archived.json (> 4096 bytes) is ignored
        File.write(File.join(project_dir, session_two, "archived.json"), " " * 5000)
        ClaudeAgent.get_session_info(session_two, directory: project_path).try(&.archived).should be_nil

        FileUtils.rm_rf(project_path)
      end
    end
  end

  describe "delete_session retry and error propagation" do
    it "retries subagent directory removal on failure and succeeds when unlocked" do
      with_temp_claude_config do |config_dir|
        project_path = "/tmp/claude-agent-cr-delretry-#{Random.rand(1_000_000)}"
        FileUtils.mkdir_p(project_path)
        project_dir = make_project_dir(config_dir, project_path)
        session_id = UUID.random.to_s

        make_session_file(project_dir, session_id: session_id)
        session_dir = File.join(project_dir, session_id)
        subagent_dir = File.join(session_dir, "subagents")
        FileUtils.mkdir_p(subagent_dir)
        File.write(File.join(subagent_dir, "agent-abc.jsonl"), "{}\n")

        File.chmod(subagent_dir, 0o500)
        File.chmod(session_dir, 0o500)

        spawn do
          sleep 20.milliseconds
          File.chmod(session_dir, 0o700) if Dir.exists?(session_dir)
          File.chmod(subagent_dir, 0o700) if Dir.exists?(subagent_dir)
        end

        begin
          ClaudeAgent.delete_session(session_id, directory: project_path)
          Dir.exists?(session_dir).should be_false
        ensure
          File.chmod(session_dir, 0o700) if Dir.exists?(session_dir)
          File.chmod(subagent_dir, 0o700) if Dir.exists?(subagent_dir)
          FileUtils.rm_rf(project_path)
        end
      end
    end

    it "propagates File::Error when subagent directory removal fails after 3 attempts" do
      with_temp_claude_config do |config_dir|
        project_path = "/tmp/claude-agent-cr-delfail-#{Random.rand(1_000_000)}"
        FileUtils.mkdir_p(project_path)
        project_dir = make_project_dir(config_dir, project_path)
        session_id = UUID.random.to_s

        make_session_file(project_dir, session_id: session_id)
        session_dir = File.join(project_dir, session_id)
        subagent_dir = File.join(session_dir, "subagents")
        FileUtils.mkdir_p(subagent_dir)
        File.write(File.join(subagent_dir, "agent-abc.jsonl"), "{}\n")

        File.chmod(subagent_dir, 0o500)
        File.chmod(session_dir, 0o500)

        begin
          expect_raises(File::Error) do
            ClaudeAgent.delete_session(session_id, directory: project_path)
          end
        ensure
          File.chmod(session_dir, 0o700) if Dir.exists?(session_dir)
          File.chmod(subagent_dir, 0o700) if Dir.exists?(subagent_dir)
          FileUtils.rm_rf(project_path)
        end
      end
    end
  end

  describe "parallel tool call/result recovery (Py #1422)" do
    it "recovers off-chain parallel tool_use siblings and tool_results on disk and in store" do
      with_temp_claude_config do |config_dir|
        project_path = "/tmp/claude-agent-cr-parallel-#{Random.rand(1_000_000)}"
        FileUtils.mkdir_p(project_path)
        project_dir = make_project_dir(config_dir, project_path)
        session_id = UUID.random.to_s

        u1 = UUID.random.to_s
        a1 = UUID.random.to_s
        a2 = UUID.random.to_s
        tr1 = UUID.random.to_s
        tr2 = UUID.random.to_s
        tr_stray = UUID.random.to_s
        a3 = UUID.random.to_s
        u2 = UUID.random.to_s

        entries = [
          make_transcript_entry("user", u1, nil, session_id, content: "run 3 tools", timestamp: "2026-01-01T00:00:00Z"),
          {
            "type"       => JSON::Any.new("assistant"),
            "uuid"       => JSON::Any.new(a1),
            "parentUuid" => JSON::Any.new(u1),
            "sessionId"  => JSON::Any.new(session_id),
            "timestamp"  => JSON::Any.new("2026-01-01T00:00:01Z"),
            "message"    => json_any({
              "id"      => "msg_parallel_1",
              "role"    => "assistant",
              "content" => [{"type" => "tool_use", "id" => "call_1", "name" => "Read", "input" => {} of String => String}],
            }),
          }.to_json,
          {
            "type"       => JSON::Any.new("assistant"),
            "uuid"       => JSON::Any.new(a2),
            "parentUuid" => JSON::Any.new(a1),
            "sessionId"  => JSON::Any.new(session_id),
            "timestamp"  => JSON::Any.new("2026-01-01T00:00:02Z"),
            "message"    => json_any({
              "id"      => "msg_parallel_1",
              "role"    => "assistant",
              "content" => [
                {"type" => "tool_use", "id" => "call_2", "name" => "Grep", "input" => {} of String => String},
                {"type" => "tool_use", "id" => "call_3", "name" => "Glob", "input" => {} of String => String},
              ],
            }),
          }.to_json,
          # tr1 branches from a1 and leads to u2 (so a2 and tr2 are off the parentUuid chain!)
          make_transcript_entry(
            "user",
            tr1,
            a1,
            session_id,
            content: [{"type" => "tool_result", "tool_use_id" => "call_1", "content" => "r1"}],
            timestamp: "2026-01-01T00:00:03Z",
          ),
          make_transcript_entry(
            "user",
            tr2,
            a2,
            session_id,
            content: [{"type" => "tool_result", "tool_use_id" => "call_2", "content" => "r2"}],
            timestamp: "2026-01-01T00:00:04Z",
          ),
          # Stray linked via sourceToolAssistantUUID / call_owner
          make_transcript_entry(
            "user",
            tr_stray,
            u1,
            session_id,
            content: [{"type" => "tool_result", "tool_use_id" => "call_3", "content" => "r3"}],
            timestamp: "2026-01-01T00:00:05Z",
            sourceToolAssistantUUID: a2,
          ),
          make_transcript_entry(
            "user",
            u2,
            tr1,
            session_id,
            content: "next question",
            timestamp: "2026-01-01T00:00:06Z",
          ),
          make_transcript_entry(
            "assistant",
            a3,
            u2,
            session_id,
            content: "final answer",
            timestamp: "2026-01-01T00:00:07Z",
          ),
        ]
        write_transcript(project_dir, session_id, entries)

        expected = [u1, a1, a2, tr2, tr_stray, tr1, u2, a3]
        msgs = ClaudeAgent.get_session_messages(session_id, directory: project_path)
        msgs.map(&.uuid).should eq(expected)

        # Limit / offset apply after recovery
        paged = ClaudeAgent.get_session_messages(session_id, directory: project_path, offset: 2, limit: 3)
        paged.map(&.uuid).should eq([a2, tr2, tr_stray])

        # Store path parity
        store = ClaudeAgent::InMemorySessionStore.new
        ClaudeAgent.import_session_to_store(session_id, store, directory: project_path)
        store_msgs = ClaudeAgent.get_session_messages_from_store(store, session_id, directory: project_path)
        store_msgs.map(&.uuid).should eq(expected)

        FileUtils.rm_rf(project_path)
      end
    end
  end

  describe "queued prompts, active branch selection, and subagent isMeta" do
    it "retains queued prompts and handles isMeta/local-command leaves" do
      with_temp_claude_config do |config_dir|
        project_path = "/tmp/claude-agent-cr-queued-#{Random.rand(1_000_000)}"
        FileUtils.mkdir_p(project_path)
        project_dir = make_project_dir(config_dir, project_path)
        session_id = UUID.random.to_s

        cb = UUID.random.to_s
        summary = UUID.random.to_s
        a1 = UUID.random.to_s
        q1 = UUID.random.to_s
        q_source = UUID.random.to_s
        meta_leaf = UUID.random.to_s

        entries = [
          make_transcript_entry("system", cb, nil, session_id, subtype: "compact_boundary"),
          make_transcript_entry("user", summary, cb, session_id, content: "Summary", isCompactSummary: true),
          make_transcript_entry("assistant", a1, summary, session_id, content: "Working..."),
          make_transcript_entry("user", meta_leaf, a1, session_id, content: "caveat", isMeta: true),
          # Trailing queued_command attachment after meta_leaf
          {
            "type"       => JSON::Any.new("attachment"),
            "uuid"       => JSON::Any.new(q1),
            "parentUuid" => JSON::Any.new(meta_leaf),
            "sessionId"  => JSON::Any.new(session_id),
            "timestamp"  => JSON::Any.new("2026-01-01T00:00:05Z"),
            "attachment" => json_any({
              "type"        => "queued_command",
              "prompt"      => "queued follow-up",
              "source_uuid" => q_source,
            }),
          }.to_json,
        ]
        write_transcript(project_dir, session_id, entries)

        msgs = ClaudeAgent.get_session_messages(session_id, directory: project_path)
        msgs.map(&.uuid).should eq([summary, a1, q_source])
        msgs.last.type.should eq("user")
        msgs.last.message["content"].as_s.should eq("queued follow-up")

        # Also test direct user queued prompt after compaction summary without assistant reply
        session_direct = UUID.random.to_s
        cb2 = UUID.random.to_s
        sum2 = UUID.random.to_s
        queued_user = UUID.random.to_s
        write_transcript(project_dir, session_direct, [
          make_transcript_entry("system", cb2, nil, session_direct, subtype: "compact_boundary"),
          make_transcript_entry("user", sum2, cb2, session_direct, content: "Summary 2", isCompactSummary: true),
          make_transcript_entry("user", queued_user, sum2, session_direct, content: "direct queued prompt"),
        ])
        direct_msgs = ClaudeAgent.get_session_messages(session_direct, directory: project_path)
        direct_msgs.map(&.uuid).should eq([sum2, queued_user])

        # Mid-turn absorbed queued_command via queue-operation + visible peer isMeta message
        session_absorbed = UUID.random.to_s
        u_abs = UUID.random.to_s
        a_abs = UUID.random.to_s
        q_abs = UUID.random.to_s
        q_abs_src = UUID.random.to_s
        u_after = UUID.random.to_s
        peer_meta = UUID.random.to_s
        write_transcript(project_dir, session_absorbed, [
          make_transcript_entry("user", u_abs, nil, session_absorbed, content: "start"),
          make_transcript_entry("assistant", a_abs, u_abs, session_absorbed, content: "running"),
          {
            "type"       => JSON::Any.new("attachment"),
            "uuid"       => JSON::Any.new(q_abs),
            "parentUuid" => JSON::Any.new(a_abs),
            "sessionId"  => JSON::Any.new(session_absorbed),
            "timestamp"  => JSON::Any.new("2026-01-01T00:00:03Z"),
            "attachment" => json_any({
              "type"        => "queued_command",
              "prompt"      => "absorbed mid turn",
              "source_uuid" => q_abs_src,
              "delivery_id" => "dlv-1",
            }),
          }.to_json,
          {
            "type"       => JSON::Any.new("queue-operation"),
            "operation"  => JSON::Any.new("remove"),
            "reason"     => JSON::Any.new("absorbed_mid_turn"),
            "deliveryId" => JSON::Any.new("dlv-1"),
          }.to_json,
          make_transcript_entry("user", u_after, q_abs, session_absorbed, content: "next prompt"),
          make_transcript_entry(
            "user",
            peer_meta,
            u_after,
            session_absorbed,
            content: "peer msg",
            isMeta: true,
            origin: {"kind" => "peer"},
          ),
        ])
        abs_msgs = ClaudeAgent.get_session_messages(session_absorbed, directory: project_path)
        abs_msgs.map(&.uuid).should eq([u_abs, a_abs, q_abs_src, u_after, peer_meta])

        # When newest branch ends at isMeta, still pick the newest active branch instead of rewound older branch
        session_branch = UUID.random.to_s
        root = UUID.random.to_s
        old_reply = UUID.random.to_s
        new_reply = UUID.random.to_s
        new_meta = UUID.random.to_s
        write_transcript(project_dir, session_branch, [
          make_transcript_entry("user", root, nil, session_branch, content: "hi"),
          make_transcript_entry("assistant", old_reply, root, session_branch, content: "old branch"),
          make_transcript_entry("assistant", new_reply, root, session_branch, content: "active branch"),
          make_transcript_entry("user", new_meta, new_reply, session_branch, content: "meta", isMeta: true),
        ])
        branch_msgs = ClaudeAgent.get_session_messages(session_branch, directory: project_path)
        branch_msgs.map(&.uuid).should eq([root, new_reply])

        FileUtils.rm_rf(project_path)
      end
    end

    it "includes isMeta messages in get_subagent_messages and counts them in offset/limit" do
      with_temp_claude_config do |config_dir|
        project_path = "/tmp/claude-agent-cr-submeta-#{Random.rand(1_000_000)}"
        FileUtils.mkdir_p(project_path)
        project_dir = make_project_dir(config_dir, project_path)
        session_id = UUID.random.to_s
        agent_id = "meta-worker"

        make_session_file(project_dir, session_id: session_id)
        subagent_dir = File.join(project_dir, session_id, "subagents")
        FileUtils.mkdir_p(subagent_dir)

        u1 = UUID.random.to_s
        m1 = UUID.random.to_s
        a1 = UUID.random.to_s
        File.write(
          File.join(subagent_dir, "agent-#{agent_id}.jsonl"),
          [
            make_transcript_entry("user", u1, nil, session_id, content: "task"),
            make_transcript_entry("user", m1, u1, session_id, content: "injected meta", isMeta: true),
            make_transcript_entry("assistant", a1, m1, session_id, content: "done"),
          ].join("\n") + "\n",
        )

        all_msgs = ClaudeAgent.get_subagent_messages(session_id, agent_id, directory: project_path)
        all_msgs.map(&.uuid).should eq([u1, m1, a1])

        paged = ClaudeAgent.get_subagent_messages(session_id, agent_id, directory: project_path, offset: 1, limit: 1)
        paged.map(&.uuid).should eq([m1])

        store = ClaudeAgent::InMemorySessionStore.new
        ClaudeAgent.import_session_to_store(session_id, store, directory: project_path)
        store_msgs = ClaudeAgent.get_subagent_messages_from_store(
          store, session_id, agent_id, directory: project_path, offset: 1, limit: 2
        )
        store_msgs.map(&.uuid).should eq([m1, a1])

        FileUtils.rm_rf(project_path)
      end
    end
  end

  describe "fork_session non-UUID and compaction-aware slicing" do
    it "forks using non-UUID delivery_id and uuid values" do
      with_temp_claude_config do |config_dir|
        project_path = "/tmp/claude-agent-cr-forkid-#{Random.rand(1_000_000)}"
        FileUtils.mkdir_p(project_path)
        project_dir = make_project_dir(config_dir, project_path)
        session_id = UUID.random.to_s

        u1 = "custom-client-id-1"
        a1 = UUID.random.to_s
        u2 = UUID.random.to_s
        a2 = UUID.random.to_s

        write_transcript(project_dir, session_id, [
          make_transcript_entry("user", u1, nil, session_id, content: "first", deliveryId: "deliv-1"),
          make_transcript_entry("assistant", a1, u1, session_id, content: "reply 1"),
          make_transcript_entry("user", u2, a1, session_id, content: "second", delivery_id: "deliv-2"),
          make_transcript_entry("assistant", a2, u2, session_id, content: "reply 2"),
        ])

        fork_by_custom = ClaudeAgent.fork_session(session_id, directory: project_path, up_to_message_id: u1)
        msgs_custom = ClaudeAgent.get_session_messages(fork_by_custom.session_id, directory: project_path)
        msgs_custom.size.should eq(1)
        msgs_custom.first.message["content"].as_s.should eq("first")

        fork_by_deliv = ClaudeAgent.fork_session(session_id, directory: project_path, up_to_message_id: "deliv-2")
        msgs_deliv = ClaudeAgent.get_session_messages(fork_by_deliv.session_id, directory: project_path)
        msgs_deliv.size.should eq(3)
        msgs_deliv.last.message["content"].as_s.should eq("second")

        FileUtils.rm_rf(project_path)
      end
    end

    it "slices cleanly at compact_boundary and isCompactSummary without dragging preserved messages" do
      with_temp_claude_config do |config_dir|
        project_path = "/tmp/claude-agent-cr-forkcompact-#{Random.rand(1_000_000)}"
        FileUtils.mkdir_p(project_path)
        project_dir = make_project_dir(config_dir, project_path)
        session_id = UUID.random.to_s

        u1 = UUID.random.to_s
        a1 = UUID.random.to_s
        kept_a = UUID.random.to_s
        cb = UUID.random.to_s
        summary = UUID.random.to_s
        u2 = UUID.random.to_s

        write_transcript(project_dir, session_id, [
          make_transcript_entry("user", u1, nil, session_id, content: "old prompt"),
          make_transcript_entry("assistant", a1, u1, session_id, content: "old reply"),
          make_transcript_entry("assistant", kept_a, a1, session_id, content: "kept reply"),
          {
            "type"              => JSON::Any.new("system"),
            "subtype"           => JSON::Any.new("compact_boundary"),
            "uuid"              => JSON::Any.new(cb),
            "parentUuid"        => JSON::Any.new(nil),
            "logicalParentUuid" => JSON::Any.new(kept_a),
            "sessionId"         => JSON::Any.new(session_id),
            "timestamp"         => JSON::Any.new("2026-01-01T00:00:03Z"),
            "compactMetadata"   => json_any({
              "trigger"           => "auto",
              "preTokens"         => 1000,
              "postTokens"        => 200,
              "preservedMessages" => {
                "anchorUuid" => summary,
                "uuids"      => [kept_a],
                "allUuids"   => [kept_a],
              },
            }),
          }.to_json,
          make_transcript_entry("user", summary, cb, session_id, content: "Compacted", isCompactSummary: true),
          make_transcript_entry("user", u2, summary, session_id, content: "post compact"),
        ])

        # Forking at compact_boundary stops before the boundary
        fork_at_cb = ClaudeAgent.fork_session(session_id, directory: project_path, up_to_message_id: cb)
        cb_msgs = ClaudeAgent.get_session_messages(fork_at_cb.session_id, directory: project_path)
        cb_msgs.map { |msg| msg.message["content"]?.try(&.as_s?) }.should eq(["old prompt", "old reply", "kept reply"])

        # Forking at isCompactSummary keeps summary, drops post-summary u2 and strips preservedMessages
        fork_at_summary = ClaudeAgent.fork_session(session_id, directory: project_path, up_to_message_id: summary)
        sum_msgs = ClaudeAgent.get_session_messages(fork_at_summary.session_id, directory: project_path)
        sum_msgs.map { |msg| msg.message["content"]?.try(&.as_s?) }.should eq(["Compacted"])

        # Verify forked JSONL cleared preservedMessages/preservedSegment/postTokens on the boundary
        forked_path = File.join(project_dir, "#{fork_at_summary.session_id}.jsonl")
        forked_entries = File.read(forked_path).each_line.compact_map do |line|
          stripped = line.strip
          stripped.empty? ? nil : JSON.parse(stripped).as_h?
        end.to_a
        boundary_entry = forked_entries.find { |entry| entry["subtype"]?.try(&.as_s?) == "compact_boundary" }
        boundary_entry.should_not be_nil
        if b_entry = boundary_entry
          cm = b_entry["compactMetadata"].as_h
          cm.has_key?("preservedMessages").should be_false
          cm.has_key?("preservedSegment").should be_false
          cm.has_key?("postTokens").should be_false
        end

        # Full fork remaps preservedMessages UUIDs to the new forked UUIDs
        full_fork = ClaudeAgent.fork_session(session_id, directory: project_path)
        full_msgs = ClaudeAgent.get_session_messages(full_fork.session_id, directory: project_path)
        full_msgs.map { |msg| msg.message["content"]?.try(&.as_s?) }.should eq(["Compacted", "kept reply", "post compact"])

        FileUtils.rm_rf(project_path)
      end
    end

    it "keeps rewind compact_boundary and scopes preservedSegment on fork" do
      with_temp_claude_config do |config_dir|
        project_path = "/tmp/claude-agent-cr-rewindfork-#{Random.rand(1_000_000)}"
        FileUtils.mkdir_p(project_path)
        project_dir = make_project_dir(config_dir, project_path)
        session_id = UUID.random.to_s

        u1 = UUID.random.to_s
        a1 = UUID.random.to_s
        rewind_cb = UUID.random.to_s
        p1 = UUID.random.to_s
        p2 = UUID.random.to_s
        q_mid = UUID.random.to_s
        cb2 = UUID.random.to_s
        s2 = UUID.random.to_s

        write_transcript(project_dir, session_id, [
          make_transcript_entry("user", u1, nil, session_id, content: "start"),
          make_transcript_entry("assistant", a1, u1, session_id, content: "first reply"),
          {
            "type"            => JSON::Any.new("system"),
            "subtype"         => JSON::Any.new("compact_boundary"),
            "uuid"            => JSON::Any.new(rewind_cb),
            "parentUuid"      => JSON::Any.new(nil),
            "sessionId"       => JSON::Any.new(session_id),
            "timestamp"       => JSON::Any.new("2026-01-01T00:00:02Z"),
            "compactMetadata" => json_any({
              "trigger"          => "auto",
              "durationMs"       => 0,
              "preservedSegment" => {
                "headUuid"   => p1,
                "anchorUuid" => rewind_cb,
                "tailUuid"   => p2,
              },
            }),
          }.to_json,
          make_transcript_entry("user", p1, rewind_cb, session_id, content: "kept 1"),
          make_transcript_entry("assistant", p2, p1, session_id, content: "kept 2"),
          {
            "type"              => JSON::Any.new("system"),
            "subtype"           => JSON::Any.new("compact_boundary"),
            "uuid"              => JSON::Any.new(cb2),
            "parentUuid"        => JSON::Any.new(nil),
            "logicalParentUuid" => JSON::Any.new(p2),
            "sessionId"         => JSON::Any.new(session_id),
            "timestamp"         => JSON::Any.new("2026-01-01T00:00:05Z"),
          }.to_json,
          {
            "type"       => JSON::Any.new("attachment"),
            "uuid"       => JSON::Any.new(q_mid),
            "parentUuid" => JSON::Any.new(cb2),
            "sessionId"  => JSON::Any.new(session_id),
            "timestamp"  => JSON::Any.new("2026-01-01T00:00:06Z"),
            "attachment" => json_any({"type" => "queued_command", "prompt" => "between"}),
          }.to_json,
          make_transcript_entry("user", s2, cb2, session_id, content: "Summary 2", isCompactSummary: true),
        ])

        # Forking at a queued_command stored between cb2 and s2 ends before cb2
        fork_mid = ClaudeAgent.fork_session(session_id, directory: project_path, up_to_message_id: q_mid)
        mid_msgs = ClaudeAgent.get_session_messages(fork_mid.session_id, directory: project_path)
        mid_msgs.map { |msg| msg.message["content"]?.try(&.as_s?) }.should eq(["kept 1", "kept 2"])

        # Forking at rewind_cb keeps rewind_cb (it is NOT trimmed by DNe)
        fork_rewind = ClaudeAgent.fork_session(session_id, directory: project_path, up_to_message_id: rewind_cb)
        rewind_lines = File.read(File.join(project_dir, "#{fork_rewind.session_id}.jsonl")).each_line.to_a
        rewind_lines.any?(&.includes?("compact_boundary")).should be_true

        # Forking mid-preservedSegment at p1 scopes tailUuid to p1's remapped UUID
        fork_p1 = ClaudeAgent.fork_session(session_id, directory: project_path, up_to_message_id: p1)
        p1_entries = File.read(File.join(project_dir, "#{fork_p1.session_id}.jsonl")).each_line.compact_map do |line|
          stripped = line.strip
          stripped.empty? ? nil : JSON.parse(stripped).as_h?
        end.to_a
        p1_cb = p1_entries.find { |entry| entry["subtype"]?.try(&.as_s?) == "compact_boundary" }
        p1_user = p1_entries.find { |entry| entry["message"]?.try(&.as_h?.try(&.["content"]?.try(&.as_s?))) == "kept 1" }
        p1_cb.should_not be_nil
        p1_user.should_not be_nil
        if cb_entry = p1_cb
          if u_entry = p1_user
            seg = cb_entry["compactMetadata"]["preservedSegment"].as_h
            seg["headUuid"].as_s.should eq(u_entry["uuid"].as_s)
            seg["tailUuid"].as_s.should eq(u_entry["uuid"].as_s)
          end
        end

        FileUtils.rm_rf(project_path)
      end
    end
  end
end
