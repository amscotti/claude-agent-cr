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

  describe ".finish_query (Python 0.2.140 ResultError parity)" do
    it "returns a successful result unchanged" do
      message = ClaudeAgent::Message.parse(
        %({"type": "result", "uuid": "u-1", "session_id": "s-1", "subtype": "success"})
      ).as(ClaudeAgent::ResultMessage)

      ClaudeAgent.finish_query(message).uuid.should eq("u-1")
    end

    it "raises ResultError for an error result" do
      message = ClaudeAgent::Message.parse(
        %({"type": "result", "uuid": "u-1", "session_id": "s-1", ) +
        %("subtype": "error_max_turns", "is_error": true, "errors": ["too many turns"]})
      ).as(ClaudeAgent::ResultMessage)

      expect_raises(ClaudeAgent::ResultError, "too many turns") do
        ClaudeAgent.finish_query(message)
      end
    end

    it "raises ResultError as a ProcessError for rescue compatibility" do
      message = ClaudeAgent::Message.parse(
        %({"type": "result", "uuid": "u-1", "session_id": "s-1", "subtype": "success", "is_error": true})
      ).as(ClaudeAgent::ResultMessage)

      expect_raises(ClaudeAgent::ProcessError, "unknown error") do
        ClaudeAgent.finish_query(message)
      end
    end

    it "raises Error when no result was received" do
      expect_raises(ClaudeAgent::Error, "No result message received") do
        ClaudeAgent.finish_query(nil)
      end
    end
  end
end
