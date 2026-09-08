require "file_utils"
require "json"
require "uuid"
require "./spec_helper"

describe ClaudeAgent do
  describe ".strip_settings_for_resume (Python 0.2.137 parity)" do
    it "strips plugin declarations and env CLAUDE_CONFIG_DIR, keeps the rest" do
      content = {
        "apiKeyHelper"           => JSON::Any.new("/bin/helper"),
        "enabledPlugins"         => JSON::Any.new([JSON::Any.new("marketplace@plugin")]),
        "extraKnownMarketplaces" => JSON::Any.new([JSON::Any.new("evil")]),
        "env"                    => JSON::Any.new({
          "CLAUDE_CONFIG_DIR" => JSON::Any.new("/tmp/elsewhere"),
          "OTHER"             => JSON::Any.new("keep"),
        } of String => JSON::Any),
      }.to_json

      stripped = JSON.parse(ClaudeAgent.strip_settings_for_resume(content))
      stripped["apiKeyHelper"]?.try(&.as_s?).should eq("/bin/helper")
      stripped.as_h.has_key?("enabledPlugins").should be_false
      stripped.as_h.has_key?("extraKnownMarketplaces").should be_false
      env = stripped["env"]?.try(&.as_h?)
      env.should_not be_nil
      env.try(&.has_key?("CLAUDE_CONFIG_DIR").should be_false)
      env.try(&.["OTHER"]?.try(&.as_s?).should eq("keep"))
    end

    it "returns content untouched when there is nothing to strip" do
      content = %({"apiKeyHelper": "/bin/helper", "env": {"OTHER": "1"}})
      ClaudeAgent.strip_settings_for_resume(content).should eq(content)
    end

    it "returns unparseable and non-object content untouched" do
      ClaudeAgent.strip_settings_for_resume("not json {{{").should eq("not json {{{")
      ClaudeAgent.strip_settings_for_resume("[1, 2]").should eq("[1, 2]")
    end

    it "tolerates a UTF-8 BOM like the CLI settings reader" do
      content = "\u{FEFF}{\"enabledPlugins\": [\"x\"], \"kept\": true}"
      stripped = JSON.parse(ClaudeAgent.strip_settings_for_resume(content))
      stripped.as_h.has_key?("enabledPlugins").should be_false
      stripped["kept"]?.try(&.as_bool?).should be_true
    end
  end

  describe ".agent_metadata_sidecar_path (Python 0.2.140 parity)" do
    it "maps agent transcripts to their sidecar" do
      ClaudeAgent.agent_metadata_sidecar_path("/p/subagents/agent-w1.jsonl").should eq(
        "/p/subagents/agent-w1.meta.json"
      )
    end

    it "appends for non-jsonl paths" do
      ClaudeAgent.agent_metadata_sidecar_path("/p/agent-w1").should eq("/p/agent-w1.meta.json")
    end
  end

  describe ".materialize_resume_session subagent partition (Python 0.2.140 parity)" do
    it "writes transcript lines to jsonl and metadata to the sidecar" do
      empty_config = File.join("/tmp", "claude-agent-cr-empty-#{Random.rand(1_000_000)}")
      FileUtils.mkdir_p(empty_config)

      begin
        store = ClaudeAgent::InMemorySessionStore.new
        project_key = ClaudeAgent::SessionStorage.project_key_for_directory(nil)
        session_id = UUID.random.to_s
        user_id = UUID.random.to_s

        main_key = ClaudeAgent::SessionKey.new(project_key, session_id)
        store.append(main_key, [
          ClaudeAgent::SessionStoreEntry.from_hash({
            "type" => JSON::Any.new("user"),
            "uuid" => JSON::Any.new(user_id),
          } of String => JSON::Any),
        ])

        sub_key = ClaudeAgent::SessionKey.new(project_key, session_id, "subagents/agent-w1")
        store.append(sub_key, [
          ClaudeAgent::SessionStoreEntry.from_hash({
            "type"      => JSON::Any.new("user"),
            "uuid"      => JSON::Any.new(user_id),
            "sessionId" => JSON::Any.new(session_id),
            "message"   => JSON::Any.new({"role" => JSON::Any.new("user")}),
          } of String => JSON::Any),
          ClaudeAgent::SessionStoreEntry.from_hash({
            "type"          => JSON::Any.new("agent_metadata"),
            "toolUseId"     => JSON::Any.new("tool-1"),
            "parentAgentId" => JSON::Any.new("agent-top"),
          } of String => JSON::Any),
        ])

        options = ClaudeAgent::AgentOptions.new(
          session_store: store,
          resume: session_id,
          env: {"CLAUDE_CONFIG_DIR" => empty_config},
        )
        materialized = ClaudeAgent.materialize_resume_session(options)
        materialized.should_not be_nil
        next unless materialized

        begin
          sub_file = File.join(
            materialized.config_dir, "projects", project_key, session_id,
            "subagents", "agent-w1.jsonl"
          )
          File.exists?(sub_file).should be_true
          File.read(sub_file).each_line do |line|
            next if line.strip.empty?
            JSON.parse(line)["type"]?.try(&.as_s?).should_not eq("agent_metadata")
          end

          sidecar = File.join(
            materialized.config_dir, "projects", project_key, session_id,
            "subagents", "agent-w1.meta.json"
          )
          File.exists?(sidecar).should be_true
          meta = JSON.parse(File.read(sidecar)).as_h
          meta["toolUseId"]?.try(&.as_s?).should eq("tool-1")
          meta["parentAgentId"]?.try(&.as_s?).should eq("agent-top")
          meta.has_key?("type").should be_false
        ensure
          materialized.cleanup
        end
      ensure
        FileUtils.rm_rf(empty_config)
      end
    end
  end
end
