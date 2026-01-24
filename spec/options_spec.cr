require "./spec_helper"

describe ClaudeAgent::AgentOptions do
  it "initializes with defaults" do
    options = ClaudeAgent::AgentOptions.new
    options.permission_mode.should eq(ClaudeAgent::PermissionMode::Default)
    options.include_partial_messages?.should be_false
    options.continue_conversation?.should be_false
    options.resume.should be_nil
    options.fork_session?.should be_false
    options.enable_file_checkpointing?.should be_false
  end

  it "accepts all configuration options" do
    options = ClaudeAgent::AgentOptions.new(
      system_prompt: "You are a helpful assistant",
      model: "claude-sonnet-4-5-20250929",
      fallback_model: "claude-haiku-4-5-20251001",
      allowed_tools: ["Read", "Write"],
      disallowed_tools: ["Bash"],
      permission_mode: ClaudeAgent::PermissionMode::AcceptEdits,
      max_budget_usd: 1.0,
      betas: ["beta-feature"],
      add_dirs: ["/extra/dir"],
      max_turns: 10,
      cwd: "/working/dir",
      session_id: "sess-123",
      resume: "session-abc-123",
      fork_session: true,
      enable_file_checkpointing: true,
      setting_sources: ["project", "user"]
    )

    options.system_prompt.should eq("You are a helpful assistant")
    options.model.should eq("claude-sonnet-4-5-20250929")
    options.fallback_model.should eq("claude-haiku-4-5-20251001")
    options.allowed_tools.should eq(["Read", "Write"])
    options.disallowed_tools.should eq(["Bash"])
    options.permission_mode.should eq(ClaudeAgent::PermissionMode::AcceptEdits)
    options.max_budget_usd.should eq(1.0)
    options.betas.should eq(["beta-feature"])
    options.add_dirs.should eq(["/extra/dir"])
    options.max_turns.should eq(10)
    options.cwd.should eq("/working/dir")
    options.session_id.should eq("sess-123")
    options.resume.should eq("session-abc-123")
    options.fork_session?.should be_true
    options.enable_file_checkpointing?.should be_true
    options.setting_sources.should eq(["project", "user"])
  end

  it "supports agent definitions" do
    agents = {
      "reviewer" => ClaudeAgent::AgentDefinition.new(
        description: "Reviews code quality",
        prompt: "You are a code reviewer",
        name: "Code Reviewer",
        tools: ["Read", "Grep"],
        model: "sonnet"
      ),
    }

    options = ClaudeAgent::AgentOptions.new(agents: agents, agent: "reviewer")
    options.agents.should_not be_nil
    options.agent.should eq("reviewer")

    if agent_defs = options.agents
      agent_defs["reviewer"].description.should eq("Reviews code quality")
    end
  end

  it "accepts SystemPromptPreset for system_prompt" do
    options = ClaudeAgent::AgentOptions.new(
      system_prompt: ClaudeAgent::SystemPromptPreset.claude_code
    )

    if preset = options.system_prompt.as?(ClaudeAgent::SystemPromptPreset)
      preset.preset.should eq("claude_code")
      preset.append.should be_nil
    else
      fail "Expected SystemPromptPreset"
    end
  end

  it "accepts SystemPromptPreset with append" do
    options = ClaudeAgent::AgentOptions.new(
      system_prompt: ClaudeAgent::SystemPromptPreset.claude_code("Extra instructions")
    )

    if preset = options.system_prompt.as?(ClaudeAgent::SystemPromptPreset)
      preset.preset.should eq("claude_code")
      preset.append.should eq("Extra instructions")
    else
      fail "Expected SystemPromptPreset"
    end
  end

  it "accepts ToolsPreset for tools" do
    options = ClaudeAgent::AgentOptions.new(
      tools: ClaudeAgent::ToolsPreset.claude_code
    )

    if preset = options.tools.as?(ClaudeAgent::ToolsPreset)
      preset.preset.should eq("claude_code")
    else
      fail "Expected ToolsPreset"
    end
  end

  it "accepts Array(String) for tools" do
    options = ClaudeAgent::AgentOptions.new(
      tools: ["Read", "Write", "Bash"]
    )

    if tools = options.tools.as?(Array(String))
      tools.should eq(["Read", "Write", "Bash"])
    else
      fail "Expected Array(String)"
    end
  end

  it "supports output format configuration" do
    output_format = ClaudeAgent::OutputFormat.new(
      type: "json_schema",
      schema: {"type" => JSON::Any.new("object")}
    )

    options = ClaudeAgent::AgentOptions.new(output_format: output_format)
    options.output_format.should_not be_nil

    if fmt = options.output_format
      fmt.type.should eq("json_schema")
    end
  end
end

describe ClaudeAgent::PermissionMode do
  it "has all expected modes" do
    ClaudeAgent::PermissionMode::Default.to_s.should eq("Default")
    ClaudeAgent::PermissionMode::AcceptEdits.to_s.should eq("AcceptEdits")
    ClaudeAgent::PermissionMode::Plan.to_s.should eq("Plan")
    ClaudeAgent::PermissionMode::BypassPermissions.to_s.should eq("BypassPermissions")
  end
end

describe ClaudeAgent::AgentDefinition do
  it "can be serialized to JSON" do
    agent = ClaudeAgent::AgentDefinition.new(
      description: "A test agent",
      prompt: "You are a test agent",
      name: "Test Agent",
      tools: ["Read"],
      model: "sonnet"
    )

    json = agent.to_json
    parsed = ClaudeAgent::AgentDefinition.from_json(json)

    parsed.name.should eq("Test Agent")
    parsed.description.should eq("A test agent")
    parsed.prompt.should eq("You are a test agent")
    parsed.tools.should eq(["Read"])
    parsed.model.should eq("sonnet")
  end
end
