require "./spec_helper"

describe ClaudeAgent::PermissionResult do
  describe ".allow" do
    it "creates an allow result" do
      result = ClaudeAgent::PermissionResult.allow
      result.allow?.should be_true
      result.reason.should be_nil
    end

    it "creates an allow result with reason" do
      result = ClaudeAgent::PermissionResult.allow(reason: "User approved")
      result.allow?.should be_true
      result.reason.should eq("User approved")
    end
  end

  describe ".deny" do
    it "creates a deny result" do
      result = ClaudeAgent::PermissionResult.deny
      result.allow?.should be_false
      result.interrupt?.should be_false
    end

    it "creates a deny result with interrupt" do
      result = ClaudeAgent::PermissionResult.deny(reason: "Blocked", interrupt: true)
      result.allow?.should be_false
      result.reason.should eq("Blocked")
      result.interrupt?.should be_true
    end
  end

  describe ".allow_and_remember" do
    it "creates an allow result with session rule" do
      result = ClaudeAgent::PermissionResult.allow_and_remember("Bash")
      result.allow?.should be_true
      result.updated_permissions.should_not be_nil
      result.updated_permissions.try(&.size).should eq(1)

      update = result.updated_permissions.try(&.first)
      update.should be_a(ClaudeAgent::AddRulesUpdate)
      if update.is_a?(ClaudeAgent::AddRulesUpdate)
        update.rules.size.should eq(1)
        update.rules.first.pattern.should eq("Bash")
        update.behavior.should eq(ClaudeAgent::PermissionRuleBehavior::Allow)
        update.destination.should eq(ClaudeAgent::PermissionUpdateDestination::Session)
      end
    end
  end

  describe ".deny_and_remember" do
    it "creates a deny result with session rule" do
      result = ClaudeAgent::PermissionResult.deny_and_remember("Bash(rm:*)")
      result.allow?.should be_false
      result.updated_permissions.should_not be_nil

      update = result.updated_permissions.try(&.first)
      update.should be_a(ClaudeAgent::AddRulesUpdate)
      if update.is_a?(ClaudeAgent::AddRulesUpdate)
        update.rules.first.pattern.should eq("Bash(rm:*)")
        update.behavior.should eq(ClaudeAgent::PermissionRuleBehavior::Deny)
      end
    end
  end

  describe ".suppress" do
    it "creates a suppress_response result" do
      result = ClaudeAgent::PermissionResult.suppress
      result.suppress_response?.should be_true
      result.allow?.should be_false
    end
  end
end

describe ClaudeAgent::PermissionRuleValue do
  describe ".tool" do
    it "creates a tool rule" do
      rule = ClaudeAgent::PermissionRuleValue.tool("Read")
      rule.pattern.should eq("Read")
    end

    it "creates a tool rule with description" do
      rule = ClaudeAgent::PermissionRuleValue.tool("Read", "Allow reading files")
      rule.pattern.should eq("Read")
      rule.description.should eq("Allow reading files")
    end
  end

  describe ".tool_with_args" do
    it "creates a tool rule with arguments" do
      rule = ClaudeAgent::PermissionRuleValue.tool_with_args("Bash", "git:*")
      rule.pattern.should eq("Bash(git:*)")
    end
  end
end

describe ClaudeAgent::AddRulesUpdate do
  it "creates an add rules update" do
    update = ClaudeAgent::AddRulesUpdate.new(
      rules: [ClaudeAgent::PermissionRuleValue.tool("Read")],
      behavior: ClaudeAgent::PermissionRuleBehavior::Allow,
      destination: ClaudeAgent::PermissionUpdateDestination::ProjectSettings
    )

    update.type.should eq("addRules")
    update.rules.size.should eq(1)
    update.behavior.should eq(ClaudeAgent::PermissionRuleBehavior::Allow)
    update.destination.should eq(ClaudeAgent::PermissionUpdateDestination::ProjectSettings)
  end
end

describe ClaudeAgent::SetModeUpdate do
  it "creates a set mode update" do
    update = ClaudeAgent::SetModeUpdate.new(
      mode: ClaudeAgent::PermissionMode::AcceptEdits,
      destination: ClaudeAgent::PermissionUpdateDestination::Session
    )

    update.type.should eq("setMode")
    update.mode.should eq(ClaudeAgent::PermissionMode::AcceptEdits)
  end
