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
