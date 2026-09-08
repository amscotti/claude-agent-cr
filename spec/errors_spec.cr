require "./spec_helper"

# Coverage for every error class declared in `src/claude_agent/errors.cr`:
# construction, default message, custom accessors, inheritance. Mirrors
# Python's `tests/test_errors.py`.

describe ClaudeAgent::Error do
  it "is a plain Exception subclass callers can rescue as the base" do
    error = ClaudeAgent::Error.new("something broke")
    error.should be_a(Exception)
    error.message.should eq("something broke")
  end

  it "lets every typed error also be caught via the base class" do
    # A representative sample of concrete subclasses must all descend from
    # ClaudeAgent::Error so the docs' "catch-all" pattern really works.
    {
      ClaudeAgent::CLINotFoundError.new,
      ClaudeAgent::ConnectionError.new("x"),
      ClaudeAgent::ProcessError.new("x"),
      ClaudeAgent::ResultError.new("x"),
      ClaudeAgent::JSONDecodeError.new("x", "raw"),
      ClaudeAgent::TimeoutError.new("x"),
      ClaudeAgent::ConfigurationError.new("x"),
      ClaudeAgent::UnsupportedOptionError.new("--foo"),
    }.each do |err|
      err.should be_a(ClaudeAgent::Error)
    end
  end
end

describe ClaudeAgent::CLINotFoundError do
  it "uses a helpful default message" do
    error = ClaudeAgent::CLINotFoundError.new
    error.message.should eq("Claude Code CLI not found")
    error.cli_path.should be_nil
  end

  it "carries the resolved cli_path for diagnostics" do
    error = ClaudeAgent::CLINotFoundError.new("nope", "/opt/claude")
    error.cli_path.should eq("/opt/claude")
    error.message.should eq("nope")
  end
end

describe ClaudeAgent::ProcessError do
  it "exposes exit_code and stderr for diagnostics" do
    error = ClaudeAgent::ProcessError.new(
      "subprocess failed",
      exit_code: 137,
      stderr: "killed by signal",
    )
    error.message.should eq("subprocess failed")
    error.exit_code.should eq(137)
    error.stderr.should eq("killed by signal")
  end

  it "accepts optional diagnostics" do
    error = ClaudeAgent::ProcessError.new("minimal")
    error.exit_code.should be_nil
    error.stderr.should be_nil
  end
end

