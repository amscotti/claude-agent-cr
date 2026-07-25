require "./spec_helper"

describe ClaudeAgent::AgentOptions do
  it "initializes with defaults" do
    options = ClaudeAgent::AgentOptions.new
    options.permission_mode.should eq(ClaudeAgent::PermissionMode::Default)
    options.include_partial_messages?.should be_false
    options.continue_conversation?.should be_false
    options.resume.should be_nil
    options.resume_session_at.should be_nil
    options.fork_session?.should be_false
    options.enable_file_checkpointing?.should be_false
    options.thinking.should be_nil
    options.effort.should be_nil
    options.prompt_suggestions?.should be_false
    options.agent_progress_summaries?.should be_false
    options.session_store.should be_nil
    options.session_store_flush.should eq("batched")
    options.load_timeout_ms.should eq(60_000)
  end

  it "accepts session_store, session_store_flush, and load_timeout_ms" do
    store = ClaudeAgent::InMemorySessionStore.new
    options = ClaudeAgent::AgentOptions.new(
      session_store: store,
      session_store_flush: "eager",
      load_timeout_ms: 5_000,
    )
    options.session_store.should be(store)
    options.session_store_flush.should eq("eager")
    options.load_timeout_ms.should eq(5_000)
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
      max_thinking_tokens: 4096,
      thinking: ClaudeAgent::ThinkingConfig.enabled(8192),
      effort: ClaudeAgent::Effort::High,
      cwd: "/working/dir",
      session_id: "sess-123",
      prompt_suggestions: true,
      agent_progress_summaries: true,
      resume: "session-abc-123",
      resume_session_at: "msg-uuid-456",
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
    options.max_thinking_tokens.should eq(4096)
    options.thinking.should be_a(ClaudeAgent::ThinkingConfigEnabled)
    options.thinking.try(&.budget_tokens).should eq(8192)
    options.effort.should eq(ClaudeAgent::Effort::High)
    options.cwd.should eq("/working/dir")
    options.session_id.should eq("sess-123")
    options.prompt_suggestions?.should be_true
    options.agent_progress_summaries?.should be_true
    options.resume.should eq("session-abc-123")
    options.resume_session_at.should eq("msg-uuid-456")
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

  it "supports adaptive and disabled thinking configs" do
    adaptive = ClaudeAgent::AgentOptions.new(thinking: ClaudeAgent::ThinkingConfig.adaptive)
    adaptive.thinking.should be_a(ClaudeAgent::ThinkingConfigAdaptive)

    disabled = ClaudeAgent::AgentOptions.new(thinking: ClaudeAgent::ThinkingConfig.disabled)
    disabled.thinking.should be_a(ClaudeAgent::ThinkingConfigDisabled)
  end
end

describe ClaudeAgent::PermissionMode do
  it "has all expected modes" do
    ClaudeAgent::PermissionMode::Default.to_s.should eq("Default")
    ClaudeAgent::PermissionMode::AcceptEdits.to_s.should eq("AcceptEdits")
    ClaudeAgent::PermissionMode::Plan.to_s.should eq("Plan")
    ClaudeAgent::PermissionMode::BypassPermissions.to_s.should eq("BypassPermissions")
    ClaudeAgent::PermissionMode::Auto.to_s.should eq("Auto")
    ClaudeAgent::PermissionMode::DontAsk.to_s.should eq("DontAsk")
  end

  it "maps to CLI string values" do
    ClaudeAgent::PermissionMode::Auto.to_cli_value.should eq("auto")
    ClaudeAgent::PermissionMode::DontAsk.to_cli_value.should eq("dontAsk")
  end
end

describe ClaudeAgent::SystemPromptFile do
  it "wraps a path with type = file" do
    prompt = ClaudeAgent::SystemPromptFile.new("/tmp/prompt.md")
    prompt.type.should eq("file")
    prompt.path.should eq("/tmp/prompt.md")
  end
end

describe ClaudeAgent::TaskBudget do
  it "round-trips through JSON" do
    budget = ClaudeAgent::TaskBudget.new(50_000)
    parsed = ClaudeAgent::TaskBudget.from_json(budget.to_json)
    parsed.total.should eq(50_000)
  end
