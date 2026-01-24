require "./spec_helper"

describe ClaudeAgent::StreamingSession do
  it "initializes with default options" do
    session = ClaudeAgent::StreamingSession.new
    session.running?.should be_false
    session.session_id.should be_nil
  end

  it "initializes with custom options" do
    options = ClaudeAgent::AgentOptions.new(
      system_prompt: "Test prompt",
      max_turns: 5
    )
    session = ClaudeAgent::StreamingSession.new(options)
    session.running?.should be_false
  end

  it "raises error when sending without starting" do
    session = ClaudeAgent::StreamingSession.new
    expect_raises(ClaudeAgent::Error, "Session not started") do
      session.send("Hello")
    end
  end

  # Note: Integration tests requiring actual CLI would go here,
  # but are skipped in unit tests to avoid external dependencies
end