end

describe ClaudeAgent::AddDirectoriesUpdate do
  it "creates an add directories update" do
    update = ClaudeAgent::AddDirectoriesUpdate.new(
      directories: ["/home/user/project", "/tmp"],
      destination: ClaudeAgent::PermissionUpdateDestination::LocalSettings
    )

    update.type.should eq("addDirectories")
    update.directories.size.should eq(2)
    update.destination.should eq(ClaudeAgent::PermissionUpdateDestination::LocalSettings)
  end
end

describe ClaudeAgent::PermissionContext do
  it "creates a permission context" do
    context = ClaudeAgent::PermissionContext.new(
      tool_name: "Bash",
      tool_input: {"command" => JSON::Any.new("ls -la")},
      session_id: "sess-123"
    )

    context.tool_name.should eq("Bash")
    context.tool_input["command"].as_s.should eq("ls -la")
    context.session_id.should eq("sess-123")
    context.suggestions.should be_nil
    context.request_id.should be_nil
  end

  it "carries request_id for out-of-band permission correlation" do
    context = ClaudeAgent::PermissionContext.new(
      tool_name: "Bash",
      tool_input: {"command" => JSON::Any.new("ls")},
      session_id: "sess-123",
      request_id: "req_perm_42",
    )

    context.request_id.should eq("req_perm_42")
  end
end

describe ClaudeAgent::InterruptReceipt do
  it "parses still_queued and cancelled from a control response" do
    receipt = ClaudeAgent::InterruptReceipt.from_response({
      "still_queued" => JSON::Any.new([JSON::Any.new("a"), JSON::Any.new("b")]),
      "cancelled"    => JSON::Any.new([JSON::Any.new("c")]),
    })

    receipt.still_queued.should eq(["a", "b"])
    receipt.cancelled.should eq(["c"])
  end

  it "parses cancelled_uuids alias and defaults missing arrays to empty" do
    receipt = ClaudeAgent::InterruptReceipt.from_response({
      "cancelled_uuids" => JSON::Any.new([JSON::Any.new("x")]),
    })

    receipt.still_queued.should eq([] of String)
    receipt.cancelled.should eq(["x"])
  end
end

describe ClaudeAgent::ReadStateEntry do
  it "holds path and mtime for seed_read_state" do
    entry = ClaudeAgent::ReadStateEntry.new("/tmp/file.cr", 123_i64)
    entry.path.should eq("/tmp/file.cr")
    entry.mtime.should eq(123_i64)
  end
end

describe ClaudeAgent::ControlSeedReadStateRequest do
  it "serializes the seed_read_state subtype" do
    req = ClaudeAgent::ControlSeedReadStateRequest.new("/tmp/x", 99_i64)
    json = JSON.parse(req.to_json).as_h
    json["subtype"].as_s.should eq("seed_read_state")
    json["path"].as_s.should eq("/tmp/x")
    json["mtime"].as_i64.should eq(99_i64)
  end

  it "parses via ControlRequestInnerConverter" do
    parsed = ClaudeAgent::ControlRequestInnerConverter.from_json(
      JSON::PullParser.new({
        "subtype" => "seed_read_state",
        "path"    => "/a",
        "mtime"   => 1,
      }.to_json)
    )
    parsed.should be_a(ClaudeAgent::ControlSeedReadStateRequest)
    if parsed.is_a?(ClaudeAgent::ControlSeedReadStateRequest)
      parsed.path.should eq("/a")
      parsed.mtime.should eq(1_i64)
    end
  end
end