end

describe ClaudeAgent::Effort do
  it "has all expected levels" do
    ClaudeAgent::Effort::Low.to_s.should eq("Low")
    ClaudeAgent::Effort::Medium.to_s.should eq("Medium")
    ClaudeAgent::Effort::High.to_s.should eq("High")
    ClaudeAgent::Effort::Xhigh.to_s.should eq("Xhigh")
    ClaudeAgent::Effort::Max.to_s.should eq("Max")
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

describe ClaudeAgent::PluginConfig do
  it "defaults to local type and round-trips skip_mcp_discovery" do
    plugin = ClaudeAgent::PluginConfig.new("/path/to/plugin", skip_mcp_discovery: true)
    plugin.type.should eq("local")
    plugin.path.should eq("/path/to/plugin")
    plugin.skip_mcp_discovery?.should be_true

    parsed = ClaudeAgent::PluginConfig.from_json(plugin.to_json)
    parsed.path.should eq("/path/to/plugin")
    parsed.skip_mcp_discovery?.should be_true
  end

  it "serializes skip_mcp_discovery under the camelCase wire key" do
    json = ClaudeAgent::PluginConfig.new("/p", skip_mcp_discovery: true).to_json
    JSON.parse(json)["skipMcpDiscovery"].as_bool.should be_true
  end
end

describe "new AgentOptions fields (managed_settings, forward_subagent_text, sandbox.credentials)" do
  it "accepts managed_settings, forward_subagent_text, and sandbox credentials" do
    inner = {} of String => JSON::Any
    inner["deny"] = JSON::Any.new([JSON::Any.new("Bash(rm:*)")] of JSON::Any)
    permissions = {} of String => JSON::Any
    permissions["permissions"] = JSON::Any.new(inner)
    creds = ClaudeAgent::SandboxCredentialsSettings.new(
      env_vars: [
        ClaudeAgent::SandboxCredentialEnvVar.new("OPENAI_API_KEY", mode: "mask"),
      ],
    )
    sandbox = ClaudeAgent::SandboxSettings.new(enabled: true, credentials: creds)

    options = ClaudeAgent::AgentOptions.new(
      managed_settings: permissions,
      forward_subagent_text: true,
      sandbox: sandbox,
    )

    options.managed_settings.should eq(permissions)
    options.forward_subagent_text?.should be_true
    env_var = options.sandbox.try(&.credentials).try(&.env_vars).try(&.first)
    env_var.try(&.name).should eq("OPENAI_API_KEY")
    env_var.try(&.mode).should eq("mask")
  end

  it "defaults forward_subagent_text to false" do
    ClaudeAgent::AgentOptions.new.forward_subagent_text?.should be_false
  end
end

describe ClaudeAgent::SandboxNetworkSettings do
  it "accepts strict_allowlist and serializes as strictAllowlist" do
    net = ClaudeAgent::SandboxNetworkSettings.new(
      allowed_domains: ["api.example.com"],
      strict_allowlist: true,
    )
    net.strict_allowlist?.should be_true
    net.allowed_domains.should eq(["api.example.com"])

    parsed = JSON.parse(net.to_json)
    parsed["strictAllowlist"].as_bool.should be_true
    parsed["allowedDomains"].as_a.map(&.as_s).should eq(["api.example.com"])
  end

  it "round-trips strict_allowlist false through JSON" do
    net = ClaudeAgent::SandboxNetworkSettings.new(strict_allowlist: false)
    restored = ClaudeAgent::SandboxNetworkSettings.from_json(net.to_json)
    restored.strict_allowlist?.should be_false
  end

  it "defaults strict_allowlist to nil" do
    ClaudeAgent::SandboxNetworkSettings.new.strict_allowlist?.should be_nil
  end
end

describe "AgentOptions#workflow_size_guideline" do
  it "accepts advisory size values" do
    options = ClaudeAgent::AgentOptions.new(workflow_size_guideline: "medium")
    options.workflow_size_guideline.should eq("medium")
  end

  it "defaults to nil" do
    ClaudeAgent::AgentOptions.new.workflow_size_guideline.should be_nil
  end
