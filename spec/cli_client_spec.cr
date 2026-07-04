require "./spec_helper"

# Test helper to access private methods for testing
class TestableCLIClient < ClaudeAgent::CLIClient
  # Expose private methods for testing
  def test_permission_mode_value(mode : ClaudeAgent::PermissionMode) : String
    permission_mode_value(mode)
  end

  def test_build_agents_json(agents : Hash(String, ClaudeAgent::AgentDefinition)) : String
    build_agents_json(agents)
  end

  def test_build_mcp_servers_json(servers : Hash(String, ClaudeAgent::MCPServerConfig)) : String
    build_mcp_servers_json(servers)
  end

  def test_build_settings_json(opts : ClaudeAgent::AgentOptions) : String?
    build_settings_json(opts)
  end

  def test_build_env : Hash(String, String)?
    build_env
  end

  def test_build_cli_args : Array(String)
    build_cli_args
  end

  def test_effort_value(effort : ClaudeAgent::Effort) : String
    effort_value(effort)
  end
end

# Stubs `run_cli_help_probe` with a caller-supplied proc so capability-probe
# specs never spawn a real subprocess.
class ProbeSpyCLIClient < ClaudeAgent::CLIClient
  def initialize(
    options : ClaudeAgent::AgentOptions?,
    @probe : Proc(String, Set(String)?),
  )
    super(options)
  end

  protected def run_cli_help_probe(cli_path : String) : Set(String)?
    @probe.call(cli_path)
  end

  def test_probe_cli_capabilities(cli_path : String) : Set(String)?
    probe_cli_capabilities(cli_path)
  end
end

describe ClaudeAgent::CLIClient do
  describe "#initialize" do
    it "initializes with no options" do
      client = ClaudeAgent::CLIClient.new
      client.session_id.should be_nil
      client.has_sdk_servers?.should be_false
    end

    it "initializes with options" do
      options = ClaudeAgent::AgentOptions.new(model: "claude-sonnet-4-20250514")
      client = ClaudeAgent::CLIClient.new(options)
      client.session_id.should be_nil
    end
  end

  describe "#sdk_server_names and #has_sdk_servers?" do
    it "returns empty when no MCP servers" do
      client = ClaudeAgent::CLIClient.new
      client.sdk_server_names.should be_empty
      client.has_sdk_servers?.should be_false
    end

    it "extracts SDK MCP servers from options" do
      sdk_server = ClaudeAgent::SDKMCPServer.new("test-server")
      servers = {} of String => ClaudeAgent::MCPServerConfig
      servers["test"] = sdk_server
      options = ClaudeAgent::AgentOptions.new(mcp_servers: servers)
      client = ClaudeAgent::CLIClient.new(options)

      client.sdk_server_names.should eq(["test"])
      client.has_sdk_servers?.should be_true
    end

    it "ignores external MCP servers when getting SDK servers" do
      external_server = ClaudeAgent::ExternalMCPServerConfig.stdio("node", ["server.js"])
      sdk_server = ClaudeAgent::SDKMCPServer.new("sdk-server")

      servers = {} of String => ClaudeAgent::MCPServerConfig
      servers["external"] = external_server
      servers["sdk"] = sdk_server

      options = ClaudeAgent::AgentOptions.new(mcp_servers: servers)
      client = ClaudeAgent::CLIClient.new(options)

      client.sdk_server_names.should eq(["sdk"])
      client.has_sdk_servers?.should be_true
    end
  end

  describe "#get_sdk_server" do
    it "returns SDK server by name" do
      sdk_server = ClaudeAgent::SDKMCPServer.new("test-server")
      servers = {} of String => ClaudeAgent::MCPServerConfig
      servers["test"] = sdk_server
      options = ClaudeAgent::AgentOptions.new(mcp_servers: servers)
      client = ClaudeAgent::CLIClient.new(options)

      result = client.get_sdk_server("test")
      result.should_not be_nil
      result.try(&.name).should eq("test-server")
    end

    it "returns nil for unknown server" do
      client = ClaudeAgent::CLIClient.new
      client.get_sdk_server("unknown").should be_nil
    end
  end
end