describe "v0.11.0 Control and Permission parity" do
  it "parses and serializes MCPServerProvenance" do
    prov = ClaudeAgent::MCPServerProvenance.new("github", "plugin")
    restored = ClaudeAgent::MCPServerProvenance.from_json(prov.to_json)
    restored.name.should eq("github")
    restored.source.should eq("plugin")
  end

  it "parses MatchedAskRule in both snake_case and camelCase and serializes as snake_case" do
    snake = ClaudeAgent::MatchedAskRule.from_json(%({"source":"userSettings","tool_name":"Bash","rule_content":"git *"}))
    snake.source.should eq("userSettings")
    snake.tool_name.should eq("Bash")
    snake.rule_content.should eq("git *")

    camel = ClaudeAgent::MatchedAskRule.from_json(
      %({"source":"projectSettings","toolName":"Write","ruleContent":"/etc/*"})
    )
    camel.source.should eq("projectSettings")
    camel.tool_name.should eq("Write")
    camel.rule_content.should eq("/etc/*")

    serialized = JSON.parse(camel.to_json).as_h
    serialized["tool_name"].as_s.should eq("Write")
    serialized["rule_content"].as_s.should eq("/etc/*")
  end

  it "parses extended fields on ControlPermissionRequest and carries them on PermissionContext" do
    json = {
      "subtype"                    => "can_use_tool",
      "tool_name"                  => "mcp__docs__fetch",
      "input"                      => {"url" => "https://example.com"},
      "mcp_server"                 => {"name" => "docs", "source" => "sdk"},
      "decision_reason_type"       => "rule",
      "decision_reason_code"       => "ask_rule",
      "server_policy_ask_only"     => true,
      "classifier_approvable"      => false,
      "suppress_always_allow_rule" => true,
      "default_to_no"              => true,
      "matched_ask_rule"           => {"source" => "session", "tool_name" => "mcp__docs__fetch", "rule_content" => "*"},
      "requires_user_interaction"  => true,
      "server_prompt"              => "Fetch external docs?",
    }.to_json

    req = ClaudeAgent::ControlPermissionRequest.from_json(json)
    req.mcp_server.try(&.name).should eq("docs")
    req.decision_reason_type.should eq("rule")
    req.decision_reason_code.should eq("ask_rule")
    req.server_policy_ask_only?.should be_true
    req.classifier_approvable?.should be_false
    req.suppress_always_allow_rule?.should be_true
    req.default_to_no?.should be_true
    req.matched_ask_rule.try(&.tool_name).should eq("mcp__docs__fetch")
    req.requires_user_interaction?.should be_true
    req.server_prompt.should eq("Fetch external docs?")

    ctx = ClaudeAgent::PermissionContext.new(
      tool_name: req.tool_name,
      tool_input: req.input,
      session_id: "sess-1",
      mcp_server: req.mcp_server,
      decision_reason_type: req.decision_reason_type,
      decision_reason_code: req.decision_reason_code,
      server_policy_ask_only: req.server_policy_ask_only,
      classifier_approvable: req.classifier_approvable,
      suppress_always_allow_rule: req.suppress_always_allow_rule,
      default_to_no: req.default_to_no,
      matched_ask_rule: req.matched_ask_rule,
      requires_user_interaction: req.requires_user_interaction,
      server_prompt: req.server_prompt,
    )
    ctx.mcp_server.try(&.source).should eq("sdk")
    ctx.decision_reason_type.should eq("rule")
    ctx.decision_reason_code.should eq("ask_rule")
    ctx.server_policy_ask_only?.should be_true
    ctx.classifier_approvable?.should be_false
    ctx.suppress_always_allow_rule?.should be_true
    ctx.default_to_no?.should be_true
    ctx.matched_ask_rule.try(&.rule_content).should eq("*")
    ctx.requires_user_interaction?.should be_true
    ctx.server_prompt.should eq("Fetch external docs?")
  end

  it "parses extended ControlRequest subtypes and response payloads" do
    init_req = ClaudeAgent::ControlInitializeRequest.from_json({
      "subtype"                => "initialize",
      "systemPromptSnapshot"   => false,
      "sdkMcpServerConfigs"    => {"srv" => {"timeout" => 5000}},
      "sdkMcpServerManifests"  => {"srv" => {"initializeResult" => {"protocolVersion" => "2025-03-26"}}},
      "excludeDynamicSections" => true,
      "forwardSubagentText"    => true,
      "title"                  => "My Session",
      "skills"                 => ["commit"],
    }.to_json)
    init_req.system_prompt_snapshot.should be_false
    init_req.sdk_mcp_server_configs.try(&.["srv"].as_h["timeout"].as_i).should eq(5000)
    init_req.sdk_mcp_server_manifests.should_not be_nil
    init_req.exclude_dynamic_sections.should be_true
    init_req.forward_subagent_text.should be_true
    init_req.title.should eq("My Session")
    init_req.skills.should eq(["commit"])

    elicit_req = ClaudeAgent::ControlElicitationRequest.from_json({
      "subtype"         => "elicitation",
      "mcp_server_name" => "auth",
      "message"         => "Sign in",
      "property_order"  => ["user", "pass"],
      "title"           => "Auth",
      "display_name"    => "Auth Server",
      "description"     => "Credentials",
    }.to_json)
    elicit_req.property_order.should eq(["user", "pass"])
    elicit_req.title.should eq("Auth")
    elicit_req.display_name.should eq("Auth Server")
    elicit_req.description.should eq("Credentials")

    think_req = ClaudeAgent::ControlSetMaxThinkingTokensRequest.from_json(
      %({"subtype":"set_max_thinking_tokens","max_thinking_tokens":null,"thinking_display":"summarized"})
    )
    think_req.max_thinking_tokens.should be_nil
    think_req.thinking_display.should eq("summarized")

    reload_req = ClaudeAgent::ControlReloadPluginsRequest.from_json({
      "subtype"              => "reload_plugins",
      "hold_on_cache_impact" => true,
      "add_plugins"          => [{"type" => "local", "path" => "/p"}],
      "refuse_if_busy"       => true,
    }.to_json)
    reload_req.hold_on_cache_impact?.should be_true
    reload_req.add_plugins.try(&.size).should eq(1)
    reload_req.refuse_if_busy?.should be_true

    ctx_req = ClaudeAgent::ControlGetContextUsageRequest.from_json(
      %({"subtype":"get_context_usage","detail":"full"})
    )
    ctx_req.detail.should eq("full")

    mcp_status_req = ClaudeAgent::ControlMCPStatusRequest.from_json(
      %({"subtype":"mcp_status","liveReply":true})
    )
    mcp_status_req.live_reply?.should be_true

    set_servers_req = ClaudeAgent::ControlSetMcpServersRequest.from_json(
      %({"subtype":"mcp_set_servers","servers":{"docs":{"type":"http","url":"https://example.com"}}})
    )
    set_servers_req.servers["docs"].as_h["type"].as_s.should eq("http")
    set_servers_req.mcp_servers["docs"].as_h["type"].as_s.should eq("http")

    rename_inner = ClaudeAgent::ControlRequestInnerConverter.from_json(
      JSON::PullParser.new(%({"subtype":"rename_session","title":"New Name","source":"remote","session_id":"s-1"}))
    )
    rename_inner.should be_a(ClaudeAgent::ControlRenameSessionRequest)
    rename = rename_inner.as(ClaudeAgent::ControlRenameSessionRequest)
    rename.title.should eq("New Name")
    rename.source.should eq("remote")
    rename.session_id.should eq("s-1")
  end

  it "parses new fields on MCPServerStatus, MCPToolInfo, ContextUsageCategory, and ContextUsageResponse" do
    status = ClaudeAgent::MCPServerStatus.from_json({
      "name"   => "docs",
      "status" => "connected",
      "source" => "sdk",
      "tools"  => [
        {
          "name"  => "search",
          "_meta" => {"ui" => {"visibility" => ["model"]}},
        },
      ],
    }.to_json)
    status.source.should eq("sdk")
    status.tools.try(&.first.meta.try(&.["ui"].as_h["visibility"].as_a.first.as_s)).should eq("model")

    usage = ClaudeAgent::ContextUsageResponse.from_json({
      "categories" => [
        {"id" => "mcp_instructions", "kind" => "used", "name" => "MCP Instructions", "tokens" => 500},
      ],
      "totalTokens"          => 500,
      "maxTokens"            => 200_000,
      "rawMaxTokens"         => 200_000,
      "percentage"           => 0.25,
      "model"                => "claude-opus-5-5",
      "isAutoCompactEnabled" => true,
      "memoryFiles"          => [] of String,
      "mcpTools"             => [] of String,
      "mcpInstructions"      => [{"serverName" => "docs", "tokens" => 500}],
      "agents"               => [] of String,
    }.to_json)
    usage.categories.first.id.should eq("mcp_instructions")
    usage.categories.first.kind.should eq("used")
    usage.mcp_instructions.try(&.first.as_h["serverName"].as_s).should eq("docs")
  end
end