end

describe "AgentOptions#debug and #debug_file" do
  it "defaults debug to false and debug_file to nil" do
    options = ClaudeAgent::AgentOptions.new
    options.debug?.should be_false
    options.debug_file.should be_nil
  end

  it "accepts debug and debug_file" do
    options = ClaudeAgent::AgentOptions.new(
      debug: true,
      debug_file: "/tmp/claude-debug.log",
    )
    options.debug?.should be_true
    options.debug_file.should eq("/tmp/claude-debug.log")
  end
end

describe "AgentOptions#tool_config" do
  it "defaults to nil" do
    ClaudeAgent::AgentOptions.new.tool_config.should be_nil
  end

  it "accepts AskUserQuestion preview_format" do
    tool_config = ClaudeAgent::ToolConfig.new(
      ask_user_question: ClaudeAgent::AskUserQuestionConfig.new(preview_format: "html"),
    )
    options = ClaudeAgent::AgentOptions.new(tool_config: tool_config)
    options.tool_config.try(&.ask_user_question).try(&.preview_format).should eq("html")
  end

  it "serializes toolConfig with camelCase keys" do
    tool_config = ClaudeAgent::ToolConfig.new(
      ask_user_question: ClaudeAgent::AskUserQuestionConfig.new(preview_format: "markdown"),
    )
    parsed = JSON.parse(tool_config.to_json)
    parsed["askUserQuestion"]["previewFormat"].as_s.should eq("markdown")
  end

  it "round-trips through JSON" do
    tool_config = ClaudeAgent::ToolConfig.new(
      ask_user_question: ClaudeAgent::AskUserQuestionConfig.new(preview_format: "html"),
    )
    restored = ClaudeAgent::ToolConfig.from_json(tool_config.to_json)
    restored.ask_user_question.try(&.preview_format).should eq("html")
  end
end

describe "AgentOptions.whole_tool_allowed" do
  it "treats bare tool names as whole-tool allows" do
    ClaudeAgent::AgentOptions.whole_tool_allowed("Read").should eq("Read")
    ClaudeAgent::AgentOptions.whole_tool_allowed("mcp__server__tool").should eq("mcp__server__tool")
  end

  it "treats empty and wildcard specifiers as whole-tool allows" do
    ClaudeAgent::AgentOptions.whole_tool_allowed("Read(*)").should eq("Read")
    ClaudeAgent::AgentOptions.whole_tool_allowed("Read()").should eq("Read")
    ClaudeAgent::AgentOptions.whole_tool_allowed("mcp__server__tool(*)").should eq("mcp__server__tool")
  end

  it "rejects real specifiers and malformed entries" do
    ClaudeAgent::AgentOptions.whole_tool_allowed("Bash(ls:*)").should be_nil
    ClaudeAgent::AgentOptions.whole_tool_allowed("Bash(git log:*)").should be_nil
    ClaudeAgent::AgentOptions.whole_tool_allowed("").should be_nil
    ClaudeAgent::AgentOptions.whole_tool_allowed("   ").should be_nil
    ClaudeAgent::AgentOptions.whole_tool_allowed("Bash(ls:*").should be_nil
    ClaudeAgent::AgentOptions.whole_tool_allowed("Bash(ls)x").should be_nil
    ClaudeAgent::AgentOptions.whole_tool_allowed("(foo)").should be_nil
    ClaudeAgent::AgentOptions.whole_tool_allowed("(*)").should be_nil
    ClaudeAgent::AgentOptions.whole_tool_allowed("Read(*x").should be_nil
  end
end

