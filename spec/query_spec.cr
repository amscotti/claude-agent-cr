require "./spec_helper"

private class QuerySpecMockCLIClient < ClaudeAgent::CLIClient
  def initialize(stream : String, options : ClaudeAgent::AgentOptions? = nil)
    super(options)
    set_output_for_test(IO::Memory.new(stream))
  end

  def start
  end

  def stop
  end

  def send_prompt(
    prompt : String,
    parent_tool_use_id : String? = nil,
    *,
    uuid : String? = nil,
    should_query : Bool = true,
  )
  end
end

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

  describe "sdk_host_only and keep_alive filtering" do
    it "drops sdk_host_only and keep_alive frames in ClaudeAgent.query while forwarding public state frames" do
      lines = [
        {
          "type"          => "system",
          "subtype"       => "session_state_changed",
          "session_id"    => "s-1",
          "state"         => "running",
          "sdk_host_only" => true,
        }.to_json,
        {"type" => "keep_alive", "startup_mark" => "hook"}.to_json,
        {
          "type"          => "system",
          "subtype"       => "session_state_changed",
          "session_id"    => "s-1",
          "state"         => "requires_action",
          "sdk_host_only" => false,
        }.to_json,
        {
          "type"            => "result",
          "uuid"            => "r-1",
          "session_id"      => "s-1",
          "subtype"         => "success",
          "duration_ms"     => 10,
          "duration_api_ms" => 5,
          "num_turns"       => 1,
        }.to_json,
      ].join('\n') + "\n"

      mock_cli = QuerySpecMockCLIClient.new(lines)
      received = [] of ClaudeAgent::Message
      result = ClaudeAgent.query("hello", cli_client: mock_cli) do |msg|
        received << msg
      end

      result.uuid.should eq("r-1")
      received.size.should eq(2)
      state_msg = received[0].as(ClaudeAgent::SessionStateChangedMessage)
      state_msg.state.should eq("requires_action")
      state_msg.sdk_host_only?.should be_false
      received[1].should be_a(ClaudeAgent::ResultMessage)
    end

    it "drops sdk_host_only and keep_alive frames in QueryIterator" do
      lines = [
        {
          "type"          => "system",
          "subtype"       => "session_state_changed",
          "session_id"    => "s-1",
          "state"         => "running",
          "sdk_host_only" => true,
        }.to_json,
        {"type" => "keep_alive"}.to_json,
        {
          "type"          => "system",
          "subtype"       => "session_state_changed",
          "session_id"    => "s-1",
          "state"         => "idle",
          "sdk_host_only" => false,
        }.to_json,
        {
          "type"       => "result",
          "uuid"       => "r-2",
          "session_id" => "s-1",
          "subtype"    => "success",
        }.to_json,
      ].join('\n') + "\n"

      mock_cli = QuerySpecMockCLIClient.new(lines)
      iterator = ClaudeAgent::QueryIterator.new("hello", nil, mock_cli)
      received = iterator.to_a

      received.size.should eq(2)
      received[0].as(ClaudeAgent::SessionStateChangedMessage).state.should eq("idle")
      received[1].as(ClaudeAgent::ResultMessage).uuid.should eq("r-2")
    end
  end
end
