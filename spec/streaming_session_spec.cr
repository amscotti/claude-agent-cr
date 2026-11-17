require "./spec_helper"

private class StreamingSpecMockCLIClient < ClaudeAgent::CLIClient
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

  def send_user_message(
    content : String,
    parent_tool_use_id : String? = nil,
    *,
    uuid : String? = nil,
    should_query : Bool = true,
  )
  end
end

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

  it "drops sdk_host_only and keep_alive frames while delivering public state frames" do
    lines = [
      {
        "type"          => "system",
        "subtype"       => "session_state_changed",
        "session_id"    => "s-1",
        "state"         => "running",
        "sdk_host_only" => true,
      }.to_json,
      {"type" => "keep_alive", "startup_mark" => "init"}.to_json,
      {
        "type"          => "system",
        "subtype"       => "session_state_changed",
        "session_id"    => "s-1",
        "state"         => "idle",
        "sdk_host_only" => false,
      }.to_json,
      {
        "type"       => "result",
        "uuid"       => "r-stream-1",
        "session_id" => "s-1",
        "subtype"    => "success",
      }.to_json,
    ].join('\n') + "\n"

    mock_cli = StreamingSpecMockCLIClient.new(lines)
    session = ClaudeAgent::StreamingSession.new(nil, mock_cli)
    received = [] of ClaudeAgent::Message

    begin
      session.start
      session.send("hi")
      session.each_message { |msg| received << msg }
    ensure
      session.close
    end

    received.size.should eq(2)
    received[0].as(ClaudeAgent::SessionStateChangedMessage).state.should eq("idle")
    received[1].as(ClaudeAgent::ResultMessage).uuid.should eq("r-stream-1")
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
