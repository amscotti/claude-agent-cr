require "./spec_helper"

describe ClaudeAgent::QueryIterator do
  describe "#initialize" do
    it "initializes with prompt and nil options" do
      iterator = ClaudeAgent::QueryIterator.new("test prompt", nil)
      iterator.should be_a(Iterator(ClaudeAgent::Message))
    end

    it "initializes with prompt and options" do
      options = ClaudeAgent::AgentOptions.new(model: "claude-sonnet-4-20250514")
      iterator = ClaudeAgent::QueryIterator.new("test prompt", options)
      iterator.should be_a(Iterator(ClaudeAgent::Message))
    end
  end

  describe "Iterator interface" do
    it "implements Iterator(Message)" do
      iterator = ClaudeAgent::QueryIterator.new("test", nil)

      # Verify it has the next method (required by Iterator)
      iterator.responds_to?(:next).should be_true
    end
  end
end

describe "ClaudeAgent.query" do
  describe "iterator-based interface" do
    it "returns a QueryIterator" do
      result = ClaudeAgent.query("test prompt")
      result.should be_a(ClaudeAgent::QueryIterator)
    end

    it "returns a QueryIterator with options" do
      options = ClaudeAgent::AgentOptions.new(model: "claude-sonnet-4-20250514")
      result = ClaudeAgent.query("test prompt", options)
      result.should be_a(ClaudeAgent::QueryIterator)
    end
  end
end
