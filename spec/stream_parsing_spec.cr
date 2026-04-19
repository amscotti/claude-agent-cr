require "./spec_helper"

# ---------------------------------------------------------------------------
# Stream parsing edge cases for CLIClient#each_message.
#
# Equivalent to Python's `test_subprocess_buffering.py`: we feed canned
# stream-json payloads through the real message pipeline without spawning a
# subprocess. Guards the parser against the silent-data-loss classes of bugs
# that plagued older SDK releases (multi-JSON lines, embedded newlines,
# malformed payloads, oversize lines).
# ---------------------------------------------------------------------------

private def collect_messages(stream : String, options = nil) : {Array(ClaudeAgent::Message), Array(String)}
  stderr_lines = [] of String
  opts = options || ClaudeAgent::AgentOptions.new(
    stderr: ->(line : String) { stderr_lines << line },
  )

  client = ClaudeAgent::CLIClient.new(opts)
  client.set_output_for_test(IO::Memory.new(stream))

  messages = [] of ClaudeAgent::Message
  client.each_message do |message|
    messages << message
  end

  {messages, stderr_lines}
end

describe "CLIClient stream parsing" do
  describe "line-oriented JSON" do
    it "parses a single well-formed stream-json line" do
      stream = {
        "type"       => JSON::Any.new("system"),
        "subtype"    => JSON::Any.new("init"),
        "session_id" => JSON::Any.new("s-1"),
      }.to_json + "\n"

      messages, errors = collect_messages(stream)
      messages.size.should eq(1)
      messages.first.should be_a(ClaudeAgent::InitMessage)
      errors.should be_empty
    end

    it "parses multiple JSON objects separated by newlines" do
      m1 = {"type" => "system", "subtype" => "init", "session_id" => "s-1"}.to_json
      m2 = {
        "type"       => "assistant",
        "uuid"       => "u-1",
        "session_id" => "s-1",
        "message"    => {"content" => [{"type" => "text", "text" => "ok"}], "model" => "claude"},
      }.to_json
      m3 = {
        "type"            => "result",
        "uuid"            => "u-2",
        "session_id"      => "s-1",
        "subtype"         => "success",
        "duration_ms"     => 10,
        "duration_api_ms" => 5,
        "num_turns"       => 1,
      }.to_json

      messages, errors = collect_messages([m1, m2, m3].join('\n') + "\n")

      messages.size.should eq(3)
      messages[0].should be_a(ClaudeAgent::InitMessage)
      messages[1].should be_a(ClaudeAgent::AssistantMessage)
      messages[2].should be_a(ClaudeAgent::ResultMessage)
      errors.should be_empty
    end

    it "skips empty lines between JSON messages" do
      m1 = {"type" => "system", "subtype" => "init", "session_id" => "s-1"}.to_json
      m2 = {"type" => "system", "subtype" => "status", "status" => "requesting",
            "session_id" => "s-1", "uuid" => "u-2"}.to_json

      # Whitespace-only lines and multiple consecutive newlines should not
      # produce spurious parse errors.
      stream = "\n" + m1 + "\n\n   \n" + m2 + "\n\n"

      messages, errors = collect_messages(stream)
      messages.size.should eq(2)
      errors.should be_empty
    end

    it "handles the final line without a trailing newline" do
      m1 = {"type" => "system", "subtype" => "init", "session_id" => "s-1"}.to_json
      stream = m1 # no trailing \n

      messages, errors = collect_messages(stream)
      messages.size.should eq(1)
      errors.should be_empty
    end
  end

  describe "embedded newline / escape handling" do
    it "preserves \\n escape sequences inside JSON string values" do
      content = "line 1\nline 2\nline 3"
      payload = {
        "type"       => "assistant",
        "uuid"       => "u-1",
        "session_id" => "s-1",
        "message"    => {
          "content" => [{"type" => "text", "text" => content}],
          "model"   => "claude",
        },
      }.to_json

      messages, errors = collect_messages(payload + "\n")
      messages.size.should eq(1)
      errors.should be_empty

      assistant = messages.first.as(ClaudeAgent::AssistantMessage)
      assistant.text.should eq(content)
      assistant.text.should contain("\n")
    end

    it "parses UTF-8 multibyte content correctly" do
      payload = {
        "type"       => "assistant",
        "uuid"       => "u-1",
        "session_id" => "s-1",
        "message"    => {
          "content" => [{"type" => "text", "text" => "日本語 · 🎉 · ñandú"}],
          "model"   => "claude",
        },
      }.to_json

      messages, _ = collect_messages(payload + "\n")
      messages.first.as(ClaudeAgent::AssistantMessage).text.should eq("日本語 · 🎉 · ñandú")
    end
  end

  describe "malformed input recovery" do
    it "logs malformed lines without stopping the stream" do
      good1 = {"type" => "system", "subtype" => "init", "session_id" => "s-1"}.to_json
      bad = %({"type": "system", "subtype": "init", malformed)
      good2 = {"type" => "system", "subtype" => "status", "status" => "requesting",
               "session_id" => "s-1", "uuid" => "u-2"}.to_json

      messages, errors = collect_messages([good1, bad, good2].join('\n') + "\n")

      messages.size.should eq(2)
      errors.any?(&.includes?("Failed to parse")).should be_true
      errors.any?(&.includes?("malformed")).should be_true
    end

    it "preserves the offending line in the JSONDecodeError payload (truncated to 500 chars)" do
      # Build a malformed line longer than 500 chars to exercise truncation.
      oversize = "x" * 600
      bad = %({"type": "system", "subtype": "init", "junk": "#{oversize}")
      messages, errors = collect_messages(bad + "\n")

      messages.should be_empty
      diag = errors.find(&.includes?("raw:"))
      diag.should_not be_nil
      diag.try(&.includes?("…").should(be_true))
    end

    it "tolerates JSON with unknown top-level type by returning UnknownMessage" do
      payload = {
        "type"       => "brand_new_type",
        "uuid"       => "u-1",
        "session_id" => "s-1",
        "payload"    => {"foo" => "bar"},
      }.to_json

      messages, errors = collect_messages(payload + "\n")
      messages.size.should eq(1)
      messages.first.should be_a(ClaudeAgent::UnknownMessage)
      errors.should be_empty
    end

    it "tolerates JSON with unknown system subtype as GenericSystemMessage" do
      payload = {
        "type"       => "system",
        "subtype"    => "brand_new_subtype",
        "session_id" => "s-1",
        "extras"     => {"anything" => 42},
      }.to_json

      messages, errors = collect_messages(payload + "\n")
      messages.size.should eq(1)
      messages.first.should be_a(ClaudeAgent::GenericSystemMessage)
      errors.should be_empty
    end
  end

  describe "scale" do
    it "parses a very large assistant message (~1 MiB payload)" do
      # ~1 MiB of repeated text. Ensures the Crystal IO#each_line pipeline
      # does not choke on large single-line JSON.
      big = "x" * (1024 * 1024)
      payload = {
        "type"       => "assistant",
        "uuid"       => "u-big",
        "session_id" => "s-1",
        "message"    => {
          "content" => [{"type" => "text", "text" => big}],
          "model"   => "claude",
        },
      }.to_json

      messages, errors = collect_messages(payload + "\n")
      messages.size.should eq(1)
      errors.should be_empty
      messages.first.as(ClaudeAgent::AssistantMessage).text.size.should eq(big.size)
    end

    it "parses 100 sequential messages without dropping any" do
      lines = (1..100).map do |index|
        {
          "type"       => JSON::Any.new("system"),
          "subtype"    => JSON::Any.new("status"),
          "status"     => JSON::Any.new("requesting"),
          "session_id" => JSON::Any.new("s-1"),
          "uuid"       => JSON::Any.new("u-#{index}"),
        }.to_json
      end

      messages, errors = collect_messages(lines.join('\n') + "\n")
      messages.size.should eq(100)
      errors.should be_empty
    end
  end
end
