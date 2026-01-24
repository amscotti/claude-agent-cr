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
  end
end