describe ClaudeAgent::JSONDecodeError do
  it "preserves the raw payload for replay" do
    error = ClaudeAgent::JSONDecodeError.new(
      "unexpected token",
      %({"broken":),
    )
    error.message.should eq("unexpected token")
    error.raw_data.should eq(%({"broken":))
  end
end

describe ClaudeAgent::UnsupportedOptionError do
  it "builds a default message that names the offending option" do
    error = ClaudeAgent::UnsupportedOptionError.new("--title", cli_path: "/opt/claude")
    error.option.should eq("--title")
    error.cli_path.should eq("/opt/claude")
    error.message.to_s.should contain("--title")
    error.message.to_s.should contain("Upgrade the CLI")
  end

  it "honors an explicit custom message" do
    error = ClaudeAgent::UnsupportedOptionError.new(
      "--task-budget",
      message: "this CLI predates task budgets",
      cli_path: "/opt/claude-old",
    )
    error.message.should eq("this CLI predates task budgets")
  end
end

describe ClaudeAgent::ConfigurationError do
  it "is a plain Error subclass that carries a custom message" do
    error = ClaudeAgent::ConfigurationError.new("invalid combination of foo and bar")
    error.should be_a(ClaudeAgent::Error)
    error.message.should eq("invalid combination of foo and bar")
  end
end

describe ClaudeAgent::TimeoutError do
  it "is a plain Error subclass with a custom message" do
    error = ClaudeAgent::TimeoutError.new("control request timed out")
    error.should be_a(ClaudeAgent::Error)
    error.message.should eq("control request timed out")
  end
end

private def error_result_json(
  subtype : String = "error_max_turns",
  errors : String? = nil,
  result : String? = nil,
  api_error_status : Int64? = nil,
  terminal_reason : String? = nil,
) : String
  payload = {
    "type"       => JSON::Any.new("result"),
    "uuid"       => JSON::Any.new("u-err"),
    "session_id" => JSON::Any.new("sess-1"),
    "subtype"    => JSON::Any.new(subtype),
    "is_error"   => JSON::Any.new(true),
  } of String => JSON::Any
  payload["errors"] = JSON::Any.new([JSON::Any.new(errors)]) if errors
  payload["result"] = JSON::Any.new(result) if result
  payload["api_error_status"] = JSON::Any.new(api_error_status) if api_error_status
  payload["terminal_reason"] = JSON::Any.new(terminal_reason) if terminal_reason
  payload.to_json
end

private def parse_error_result(**options) : ClaudeAgent::ResultMessage
  message = ClaudeAgent::Message.parse(error_result_json(**options))
  message.should be_a(ClaudeAgent::ResultMessage)
  message.as(ClaudeAgent::ResultMessage)
end

describe ClaudeAgent::ResultError do
  it "is a ProcessError so existing handlers keep working" do
    error = ClaudeAgent::ResultError.new("boom")
    error.should be_a(ClaudeAgent::ProcessError)
    error.should be_a(ClaudeAgent::Error)
    error.exit_code.should be_nil
    error.errors.should eq([] of String)
  end

  it "carries the structured payload from a data hash" do
    data = {
      "subtype"          => JSON::Any.new("error_during_execution"),
      "errors"           => JSON::Any.new([JSON::Any.new("  bad tool  "), JSON::Any.new(42)]),
      "result"           => JSON::Any.new("partial"),
      "api_error_status" => JSON::Any.new(529_i64),
      "terminal_reason"  => JSON::Any.new("api_error"),
      "session_id"       => JSON::Any.new("sess-9"),
    } of String => JSON::Any

    error = ClaudeAgent::ResultError.new("failed", data, exit_code: 1)
    error.subtype.should eq("error_during_execution")
    error.errors.should eq(["bad tool"])
    error.result_text.should eq("partial")
    error.api_error_status.should eq(529)
    error.terminal_reason.should eq("api_error")
    error.session_id.should eq("sess-9")
    error.exit_code.should eq(1)
    error.data.should eq(data)
  end

  it "prefers errors[] for the message text" do
    result = parse_error_result(errors: "max turns hit")
    error = ClaudeAgent::ResultError.from_result(result)
    (error.message || "").should contain("max turns hit")
    error.subtype.should eq("error_max_turns")
  end

  it "falls back to result prose for API failures with a success subtype" do
    result = parse_error_result(subtype: "success", result: "API Error: overloaded")
    error = ClaudeAgent::ResultError.from_result(result)
    (error.message || "").should contain("API Error: overloaded")
    (error.message || "").should_not contain("error result: success")
  end

  it "falls back to a non-success subtype, then the HTTP status" do
    subtype_error = ClaudeAgent::ResultError.from_result(parse_error_result(subtype: "error_during_execution"))
    (subtype_error.message || "").should contain("error_during_execution")

    status_error = ClaudeAgent::ResultError.from_result(
      parse_error_result(subtype: "success", api_error_status: 529_i64)
    )
    (status_error.message || "").should contain("HTTP 529")
  end

  it "reports unknown error when the payload has no signal" do
    error = ClaudeAgent::ResultError.from_result(parse_error_result(subtype: "success"))
    (error.message || "").should contain("unknown error")
  end

  it "normalizes bare-string and mixed errors payloads" do
    ClaudeAgent::ResultError.normalize_errors(JSON::Any.new("solo")).should eq(["solo"])
    ClaudeAgent::ResultError.normalize_errors(nil).should eq([] of String)
    mixed = JSON::Any.new([JSON::Any.new(" a "), JSON::Any.new("  "), JSON::Any.new(7_i64)])
    ClaudeAgent::ResultError.normalize_errors(mixed).should eq(["a"])
  end
end
