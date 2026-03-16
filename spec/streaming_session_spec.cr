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

  it "does not raise when close is called without start" do
    session = ClaudeAgent::StreamingSession.new
    session.close
    session.running?.should be_false
  end

  it "does not raise when close is called twice" do
    session = ClaudeAgent::StreamingSession.new
    session.close
    session.close
    session.running?.should be_false
  end
end

describe ClaudeAgent::QueryIterator do
  it "initializes without starting" do
    iterator = ClaudeAgent::QueryIterator.new("hello", nil)
    iterator.should be_a(Iterator(ClaudeAgent::Message))
  end

  it "can be closed before starting" do
    iterator = ClaudeAgent::QueryIterator.new("hello", nil)
    iterator.close
  end
end
