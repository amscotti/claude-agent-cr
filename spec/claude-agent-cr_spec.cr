require "./spec_helper"

describe ClaudeAgent do
  it "has a version" do
    ClaudeAgent::VERSION.should_not be_nil
  end

  it "can initialize options" do
    options = ClaudeAgent::AgentOptions.new(
      model: "claude-opus-4-5-20251101",
      max_turns: 10
    )
    options.model.should eq("claude-opus-4-5-20251101")
    options.max_turns.should eq(10)
  end
end
