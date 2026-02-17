require "./spec_helper"

describe ClaudeAgent::HookMatcher do
  it "matches tool names" do
    matcher = ClaudeAgent::HookMatcher.new(matcher: "Bash")
    matcher.matches?("Bash").should be_true
    matcher.matches?("Read").should be_false
  end

  it "matches regex" do
    matcher = ClaudeAgent::HookMatcher.new(matcher: "^Bash.*")
    matcher.matches?("Bash").should be_true
    matcher.matches?("BashCommand").should be_true
    matcher.matches?("Read").should be_false
  end
end

describe ClaudeAgent::ControlHookCallbackRequest do
  it "parses hook_callback control request" do
    json = %({"subtype": "hook_callback", "hook": "pre_compact", "input": {"key": "value"}})
    req = ClaudeAgent::ControlHookCallbackRequest.from_json(json)
    req.subtype.should eq("hook_callback")
    req.hook.should eq("pre_compact")
    req.input.should_not be_nil
    req.input.try(&.["key"].as_s.should eq("value"))
  end

  it "parses hook_callback without input" do
    json = %({"subtype": "hook_callback", "hook": "pre_compact"})
    req = ClaudeAgent::ControlHookCallbackRequest.from_json(json)
    req.hook.should eq("pre_compact")
    req.input.should be_nil
  end
end

describe ClaudeAgent::HookResult do
  it "creates allow result" do
    res = ClaudeAgent::HookResult.allow
    res.hook_specific_output.should be_nil
  end

  it "creates deny result" do
    res = ClaudeAgent::HookResult.deny("Bad tool")
    output = res.hook_specific_output
    output.should_not be_nil
    if output
      output.permission_decision.should eq("deny")
      output.permission_decision_reason.should eq("Bad tool")
    end
  end
end

describe ClaudeAgent::HookConfig do
  it "supports notification hook" do
    config = ClaudeAgent::HookConfig.new(
      notification: [->(_input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
        ClaudeAgent::HookResult.allow
      }]
    )
    config.notification.should_not be_nil
    config.notification.try(&.size).should eq(1)
  end

  it "supports pre_compact hook" do
    config = ClaudeAgent::HookConfig.new(
      pre_compact: [->(_input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
        ClaudeAgent::HookResult.allow
      }]
    )
    config.pre_compact.should_not be_nil
  end
end

describe ClaudeAgent::HookInput do
  it "supports notification fields" do
    input = ClaudeAgent::HookInput.new(
      notification_message: "Agent status update",
      notification_title: "Status"
    )
    input.notification_message.should eq("Agent status update")
    input.notification_title.should eq("Status")
  end

  it "supports pre_compact fields" do
    input = ClaudeAgent::HookInput.new(
      trigger: "manual",
      custom_instructions: "Focus on key context"
    )
    input.trigger.should eq("manual")
    input.custom_instructions.should eq("Focus on key context")
  end
end
