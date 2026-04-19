require "./spec_helper"

# ---------------------------------------------------------------------------
# Mocked integration tests — the Crystal analogue of Python's
# `tests/test_integration.py`.
#
# These run on every `crystal spec` invocation (no `CLAUDE_AGENT_RUN_E2E`
# gate), exercise the full SDK pipeline end-to-end by injecting a canned
# stream-json transcript through the real `CLIClient`, and verify the
# message dispatch, session_id capture, and iterator wiring.
#
# Live-CLI coverage still lives in `spec/e2e_spec.cr` (gated); this file
# catches the regressions that don't require a real Claude Code install.
# ---------------------------------------------------------------------------

# Turn an array of JSON-serializable hashes into a stream-json blob.
private def transcript(entries : Array(Hash(String, JSON::Any))) : String
  entries.map(&.to_json).join('\n') + "\n"
end

private def json(value) : JSON::Any
  JSON::Any.new(value)
end

private def sjson(**key_values) : Hash(String, JSON::Any)
  hash = {} of String => JSON::Any
  key_values.each do |k, v|
    hash[k.to_s] = v.is_a?(JSON::Any) ? v.as(JSON::Any) : JSON::Any.new(v)
  end
  hash
end

# Minimal mock that overrides `start` and `stop` so tests don't spawn a
# subprocess, while still exercising the real `each_message` path.
private class MockCLIClient < ClaudeAgent::CLIClient
  property? started : Bool = false
  getter sent_messages : Array(String) = [] of String

  def initialize(@stream : String, options : ClaudeAgent::AgentOptions? = nil)
    super(options)
    set_output_for_test(IO::Memory.new(@stream))
  end

  def start
    @started = true
  end

  def stop
    @started = false
  end

  def send_json(message)
    @sent_messages << message.to_json
  end

  def send_prompt(prompt : String, parent_tool_use_id : String? = nil, *, uuid : String? = nil, should_query : Bool = true)
    payload = {
      "type"               => JSON::Any.new("user"),
      "parent_tool_use_id" => parent_tool_use_id ? JSON::Any.new(parent_tool_use_id) : JSON::Any.new(nil),
      "message"            => JSON::Any.new({
        "role"    => JSON::Any.new("user"),
        "content" => JSON::Any.new(prompt),
      }),
    }
    payload["uuid"] = JSON::Any.new(uuid) if uuid
    payload["shouldQuery"] = JSON::Any.new(false) unless should_query
    @sent_messages << payload.to_json
  end

  def send_user_message(content, parent_tool_use_id = nil, *, uuid = nil, should_query = true)
    send_prompt(content, parent_tool_use_id, uuid: uuid, should_query: should_query)
  end

  def send_control_response(response)
    @sent_messages << {"type" => response.type, "response" => response.response}.to_json
  end
end