describe "AgentOptions#can_use_tool_shadowed_warning" do
  # Minimal can_use_tool callback so the warning path is active.
  can_use = ->(_ctx : ClaudeAgent::PermissionContext) {
    ClaudeAgent::PermissionResult.allow
  }

  it "returns nil when can_use_tool is unset" do
    options = ClaudeAgent::AgentOptions.new(
      permission_mode: ClaudeAgent::PermissionMode::BypassPermissions,
      allowed_tools: ["Read"],
    )
    options.can_use_tool_shadowed_warning.should be_nil
  end

  it "warns on bypassPermissions" do
    options = ClaudeAgent::AgentOptions.new(
      can_use_tool: can_use,
      permission_mode: ClaudeAgent::PermissionMode::BypassPermissions,
    )
    message = options.can_use_tool_shadowed_warning
    message.should_not be_nil
    message.try(&.should contain("bypassPermissions"))
    message.try(&.should contain("PreToolUse"))
  end

  it "bypassPermissions takes precedence over bare allowed_tools entries" do
    options = ClaudeAgent::AgentOptions.new(
      can_use_tool: can_use,
      permission_mode: ClaudeAgent::PermissionMode::BypassPermissions,
      allowed_tools: ["Read", "Write"],
    )
    message = options.can_use_tool_shadowed_warning
    message.should_not be_nil
    message.try(&.should contain("bypassPermissions"))
    message.try(&.should_not contain("Read"))
  end

  it "lists bare allowed_tools entries that shadow the callback" do
    options = ClaudeAgent::AgentOptions.new(
      can_use_tool: can_use,
      allowed_tools: ["Read", "mcp__server__tool", "Bash(ls:*)"],
    )
    message = options.can_use_tool_shadowed_warning
    message.should_not be_nil
    message.try(&.should contain("Read, mcp__server__tool"))
    message.try(&.should_not contain("Bash(ls:*)"))
  end

  it "treats Read(*) and Read() as whole-tool allows" do
    options = ClaudeAgent::AgentOptions.new(
      can_use_tool: can_use,
      allowed_tools: ["Read(*)", "Write()"],
    )
    message = options.can_use_tool_shadowed_warning
    message.should_not be_nil
    message.try(&.should contain("invoked for: Read, Write."))
  end

  it "dedupes entries that resolve to the same tool" do
    options = ClaudeAgent::AgentOptions.new(
      can_use_tool: can_use,
      allowed_tools: ["Read", "Read()", "Read(*)"],
    )
    message = options.can_use_tool_shadowed_warning
    message.should_not be_nil
    message.try(&.should contain("invoked for: Read."))
  end

  it "preserves first-seen order" do
    options = ClaudeAgent::AgentOptions.new(
      can_use_tool: can_use,
      allowed_tools: ["Write", "Read", "Write()"],
    )
    message = options.can_use_tool_shadowed_warning
    message.should_not be_nil
    message.try(&.should contain("invoked for: Write, Read."))
  end

  it "returns nil for specifier-only allowed_tools" do
    options = ClaudeAgent::AgentOptions.new(
      can_use_tool: can_use,
      allowed_tools: ["Bash(ls:*)", "Bash(git log:*)"],
    )
    options.can_use_tool_shadowed_warning.should be_nil
  end

  it "skills=all injects Skill into the shadow list" do
    options = ClaudeAgent::AgentOptions.new(
      can_use_tool: can_use,
      skills: "all",
    )
    message = options.can_use_tool_shadowed_warning
    message.should_not be_nil
    message.try(&.should contain("invoked for: Skill"))
  end

  it "skills=all does not duplicate an explicit Skill entry" do
    options = ClaudeAgent::AgentOptions.new(
      can_use_tool: can_use,
      skills: "all",
      allowed_tools: ["Skill"],
    )
    message = options.can_use_tool_shadowed_warning
    message.should_not be_nil
    message.try(&.should contain("invoked for: Skill."))
  end

  it "named skills do not shadow" do
    options = ClaudeAgent::AgentOptions.new(
      can_use_tool: can_use,
      skills: ["reviewer"],
    )
    options.can_use_tool_shadowed_warning.should be_nil
  end

  it "skills=all leaves caller allowed_tools untouched" do
    allowed = ["Read"]
    options = ClaudeAgent::AgentOptions.new(
      can_use_tool: can_use,
      skills: "all",
      allowed_tools: allowed,
    )
    message = options.can_use_tool_shadowed_warning
    message.should_not be_nil
    message.try(&.should contain("Read, Skill"))
    allowed.should eq(["Read"])
  end
end
