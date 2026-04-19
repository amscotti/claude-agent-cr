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