describe "ClaudeAgent integration (mocked)" do
  describe "query + result pipeline" do
    it "yields AssistantMessage then ResultMessage for a simple query" do
      stream = transcript([
        sjson(type: "system", subtype: "init", session_id: "s-1"),
        sjson(
          type: "assistant",
          uuid: "u-1",
          session_id: "s-1",
          message: json({
            "content" => json([json({
              "type" => json("text"),
              "text" => json("2 + 2 equals 4"),
            })]),
            "model" => json("claude-opus-4-7"),
          }),
        ),
        sjson(
          type: "result",
          uuid: "u-2",
          session_id: "s-1",
          subtype: "success",
          duration_ms: 100_i64,
          duration_api_ms: 80_i64,
          num_turns: 1,
          total_cost_usd: 0.001,
        ),
      ])

      cli = MockCLIClient.new(stream)
      received = [] of ClaudeAgent::Message
      cli.each_message { |msg| received << msg }

      received.size.should eq(3)
      received[0].should be_a(ClaudeAgent::InitMessage)
      received[1].should be_a(ClaudeAgent::AssistantMessage)
      received[2].should be_a(ClaudeAgent::ResultMessage)

      assistant = received[1].as(ClaudeAgent::AssistantMessage)
      assistant.text.should eq("2 + 2 equals 4")
      assistant.model.should eq("claude-opus-4-7")

      result = received[2].as(ClaudeAgent::ResultMessage)
      result.subtype.should eq("success")
      result.total_cost_usd.should eq(0.001)
      result.session_id.should eq("s-1")
    end

    it "captures session_id from system/init" do
      stream = transcript([
        sjson(type: "system", subtype: "init", session_id: "captured-session"),
      ])

      cli = MockCLIClient.new(stream)
      cli.each_message { |_msg| }
      cli.session_id.should eq("captured-session")
    end

    it "falls back to assistant.session_id when system/init is absent" do
      stream = transcript([
        sjson(
          type: "assistant",
          uuid: "u-1",
          session_id: "fallback-session",
          message: json({
            "content" => json([json({"type" => json("text"), "text" => json("hi")})]),
            "model"   => json("c"),
          }),
        ),
      ])

      cli = MockCLIClient.new(stream)
      cli.each_message { |_msg| }
      cli.session_id.should eq("fallback-session")
    end
  end

  describe "tool-use flow" do
    it "parses a tool_use block inside an assistant message" do
      stream = transcript([
        sjson(
          type: "assistant",
          uuid: "u-1",
          session_id: "s-1",
          message: json({
            "content" => json([
              json({"type" => json("text"), "text" => json("Let me read that file.")}),
              json({
                "type"  => json("tool_use"),
                "id"    => json("tool-abc"),
                "name"  => json("Read"),
                "input" => json({"file_path" => json("/tmp/x.txt")}),
              }),
            ]),
            "model" => json("claude"),
          }),
        ),
      ])

      cli = MockCLIClient.new(stream)
      assistant = nil.as(ClaudeAgent::AssistantMessage?)
      cli.each_message do |msg|
        assistant = msg if msg.is_a?(ClaudeAgent::AssistantMessage)
      end

      assistant.should_not be_nil
      assistant.try do |message|
        message.content.size.should eq(2)
        tool_use = message.content[1].as(ClaudeAgent::ToolUseBlock)
        tool_use.id.should eq("tool-abc")
        tool_use.name.should eq("Read")
        tool_use.input["file_path"].as_s.should eq("/tmp/x.txt")
      end
    end

    it "parses tool_result blocks and ResultMessage with error subtype" do
      stream = transcript([
        sjson(
          type: "user",
          uuid: "u-user-1",
          session_id: "s-1",
          message: json({
            "role"    => json("user"),
            "content" => json([
              json({
                "type"        => json("tool_result"),
                "tool_use_id" => json("tool-abc"),
                "content"     => json("file contents"),
                "is_error"    => json(false),
              }),
            ]),
          }),
        ),
        sjson(
          type: "result",
          uuid: "u-res",
          session_id: "s-1",
          subtype: "error_max_budget_usd",
          duration_ms: 50_i64,
          duration_api_ms: 40_i64,
          num_turns: 1,
          total_cost_usd: 0.0002,
          is_error: false,
        ),
      ])

      cli = MockCLIClient.new(stream)
      messages = [] of ClaudeAgent::Message
      cli.each_message { |msg| messages << msg }

      result = messages.last.as(ClaudeAgent::ResultMessage)
      result.subtype.should eq("error_max_budget_usd")
      result.total_cost_usd.should eq(0.0002)
    end
  end

  describe "control-protocol messages" do
    it "surfaces rate_limit_event as a typed RateLimitEvent" do
      stream = transcript([
        sjson(
          type: "rate_limit_event",
          uuid: "u-rl",
          session_id: "s-1",
          rate_limit_info: json({
            "status"        => json("allowed_warning"),
            "resetsAt"      => json(1_700_000_000_i64),
            "rateLimitType" => json("five_hour"),
            "utilization"   => json(0.85),
          }),
        ),
      ])

      cli = MockCLIClient.new(stream)
      msg = nil.as(ClaudeAgent::Message?)
      cli.each_message { |message| msg = message }

      event = msg.as(ClaudeAgent::RateLimitEvent)
      info = event.rate_limit_info
      info.status.should eq("allowed_warning")
      info.rate_limit_type.should eq("five_hour")
      info.utilization.should eq(0.85)
    end

    it "parses system/api_retry messages with typed attempt fields" do
      stream = transcript([
        sjson(
          type: "system",
          subtype: "api_retry",
          session_id: "s-1",
          uuid: "u-retry",
          attempt: 2_i64,
          max_retries: 3_i64,
          delay_ms: 500_i64,
          status: 429_i64,
          error: "rate_limited",
        ),
      ])

      cli = MockCLIClient.new(stream)
      msg = nil.as(ClaudeAgent::Message?)
      cli.each_message { |message| msg = message }

      retry = msg.as(ClaudeAgent::ApiRetryMessage)
      retry.attempt.should eq(2)
      retry.max_retries.should eq(3)
      retry.delay_ms.should eq(500)
      retry.status.should eq(429)
      retry.error.should eq("rate_limited")
    end

    it "parses system/memory_recall messages with typed Hash(String, String) paths" do
      stream = transcript([
        sjson(
          type: "system",
          subtype: "memory_recall",
          session_id: "s-1",
          uuid: "u-mem",
          memory_paths: json({
            "auto"    => json("/tmp/auto"),
            "project" => json("/tmp/proj"),
          }),
        ),
      ])

      cli = MockCLIClient.new(stream)
      msg = nil.as(ClaudeAgent::Message?)
      cli.each_message { |message| msg = message }

      recall = msg.as(ClaudeAgent::MemoryRecallMessage)
      recall.memory_paths.should eq({"auto" => "/tmp/auto", "project" => "/tmp/proj"})
    end

    it "parses top-level mirror_error messages" do
      stream = transcript([
        sjson(
          type: "mirror_error",
          uuid: "u-mirror",
          session_id: "s-1",
          error: "store append failed",
        ),
      ])

      cli = MockCLIClient.new(stream)
      msg = nil.as(ClaudeAgent::Message?)
      cli.each_message { |message| msg = message }

      mirror = msg.as(ClaudeAgent::MirrorErrorMessage)
      mirror.session_id.should eq("s-1")
      mirror.error.should eq("store append failed")
    end
  end

  describe "error handling surfaces to the caller" do
    it "raises CLINotFoundError when the cli_path does not exist" do
      options = ClaudeAgent::AgentOptions.new(
        cli_path: "/nonexistent/path/to/claude-cli-#{Random.rand(1_000_000)}",
      )

      expect_raises(ClaudeAgent::CLINotFoundError) do
        client = ClaudeAgent::CLIClient.new(options)
        client.start
        client.stop
      end
    end

    it "malformed stream-json lines route through the stderr callback" do
      captured = [] of String
      options = ClaudeAgent::AgentOptions.new(
        stderr: ->(line : String) { captured << line },
      )

      good = sjson(type: "system", subtype: "init", session_id: "s-1").to_json
      bad = %({"not": closed)

      cli = MockCLIClient.new([good, bad, good].join('\n') + "\n", options)
      messages = [] of ClaudeAgent::Message
      cli.each_message { |message| messages << message }

      messages.size.should eq(2)
      captured.any?(&.includes?("Failed to parse")).should be_true
    end
  end

  describe "QueryIterator surfacing" do
    it "re-raises background-fiber errors instead of silently stopping" do
      options = ClaudeAgent::AgentOptions.new(
        cli_path: "/nonexistent/claude-does-not-exist-#{Random.rand(1_000_000)}",
      )
      iterator = ClaudeAgent::QueryIterator.new("hi", options)

      expect_raises(ClaudeAgent::CLINotFoundError) do
        iterator.next
      end
    end
  end
end