describe TestableCLIClient do
  describe "#permission_mode_value" do
    it "converts Default to 'default'" do
      client = TestableCLIClient.new
      client.test_permission_mode_value(ClaudeAgent::PermissionMode::Default).should eq("default")
    end

    it "converts AcceptEdits to 'acceptEdits'" do
      client = TestableCLIClient.new
      client.test_permission_mode_value(ClaudeAgent::PermissionMode::AcceptEdits).should eq("acceptEdits")
    end

    it "converts Plan to 'plan'" do
      client = TestableCLIClient.new
      client.test_permission_mode_value(ClaudeAgent::PermissionMode::Plan).should eq("plan")
    end

    it "converts BypassPermissions to 'bypassPermissions'" do
      client = TestableCLIClient.new
      client.test_permission_mode_value(ClaudeAgent::PermissionMode::BypassPermissions).should eq("bypassPermissions")
    end
  end

  describe "#effort_value" do
    it "converts effort levels to CLI strings" do
      client = TestableCLIClient.new
      client.test_effort_value(ClaudeAgent::Effort::Low).should eq("low")
      client.test_effort_value(ClaudeAgent::Effort::Medium).should eq("medium")
      client.test_effort_value(ClaudeAgent::Effort::High).should eq("high")
      client.test_effort_value(ClaudeAgent::Effort::Xhigh).should eq("xhigh")
      client.test_effort_value(ClaudeAgent::Effort::Max).should eq("max")
    end
  end

  describe "#build_cli_args thinking args" do
    it "emits --max-thinking-tokens when only max_thinking_tokens is set" do
      options = ClaudeAgent::AgentOptions.new(max_thinking_tokens: 4096)
      client = TestableCLIClient.new(options)
      args = client.test_build_cli_args
      args.should contain("--max-thinking-tokens")
      args.should contain("4096")
      args.should_not contain("--thinking")
    end

    it "emits --thinking adaptive for adaptive thinking config" do
      options = ClaudeAgent::AgentOptions.new(thinking: ClaudeAgent::ThinkingConfig.adaptive)
      client = TestableCLIClient.new(options)
      args = client.test_build_cli_args
      idx = args.index("--thinking")
      idx.should_not be_nil
      args[idx.as(Int32) + 1].should eq("adaptive") if idx
      args.should_not contain("--max-thinking-tokens")
    end

    it "emits --thinking disabled for disabled thinking config" do
      options = ClaudeAgent::AgentOptions.new(thinking: ClaudeAgent::ThinkingConfig.disabled)
      client = TestableCLIClient.new(options)
      args = client.test_build_cli_args
      idx = args.index("--thinking")
      idx.should_not be_nil
      args[idx.as(Int32) + 1].should eq("disabled") if idx
      args.should_not contain("--max-thinking-tokens")
    end

    it "emits --max-thinking-tokens for enabled thinking config" do
      options = ClaudeAgent::AgentOptions.new(thinking: ClaudeAgent::ThinkingConfig.enabled(12_000))
      client = TestableCLIClient.new(options)
      args = client.test_build_cli_args
      args.should contain("--max-thinking-tokens")
      args.should contain("12000")
      args.should_not contain("--thinking")
    end

    it "adds effort flags alongside thinking config" do
      options = ClaudeAgent::AgentOptions.new(
        thinking: ClaudeAgent::ThinkingConfig.enabled(8192),
        effort: ClaudeAgent::Effort::High,
      )
      client = TestableCLIClient.new(options)

      args = client.test_build_cli_args
      args.should contain("--max-thinking-tokens")
      args.should contain("8192")
      args.should contain("--effort")
      args.should contain("high")
    end
  end

  describe "#build_cli_args skills handling" do
    it "injects the bare Skill tool when skills is \"all\"" do
      options = ClaudeAgent::AgentOptions.new(skills: "all")
      client = TestableCLIClient.new(options)
      args = client.test_build_cli_args

      idx = args.index("--allowedTools")
      idx.should_not be_nil
      args[idx.as(Int32) + 1].should contain("Skill") if idx

      # `--setting-sources` is always emitted as a single `=`-joined token
      # (matches Python SDK canonical form).
      args.should contain("--setting-sources=user,project")
    end

    it "injects Skill(name) entries when given a list" do
      options = ClaudeAgent::AgentOptions.new(skills: ["git", "playwright"])
      client = TestableCLIClient.new(options)
      args = client.test_build_cli_args

      idx = args.index("--allowedTools")
      idx.should_not be_nil
      value = args[idx.as(Int32) + 1] if idx
      value.try(&.includes?("Skill(git)")).should be_true
      value.try(&.includes?("Skill(playwright)")).should be_true
    end

    it "does not touch setting_sources when caller set one explicitly" do
      options = ClaudeAgent::AgentOptions.new(skills: "all", setting_sources: ["local"])
      client = TestableCLIClient.new(options)
      args = client.test_build_cli_args

      args.should contain("--setting-sources=local")
      args.should_not contain("--setting-sources=user,project")
    end

    it "skills: [] (empty) is a true no-op and does not mutate setting_sources" do
      options = ClaudeAgent::AgentOptions.new(skills: [] of String)
      client = TestableCLIClient.new(options)
      args = client.test_build_cli_args

      # No `--setting-sources=…` should be emitted since the caller didn't
      # set one and empty skills should not trigger the user/project default.
      args.none?(&.starts_with?("--setting-sources=")).should be_true
    end

    it "skills: \"invalid\" raises ConfigurationError" do
      options = ClaudeAgent::AgentOptions.new(skills: "none")
      client = TestableCLIClient.new(options)

      expect_raises(ClaudeAgent::ConfigurationError, /must be \"all\"/) do
        client.test_build_cli_args
      end
    end

    it "emits single --setting-sources= token for an empty array" do
      options = ClaudeAgent::AgentOptions.new(setting_sources: [] of String)
      client = TestableCLIClient.new(options)
      args = client.test_build_cli_args

      args.should contain("--setting-sources=")
    end
  end

  describe "#build_cli_args with task_budget and title" do
    it "emits --task-budget but never --title (title is a session-file mutation)" do
      options = ClaudeAgent::AgentOptions.new(
        task_budget: ClaudeAgent::TaskBudget.new(120_000),
        title: "refactor session",
      )
      client = TestableCLIClient.new(options)
      args = client.test_build_cli_args

      args.should contain("--task-budget")
      args.should contain("120000")
      args.should_not contain("--title")
      args.should_not contain("refactor session")
    end
  end

  describe "#build_cli_args SystemPromptFile" do
    it "emits --system-prompt-file for file-backed prompts" do
      options = ClaudeAgent::AgentOptions.new(
        system_prompt: ClaudeAgent::SystemPromptFile.new("/tmp/prompt.md"),
      )
      client = TestableCLIClient.new(options)
      args = client.test_build_cli_args

      idx = args.index("--system-prompt-file")
      idx.should_not be_nil
      args[idx.as(Int32) + 1].should eq("/tmp/prompt.md") if idx
    end
  end

  describe "#build_cli_args SystemPromptPreset with exclude_dynamic_sections" do
    it "forwards append but never emits a --exclude-dynamic-sections flag" do
      options = ClaudeAgent::AgentOptions.new(
        system_prompt: ClaudeAgent::SystemPromptPreset.claude_code(
          "extra instructions",
          true,
        ),
      )
      client = TestableCLIClient.new(options)
      args = client.test_build_cli_args

      # The Claude Code CLI routes `exclude_dynamic_sections` through the
      # initialize control request (`excludeDynamicSections`), not argv.
      args.should_not contain("--exclude-dynamic-sections")
      args.should contain("--append-system-prompt")
      args.should contain("extra instructions")
    end
  end

  describe "#build_cli_args with max_turns" do
    it "adds --max-turns flag" do
      options = ClaudeAgent::AgentOptions.new(max_turns: 5)
      client = TestableCLIClient.new(options)

      args = client.test_build_cli_args
      args.should contain("--max-turns")
      args.should contain("5")
    end

    it "emits --include-hook-events when include_hook_events is true" do
      options = ClaudeAgent::AgentOptions.new(include_hook_events: true)
      client = TestableCLIClient.new(options)
      args = client.test_build_cli_args

      args.should contain("--include-hook-events")
    end

    it "never emits --include-hook-events by default" do
      options = ClaudeAgent::AgentOptions.new
      client = TestableCLIClient.new(options)
      args = client.test_build_cli_args

      args.should_not contain("--include-hook-events")
    end

    it "emits failIfUnavailable=true by default when sandbox is enabled" do
      sandbox = ClaudeAgent::SandboxSettings.new(enabled: true)
      options = ClaudeAgent::AgentOptions.new(sandbox: sandbox)
      client = TestableCLIClient.new(options)

      settings_json = client.test_build_settings_json(options)
      settings_json.should_not be_nil
      if settings_json
        parsed = JSON.parse(settings_json)
        parsed["sandbox"]["failIfUnavailable"].as_bool.should be_true
      end
    end

    it "emits failIfUnavailable=false when the caller opts into graceful degradation" do
      sandbox = ClaudeAgent::SandboxSettings.new(enabled: true, fail_if_unavailable: false)
      options = ClaudeAgent::AgentOptions.new(sandbox: sandbox)
      client = TestableCLIClient.new(options)

      settings_json = client.test_build_settings_json(options)
      if settings_json
        parsed = JSON.parse(settings_json)
        parsed["sandbox"]["failIfUnavailable"].as_bool.should be_false
      end
    end

    it "does not emit failIfUnavailable when the sandbox is disabled" do
      sandbox = ClaudeAgent::SandboxSettings.new(enabled: false)
      options = ClaudeAgent::AgentOptions.new(sandbox: sandbox)
      client = TestableCLIClient.new(options)

      settings_json = client.test_build_settings_json(options)
      if settings_json
        parsed = JSON.parse(settings_json)
        sandbox_obj = parsed["sandbox"]?
        sandbox_obj.try(&.as_h?.try(&.has_key?("failIfUnavailable"))).should be_falsey
      end
    end

    it "includes SDK MCP servers in --mcp-config with type=sdk" do
      sdk_server = ClaudeAgent::SDKMCPServer.new("mine", version: "0.1.0")
      mcp_servers = {"mine" => sdk_server.as(ClaudeAgent::MCPServerConfig)}
      options = ClaudeAgent::AgentOptions.new(mcp_servers: mcp_servers)
      client = TestableCLIClient.new(options)
      args = client.test_build_cli_args

      idx = args.index("--mcp-config")
      idx.should_not be_nil
      parsed = JSON.parse(args[idx.as(Int32) + 1])
      parsed["mcpServers"]["mine"]["type"].as_s.should eq("sdk")
      parsed["mcpServers"]["mine"]["name"].as_s.should eq("mine")
      parsed["mcpServers"]["mine"]["version"].as_s.should eq("0.1.0")
    end

    it "never forwards opts.agents as a --agents CLI flag (initialize-only)" do
      agents = {
        "reviewer" => ClaudeAgent::AgentDefinition.new(
          description: "r", prompt: "p",
        ),
      }
      options = ClaudeAgent::AgentOptions.new(agents: agents)
      client = TestableCLIClient.new(options)
      args = client.test_build_cli_args

      args.should_not contain("--agents")
    end

    it "raises ConfigurationError when resume_session_at is set without resume" do
      options = ClaudeAgent::AgentOptions.new(resume_session_at: "abc")
      client = TestableCLIClient.new(options)

      expect_raises(ClaudeAgent::ConfigurationError, /requires AgentOptions#resume/) do
        client.test_build_cli_args
      end
    end

    it "accepts resume_session_at when resume is set" do
      options = ClaudeAgent::AgentOptions.new(
        resume: "session-uuid",
        resume_session_at: "message-uuid",
      )
      client = TestableCLIClient.new(options)
      args = client.test_build_cli_args

      args.should contain("--resume")
      args.should contain("session-uuid")
      args.should contain("--resume-session-at")
      args.should contain("message-uuid")
    end

    it "emits --betas as separate variadic tokens" do
      options = ClaudeAgent::AgentOptions.new(betas: ["context-1m-2025-08-07", "experimental"])
      client = TestableCLIClient.new(options)
      args = client.test_build_cli_args

      idx = args.index("--betas")
      idx.should_not be_nil
      # Next two args should be the beta names as SEPARATE tokens, never
      # a single joined string like "context-1m-2025-08-07 experimental"
      # or "context-1m-2025-08-07,experimental".
      if idx
        args[idx + 1].should eq("context-1m-2025-08-07")
        args[idx + 2].should eq("experimental")
      end
      args.should_not contain("context-1m-2025-08-07 experimental")
      args.should_not contain("context-1m-2025-08-07,experimental")
    end

    it "skips --betas entirely when the list is empty" do
      options = ClaudeAgent::AgentOptions.new(betas: [] of String)
      client = TestableCLIClient.new(options)
      args = client.test_build_cli_args

      args.should_not contain("--betas")
    end

    it "emits --system-prompt \"\" when system_prompt is nil (vanilla SDK behavior)" do
      options = ClaudeAgent::AgentOptions.new
      client = TestableCLIClient.new(options)
      args = client.test_build_cli_args

      idx = args.index("--system-prompt")
      idx.should_not be_nil
      args[idx.as(Int32) + 1].should eq("") if idx
    end

    it "does not emit an empty --system-prompt when one is provided" do
      options = ClaudeAgent::AgentOptions.new(system_prompt: "You are helpful.")
      client = TestableCLIClient.new(options)
      args = client.test_build_cli_args

      # Exactly one --system-prompt token, carrying the provided value.
      args.count("--system-prompt").should eq(1)
      idx = args.index("--system-prompt")
      args[idx.as(Int32) + 1].should eq("You are helpful.") if idx
    end

    it "emits comma-separated --allowedTools and --disallowedTools" do
      options = ClaudeAgent::AgentOptions.new(
        allowed_tools: ["Read", "Glob", "Grep"],
        disallowed_tools: ["Bash", "Write"],
      )
      client = TestableCLIClient.new(options)
      args = client.test_build_cli_args

      args.should contain("Read,Glob,Grep")
      args.should contain("Bash,Write")
    end

    it "maps --tools ToolsPreset.claude_code to the CLI's canonical \"default\"" do
      options = ClaudeAgent::AgentOptions.new(tools: ClaudeAgent::ToolsPreset.claude_code)
      client = TestableCLIClient.new(options)
      args = client.test_build_cli_args

      idx = args.index("--tools")
      idx.should_not be_nil
      args[idx.as(Int32) + 1].should eq("default") if idx
    end

    it "forwards extra_args as trailing flags (string values and boolean switches)" do
      extra = {} of String => String?
      extra["ide"] = nil
      extra["debug-file"] = "/tmp/claude.log"
      options = ClaudeAgent::AgentOptions.new(extra_args: extra)
      client = TestableCLIClient.new(options)
      args = client.test_build_cli_args

      args.should contain("--ide")
      args.should contain("--debug-file")
      args.should contain("/tmp/claude.log")
      # Boolean switch must not be followed by a nil stringification.
      ide_idx = args.index("--ide").as(Int32)
      next_token = args[ide_idx + 1]?
      # Either we hit the end, or the next token is a new flag, never a nil.
      next_token.nil? || next_token.to_s.starts_with?("--")
    end

    it "accepts --flag-style keys in extra_args without double-prefixing" do
      extra = {} of String => String?
      extra["--custom-flag"] = "x"
      options = ClaudeAgent::AgentOptions.new(extra_args: extra)
      client = TestableCLIClient.new(options)
      args = client.test_build_cli_args

      args.should contain("--custom-flag")
      args.should_not contain("----custom-flag")
      args.should contain("x")
    end

    it "emits --permission-prompt-tool with the tool name" do
      options = ClaudeAgent::AgentOptions.new(permission_prompt_tool_name: "AskUser")
      client = TestableCLIClient.new(options)
      args = client.test_build_cli_args

      # The real CLI flag is `--permission-prompt-tool`, not the earlier
      # `--permission-prompt-tool-name`. Asserting the correct wire name
      # guards against the bug that used to crash subprocess startup.
      args.should contain("--permission-prompt-tool")
      args.should_not contain("--permission-prompt-tool-name")
      args.should contain("AskUser")
    end

    it "emits shouldQuery camelCase (not should_query) on user stream messages" do
      # Build a no-op client and capture what `send_prompt` writes by
      # substituting an in-memory IO for the subprocess stdin.
      client = ClaudeAgent::CLIClient.new
      buffer = IO::Memory.new
      client.set_input_for_test(buffer)

      client.send_prompt("hello", should_query: false)

      line = buffer.to_s.strip
      parsed = JSON.parse(line).as_h
      parsed["type"].as_s.should eq("user")
      parsed.has_key?("shouldQuery").should be_true
      parsed.has_key?("should_query").should be_false
      parsed["shouldQuery"].as_bool.should be_false
    end

    it "never emits --enable-file-checkpointing (it's an env var, not a flag)" do
      options = ClaudeAgent::AgentOptions.new(enable_file_checkpointing: true)
      client = TestableCLIClient.new(options)
      args = client.test_build_cli_args

      args.should_not contain("--enable-file-checkpointing")
    end

    it "sets CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING when file checkpointing is enabled" do
      options = ClaudeAgent::AgentOptions.new(enable_file_checkpointing: true)
      client = TestableCLIClient.new(options)
      env = client.test_build_env

      env.should_not be_nil
      env.try(&.["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"]?).should eq("true")
    end

    it "omits CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING by default" do
      client = TestableCLIClient.new(ClaudeAgent::AgentOptions.new)
      env = client.test_build_env

      env.try(&.has_key?("CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING")).should be_false
    end
  end

  describe "#build_env" do
    it "sets fine-grained tool streaming env var when partial messages are enabled" do
      options = ClaudeAgent::AgentOptions.new(include_partial_messages: true)
      client = TestableCLIClient.new(options)

      env = client.test_build_env
      env.should_not be_nil
      env.try(&.["CLAUDE_CODE_ENABLE_FINE_GRAINED_TOOL_STREAMING"]?).try(&.should eq("1"))
    end

    it "does not set fine-grained tool streaming env var by default" do
      client = TestableCLIClient.new(ClaudeAgent::AgentOptions.new)

      env = client.test_build_env
      env.should_not be_nil
      env.try(&.["CLAUDE_CODE_ENABLE_FINE_GRAINED_TOOL_STREAMING"]?).should be_nil
    end
  end

  describe "#build_agents_json" do
    it "builds JSON for agent definitions" do
      agents = {
        "researcher" => ClaudeAgent::AgentDefinition.new(
          description: "Research agent",
          prompt: "You are a researcher",
          tools: ["Read", "Grep"],
          model: "claude-sonnet-4-20250514"
        ),
      }

      client = TestableCLIClient.new
      json = client.test_build_agents_json(agents)
      parsed = JSON.parse(json)

      parsed["researcher"]["description"].as_s.should eq("Research agent")
      parsed["researcher"]["prompt"].as_s.should eq("You are a researcher")
      parsed["researcher"]["tools"].as_a.map(&.as_s).should eq(["Read", "Grep"])
      parsed["researcher"]["model"].as_s.should eq("claude-sonnet-4-20250514")
    end

    it "builds JSON for expanded agent definition" do
      effort = JSON::Any.new("high")
      agents = {
        "expanded" => ClaudeAgent::AgentDefinition.new(
          description: "Expanded agent",
          prompt: "You are expanded",
          tools: ["Read"],
          disallowed_tools: ["Bash"],
          skills: ["git"],
          memory: "project",
          max_turns: 4,
          initial_prompt: "kick-off",
          background: true,
          effort: effort,
          permission_mode: "plan",
        ),
      }

      client = TestableCLIClient.new
      json = client.test_build_agents_json(agents)
      parsed = JSON.parse(json)

      parsed["expanded"]["disallowedTools"].as_a.map(&.as_s).should eq(["Bash"])
      parsed["expanded"]["skills"].as_a.map(&.as_s).should eq(["git"])
      parsed["expanded"]["memory"].as_s.should eq("project")
      parsed["expanded"]["maxTurns"].as_i.should eq(4)
      parsed["expanded"]["initialPrompt"].as_s.should eq("kick-off")
      parsed["expanded"]["background"].as_bool.should be_true
      parsed["expanded"]["effort"].as_s.should eq("high")
      parsed["expanded"]["permissionMode"].as_s.should eq("plan")
    end

    it "builds JSON for minimal agent definition" do
      agents = {
        "simple" => ClaudeAgent::AgentDefinition.new(
          description: "Simple agent",
          prompt: "You are simple"
        ),
      }

      client = TestableCLIClient.new
      json = client.test_build_agents_json(agents)
      parsed = JSON.parse(json)

      parsed["simple"]["description"].as_s.should eq("Simple agent")
      parsed["simple"]["prompt"].as_s.should eq("You are simple")
      parsed["simple"]["tools"]?.should be_nil
      parsed["simple"]["model"]?.should be_nil
    end
  end

  describe "#build_mcp_servers_json" do
    it "builds JSON for stdio MCP server" do
      servers = {
        "filesystem" => ClaudeAgent::ExternalMCPServerConfig.stdio(
          "node",
          ["filesystem-server.js"],
          {"HOME" => "/home/user"}
        ),
      }

      client = TestableCLIClient.new
      json = client.test_build_mcp_servers_json(servers.transform_values(&.as(ClaudeAgent::MCPServerConfig)))
      parsed = JSON.parse(json)

      parsed["mcpServers"]["filesystem"]["command"].as_s.should eq("node")
      parsed["mcpServers"]["filesystem"]["args"].as_a.map(&.as_s).should eq(["filesystem-server.js"])
      parsed["mcpServers"]["filesystem"]["env"]["HOME"].as_s.should eq("/home/user")
    end

    it "builds JSON for HTTP MCP server" do
      servers = {
        "remote" => ClaudeAgent::ExternalMCPServerConfig.http(
          "https://api.example.com/mcp",
          {"Authorization" => "Bearer token123"}
        ),
      }

      client = TestableCLIClient.new
      json = client.test_build_mcp_servers_json(servers.transform_values(&.as(ClaudeAgent::MCPServerConfig)))
      parsed = JSON.parse(json)

      parsed["mcpServers"]["remote"]["type"].as_s.should eq("http")
      parsed["mcpServers"]["remote"]["url"].as_s.should eq("https://api.example.com/mcp")
      parsed["mcpServers"]["remote"]["headers"]["Authorization"].as_s.should eq("Bearer token123")
    end

    it "builds JSON for SSE MCP server" do
      servers = {
        "streaming" => ClaudeAgent::ExternalMCPServerConfig.sse("https://sse.example.com/events"),
      }

      client = TestableCLIClient.new
      json = client.test_build_mcp_servers_json(servers.transform_values(&.as(ClaudeAgent::MCPServerConfig)))
      parsed = JSON.parse(json)

      parsed["mcpServers"]["streaming"]["type"].as_s.should eq("sse")
      parsed["mcpServers"]["streaming"]["url"].as_s.should eq("https://sse.example.com/events")
    end

    it "includes SDK MCP servers with type=sdk and metadata (no instance)" do
      sdk_server = ClaudeAgent::SDKMCPServer.new("sdk-tools", version: "2.5.0")
      external_server = ClaudeAgent::ExternalMCPServerConfig.stdio("node", ["server.js"])

      servers = {
        "sdk"      => sdk_server.as(ClaudeAgent::MCPServerConfig),
        "external" => external_server.as(ClaudeAgent::MCPServerConfig),
      }

      client = TestableCLIClient.new
      json = client.test_build_mcp_servers_json(servers)
      parsed = JSON.parse(json)

      # SDK server must be declared so the CLI knows to route tool calls
      # back to us via `mcp_message` control requests. Only the metadata
      # crosses the wire; the instance itself stays in-process.
      sdk_entry = parsed["mcpServers"]["sdk"]
      sdk_entry["type"].as_s.should eq("sdk")
      sdk_entry["name"].as_s.should eq("sdk-tools")
      sdk_entry["version"].as_s.should eq("2.5.0")
      sdk_entry.as_h.has_key?("instance").should be_false

      parsed["mcpServers"]["external"].should_not be_nil
    end

    it "emits --mcp-config JSON even when only SDK servers are configured" do
      sdk_server = ClaudeAgent::SDKMCPServer.new("sdk-tools")
      servers = {"sdk" => sdk_server.as(ClaudeAgent::MCPServerConfig)}

      client = TestableCLIClient.new
      json = client.test_build_mcp_servers_json(servers)

      json.should_not eq("")
      parsed = JSON.parse(json)
      parsed["mcpServers"]["sdk"]["type"].as_s.should eq("sdk")
    end
  end

  describe "#build_settings_json" do
    it "returns nil when no sandbox settings" do
      options = ClaudeAgent::AgentOptions.new
      client = TestableCLIClient.new
      client.test_build_settings_json(options).should be_nil
    end

    it "builds JSON for basic sandbox settings" do
      sandbox = ClaudeAgent::SandboxSettings.new(
        enabled: true,
        auto_allow_bash_if_sandboxed: true
      )
      options = ClaudeAgent::AgentOptions.new(sandbox: sandbox)

      client = TestableCLIClient.new
      json = client.test_build_settings_json(options)
      json.should_not be_nil

      if json
        parsed = JSON.parse(json)
        parsed["sandbox"]["enabled"].as_bool.should be_true
        parsed["sandbox"]["autoAllowBashIfSandboxed"].as_bool.should be_true
      end
    end

    it "builds JSON for sandbox with excluded commands" do
      sandbox = ClaudeAgent::SandboxSettings.new(
        enabled: true,
        excluded_commands: ["rm", "dd", "mkfs"]
      )
      options = ClaudeAgent::AgentOptions.new(sandbox: sandbox)

      client = TestableCLIClient.new
      json = client.test_build_settings_json(options)

      if json
        parsed = JSON.parse(json)
        parsed["sandbox"]["excludedCommands"].as_a.map(&.as_s).should eq(["rm", "dd", "mkfs"])
      end
    end

    it "builds JSON for sandbox with network settings" do
      network = ClaudeAgent::SandboxNetworkSettings.new(
        allow_local_binding: true,
        allow_unix_sockets: ["/tmp/socket1", "/tmp/socket2"],
        http_proxy_port: 8080,
        socks_proxy_port: 1080
      )
      sandbox = ClaudeAgent::SandboxSettings.new(
        enabled: true,
        network: network
      )
      options = ClaudeAgent::AgentOptions.new(sandbox: sandbox)

      client = TestableCLIClient.new
      json = client.test_build_settings_json(options)

      if json
        parsed = JSON.parse(json)
        net = parsed["sandbox"]["network"]
        net["allowLocalBinding"].as_bool.should be_true
        net["allowUnixSockets"].as_a.map(&.as_s).should eq(["/tmp/socket1", "/tmp/socket2"])
        net["httpProxyPort"].as_i.should eq(8080)
        net["socksProxyPort"].as_i.should eq(1080)
      end
    end

    it "builds JSON for sandbox with ignore violations" do
      ignore = ClaudeAgent::SandboxIgnoreViolations.new(
        file: ["/tmp/*", "/var/log/*"],
        network: ["*.example.com"]
      )
      sandbox = ClaudeAgent::SandboxSettings.new(
        enabled: true,
        ignore_violations: ignore
      )
      options = ClaudeAgent::AgentOptions.new(sandbox: sandbox)

      client = TestableCLIClient
      json = client.new.test_build_settings_json(options)

      if json
        parsed = JSON.parse(json)
        violations = parsed["sandbox"]["ignoreViolations"]
        violations["file"].as_a.map(&.as_s).should eq(["/tmp/*", "/var/log/*"])
        violations["network"].as_a.map(&.as_s).should eq(["*.example.com"])
      end
    end

    it "builds JSON for sandbox.credentials (deny file + env var)" do
      creds = ClaudeAgent::SandboxCredentialsSettings.new(
        files: [ClaudeAgent::SandboxCredentialFile.new("~/.aws/credentials")],
        env_vars: [ClaudeAgent::SandboxCredentialEnvVar.new("AWS_SECRET_ACCESS_KEY")],
      )
      sandbox = ClaudeAgent::SandboxSettings.new(enabled: true, credentials: creds)
      options = ClaudeAgent::AgentOptions.new(sandbox: sandbox)

      json = TestableCLIClient.new.test_build_settings_json(options)
      json.should_not be_nil

      if json
        parsed = JSON.parse(json)
        c = parsed["sandbox"]["credentials"]
        file = c["files"].as_a.first
        file["path"].as_s.should eq("~/.aws/credentials")
        file["mode"].as_s.should eq("deny")
        env_var = c["envVars"].as_a.first
        env_var["name"].as_s.should eq("AWS_SECRET_ACCESS_KEY")
        env_var["mode"].as_s.should eq("deny")
      end
    end

    it "builds JSON for sandbox.credentials (mask mode with injectHosts)" do
      creds = ClaudeAgent::SandboxCredentialsSettings.new(
        env_vars: [
          ClaudeAgent::SandboxCredentialEnvVar.new(
            "AWS_SECRET_ACCESS_KEY",
            mode: "mask",
            inject_hosts: ["*.amazonaws.com"],
          ),
        ],
      )
      sandbox = ClaudeAgent::SandboxSettings.new(enabled: true, credentials: creds)
      options = ClaudeAgent::AgentOptions.new(sandbox: sandbox)

      json = TestableCLIClient.new.test_build_settings_json(options)
      json.should_not be_nil

      if json
        parsed = JSON.parse(json)
        env_var = parsed["sandbox"]["credentials"]["envVars"].as_a.first
        env_var["mode"].as_s.should eq("mask")
        env_var["injectHosts"].as_a.map(&.as_s).should eq(["*.amazonaws.com"])
      end
    end
  end

  describe "#build_cli_args new options" do
    it "does NOT emit --forward-subagent-text (initialize-only)" do
      options = ClaudeAgent::AgentOptions.new(forward_subagent_text: true)
      rendered = TestableCLIClient.new(options).test_build_cli_args.join(" ")
      rendered.should_not contain("--forward-subagent-text")
    end

    it "emits --managed-settings with the JSON payload" do
      inner = {} of String => JSON::Any
      inner["allow"] = JSON::Any.new([JSON::Any.new("Bash")] of JSON::Any)
      managed = {"permissions" => JSON::Any.new(inner)} of String => JSON::Any
      options = ClaudeAgent::AgentOptions.new(managed_settings: managed)
      args = TestableCLIClient.new(options).test_build_cli_args
      idx = args.index("--managed-settings")
      idx.should_not be_nil
      value = args[idx ? idx + 1 : -1]
      JSON.parse(value)["permissions"]["allow"].as_a.first.as_s.should eq("Bash")
    end

    it "does not emit --managed-settings by default" do
      rendered = TestableCLIClient.new.test_build_cli_args.join(" ")
      rendered.should_not contain("--managed-settings")
    end

    it "emits --plugin-dir for each string plugin" do
      options = ClaudeAgent::AgentOptions.new(plugins: ["/a", "/b"])
      rendered = TestableCLIClient.new(options).test_build_cli_args.join(" ")
      rendered.should contain("--plugin-dir /a")
      rendered.should contain("--plugin-dir /b")
    end

    it "emits --plugin-dir-no-mcp for PluginConfig with skip_mcp_discovery" do
      options = ClaudeAgent::AgentOptions.new(
        plugins: [ClaudeAgent::PluginConfig.new("/p", skip_mcp_discovery: true)]
      )
      rendered = TestableCLIClient.new(options).test_build_cli_args.join(" ")
      rendered.should contain("--plugin-dir-no-mcp /p")
      rendered.should_not contain("--plugin-dir /p")
    end

    it "emits --plugin-dir for PluginConfig without skip_mcp_discovery" do
      options = ClaudeAgent::AgentOptions.new(
        plugins: [ClaudeAgent::PluginConfig.new("/p")]
      )
      rendered = TestableCLIClient.new(options).test_build_cli_args.join(" ")
      rendered.should contain("--plugin-dir /p")
      rendered.should_not contain("--plugin-dir-no-mcp")
    end
  end
end

describe ClaudeAgent::ExternalMCPServerConfig do
  describe ".stdio" do
    it "creates stdio server config" do
      config = ClaudeAgent::ExternalMCPServerConfig.stdio("python", ["-m", "server"])
      config.command.should eq("python")
      config.args.should eq(["-m", "server"])
      config.type.should be_nil # stdio is default, no explicit type needed
    end

    it "creates stdio server with environment" do
      config = ClaudeAgent::ExternalMCPServerConfig.stdio(
        "node",
        ["server.js"],
        {"NODE_ENV" => "production"}
      )
      config.env.should eq({"NODE_ENV" => "production"})
    end
  end

  describe ".http" do
    it "creates HTTP server config" do
      config = ClaudeAgent::ExternalMCPServerConfig.http("https://api.example.com")
      config.type.should eq("http")
      config.url.should eq("https://api.example.com")
    end

    it "creates HTTP server with headers" do
      config = ClaudeAgent::ExternalMCPServerConfig.http(
        "https://api.example.com",
        {"X-API-Key" => "secret"}
      )
      config.headers.should eq({"X-API-Key" => "secret"})
    end
  end

  describe ".sse" do
    it "creates SSE server config" do
      config = ClaudeAgent::ExternalMCPServerConfig.sse("https://events.example.com")
      config.type.should eq("sse")
      config.url.should eq("https://events.example.com")
    end
  end
end

describe ClaudeAgent::ToolsPreset do
  describe ".claude_code" do
    it "creates claude_code preset" do
      preset = ClaudeAgent::ToolsPreset.claude_code
      preset.type.should eq("preset")
      preset.preset.should eq("claude_code")
    end
  end

  describe ".default" do
    it "creates default preset" do
      preset = ClaudeAgent::ToolsPreset.default
      preset.type.should eq("preset")
      preset.preset.should eq("default")
    end
  end
end

describe ClaudeAgent::SystemPromptPreset do
  describe ".claude_code" do
    it "creates claude_code preset without append" do
      preset = ClaudeAgent::SystemPromptPreset.claude_code
      preset.type.should eq("preset")
      preset.preset.should eq("claude_code")
      preset.append.should be_nil
    end

    it "creates claude_code preset with append" do
      preset = ClaudeAgent::SystemPromptPreset.claude_code("Additional instructions")
      preset.preset.should eq("claude_code")
      preset.append.should eq("Additional instructions")
    end
  end
end

describe "ClaudeAgent::CLIClient capability probe" do
  describe ".parse_long_flags" do
    it "extracts long option names from help text" do
      help = <<-HELP
        Usage: claude [options]

        Options:
          --model <id>              Model to use
          --title <title>           Session title
          --task-budget <n>         Token budget
          --max-thinking-tokens <n> Legacy thinking tokens
          -h, --help                Show help
        HELP

      flags = ClaudeAgent::CLIClient.parse_long_flags(help)
      flags.should contain("--model")
      flags.should contain("--title")
      flags.should contain("--task-budget")
      flags.should contain("--max-thinking-tokens")
      flags.should contain("--help")
    end

    it "returns an empty set for help text with no long flags" do
      flags = ClaudeAgent::CLIClient.parse_long_flags("usage: claude\n")
      flags.should be_empty
    end
  end

  describe "#filter_unsupported_flags" do
    # Shared no-op stderr callback so the filter's "dropped flag" warnings
    # do not leak into spec output.
    silent_stderr = ->(_line : String) { }

    it "drops optional flags the CLI does not advertise (space-separated form)" do
      options = ClaudeAgent::AgentOptions.new(stderr: silent_stderr)
      client = ClaudeAgent::CLIClient.new(options)
      args = [
        "--verbose",
        "--model", "claude-opus-4-7",
        "--task-budget", "120000",
        "--system-prompt-file", "/tmp/prompt.md",
        "--print",
      ]

      capabilities = Set{"--verbose", "--model", "--print"}
      filtered = client.filter_unsupported_flags(args, capabilities)

      filtered.should_not contain("--task-budget")
      filtered.should_not contain("120000")
      filtered.should_not contain("--system-prompt-file")
      filtered.should_not contain("/tmp/prompt.md")
      filtered.should contain("--model")
      filtered.should contain("claude-opus-4-7")
    end

    it "drops --flag=value style tokens without consuming the next arg" do
      options = ClaudeAgent::AgentOptions.new(stderr: silent_stderr)
      client = ClaudeAgent::CLIClient.new(options)
      # `--task-budget=100` is a single token; the following `--model` token
      # must survive the filter even though `--task-budget` is dropped.
      args = ["--task-budget=100", "--model", "claude-opus-4-7"]

      capabilities = Set{"--model"}
      filtered = client.filter_unsupported_flags(args, capabilities)

      filtered.should eq(["--model", "claude-opus-4-7"])
    end

    it "keeps optional flags that the CLI advertises" do
      options = ClaudeAgent::AgentOptions.new
      client = ClaudeAgent::CLIClient.new(options)
      args = ["--task-budget", "100", "--model", "claude-opus-4-7"]

      capabilities = Set{"--task-budget", "--model"}
      filtered = client.filter_unsupported_flags(args, capabilities)

      filtered.should eq(args)
    end

    it "never filters core flags even when not in the capability set" do
      options = ClaudeAgent::AgentOptions.new
      client = ClaudeAgent::CLIClient.new(options)
      args = ["--model", "claude-opus-4-7", "--output-format", "stream-json"]

      # Empty capabilities; only OPTIONAL_CLI_FLAGS get dropped.
      filtered = client.filter_unsupported_flags(args, Set(String).new)

      filtered.should eq(args)
    end

    it "passes args through unchanged when capabilities is nil" do
      options = ClaudeAgent::AgentOptions.new
      client = ClaudeAgent::CLIClient.new(options)
      args = ["--task-budget", "100", "--thinking", "adaptive"]

      client.filter_unsupported_flags(args, nil).should eq(args)
    end

    it "invokes the stderr callback for each dropped flag" do
      dropped = [] of String
      callback = ->(line : String) { dropped << line; nil }
      options = ClaudeAgent::AgentOptions.new(stderr: callback)
      client = ClaudeAgent::CLIClient.new(options)
      args = ["--task-budget", "100", "--thinking", "adaptive"]

      client.filter_unsupported_flags(args, Set(String).new)

      dropped.size.should eq(2)
      dropped.any?(&.includes?("--task-budget")).should be_true
      dropped.any?(&.includes?("--thinking")).should be_true
    end
  end

  describe "#probe_cli_capabilities" do
    it "returns nil without probing when probe_cli_capabilities is false" do
      ClaudeAgent::CLIClient.clear_capability_cache
      options = ClaudeAgent::AgentOptions.new(probe_cli_capabilities: false)

      probed = false
      probe = ->(_path : String) {
        probed = true
        Set(String).new.as(Set(String)?)
      }
      client = ProbeSpyCLIClient.new(options, probe)

      client.test_probe_cli_capabilities("/opt/claude").should be_nil
      probed.should be_false
    end

    it "caches probe results per cli_path" do
      ClaudeAgent::CLIClient.clear_capability_cache
      options = ClaudeAgent::AgentOptions.new

      calls = 0
      probe = ->(_path : String) {
        calls += 1
        Set{"--model", "--title"}.as(Set(String)?)
      }
      client = ProbeSpyCLIClient.new(options, probe)

      client.test_probe_cli_capabilities("/opt/claude")
      client.test_probe_cli_capabilities("/opt/claude")
      client.test_probe_cli_capabilities("/opt/claude")

      calls.should eq(1)
    end

    it "uses seeded cache entries without re-probing" do
      ClaudeAgent::CLIClient.clear_capability_cache
      ClaudeAgent::CLIClient.seed_capability_cache("/opt/claude", ["--model"])

      calls = 0
      probe = ->(_path : String) {
        calls += 1
        Set(String).new.as(Set(String)?)
      }
      client = ProbeSpyCLIClient.new(ClaudeAgent::AgentOptions.new, probe)

      result = client.test_probe_cli_capabilities("/opt/claude")
      result.should_not be_nil
      result.try(&.includes?("--model")).should be_true
      calls.should eq(0)
    end
  end

  describe "#detect_unknown_option_error" do
    it "recognizes the Claude Code stderr signature" do
      client = ClaudeAgent::CLIClient.new
      client.record_stderr_for_test("error: unknown option '--title'")

      client.detect_unknown_option_error.should eq("--title")
    end

    it "returns nil when stderr does not contain the signature" do
      client = ClaudeAgent::CLIClient.new
      client.record_stderr_for_test("warning: something")

      client.detect_unknown_option_error.should be_nil
    end
  end
end

describe ClaudeAgent::UnsupportedOptionError do
  it "builds a helpful default message" do
    error = ClaudeAgent::UnsupportedOptionError.new("--title", cli_path: "/opt/claude")
    error.option.should eq("--title")
    error.cli_path.should eq("/opt/claude")
    message = error.message.to_s
    message.should contain("--title")
    message.should contain("Upgrade the CLI")
  end
end
