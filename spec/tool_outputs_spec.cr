require "./spec_helper"

describe ClaudeAgent::BashToolOutput do
  it "parses timedOutAfterMs from tool_use_result JSON" do
    json = {
      "stdout"             => "",
      "stderr"             => "command still running",
      "interrupted"        => false,
      "timedOutAfterMs"    => 120_000,
      "backgroundTaskId"   => "bg-1",
      "backgroundedByUser" => false,
    }.to_json

    out = ClaudeAgent::BashToolOutput.parse(json)
    out.should_not be_nil
    if out
      out.timed_out_after_ms.should eq(120_000)
      out.timed_out?.should be_true
      out.background_task_id.should eq("bg-1")
      out.backgrounded_by_user.should be_false
    end
  end

  it "parses from JSON::Any" do
    value = JSON.parse(%({"stdout":"hi","stderr":"","interrupted":false}))
    out = ClaudeAgent::BashToolOutput.parse(value)
    out.should_not be_nil
    out.try(&.stdout).should eq("hi")
    out.try(&.timed_out_after_ms).should be_nil
    out.try(&.timed_out?).should be_false
  end

  it "returns nil for non-JSON content" do
    ClaudeAgent::BashToolOutput.parse("not json").should be_nil
    ClaudeAgent::BashToolOutput.parse(nil).should be_nil
  end
end

describe ClaudeAgent::AgentToolCompletedOutput do
  it "parses resolvedModel into model" do
    json = {
      "status"            => "completed",
      "agentId"           => "agent-1",
      "agentType"         => "Explore",
      "resolvedModel"     => "claude-sonnet-4-6",
      "totalTokens"       => 1500,
      "totalDurationMs"   => 4200,
      "totalToolUseCount" => 3,
      "prompt"            => "explore repo",
    }.to_json

    out = ClaudeAgent::AgentToolCompletedOutput.parse(json)
    out.should_not be_nil
    if out
      out.status.should eq("completed")
      out.resolved_model.should eq("claude-sonnet-4-6")
      out.model.should eq("claude-sonnet-4-6")
      out.effective_model.should eq("claude-sonnet-4-6")
      out.agent_id.should eq("agent-1")
      out.total_tokens.should eq(1500)
    end
  end

  it "prefers explicit model over resolvedModel" do
    json = %({"status":"completed","model":"claude-opus-4-7","resolvedModel":"claude-sonnet-4-6"})
    out = ClaudeAgent::AgentToolCompletedOutput.parse(json)
    out.try(&.model).should eq("claude-opus-4-7")
    out.try(&.effective_model).should eq("claude-opus-4-7")
  end
end

describe ClaudeAgent::SkillToolOutput do
  it "parses background flag" do
    json = %({"background":true,"name":"my-skill","status":"launched"})
    out = ClaudeAgent::SkillToolOutput.parse(json)
    out.should_not be_nil
    if out
      out.background.should be_true
      out.background?.should be_true
      out.name.should eq("my-skill")
    end
  end

  it "defaults background? to false when absent" do
    out = ClaudeAgent::SkillToolOutput.parse(%({"name":"x"}))
    out.try(&.background?).should be_false
  end
end

describe ClaudeAgent::NotebookEditOutput do
  it "parses old_source for replace/delete diffs" do
    json = {
      "new_source" => "print(2)",
      "old_source" => "print(1)",
      "cell_id"    => "cell-1",
      "cell_type"  => "code",
      "language"   => "python",
      "edit_mode"  => "replace",
    }.to_json

    out = ClaudeAgent::NotebookEditOutput.parse(json)
    out.should_not be_nil
    if out
      out.old_source.should eq("print(1)")
      out.new_source.should eq("print(2)")
      out.edit_mode.should eq("replace")
      out.cell_id.should eq("cell-1")
    end
  end
end

describe ClaudeAgent::ReadMcpResourceDirOutput do
  it "parses directory listing payloads" do
    json = %({"server":"docs","uri":"mcp://docs/","resources":[{"uri":"a"}]})
    out = ClaudeAgent::ReadMcpResourceDirOutput.parse(json)
    out.should_not be_nil
    out.try(&.server).should eq("docs")
    out.try(&.resources).try(&.size).should eq(1)
  end
end

describe ClaudeAgent::AgentToolQueuedOutput do
  it "detects queued_to_running" do
    out = ClaudeAgent::AgentToolQueuedOutput.parse(%({"status":"queued_to_running","agentId":"a1"}))
    out.try(&.queued_to_running?).should be_true
    out.try(&.agent_id).should eq("a1")
  end
end

describe ClaudeAgent::BuiltinTools do
  it "exposes ReadMcpResourceDir constant" do
    ClaudeAgent::BuiltinTools::READ_MCP_RESOURCE_DIR.should eq("ReadMcpResourceDir")
    ClaudeAgent::BuiltinTools::BASH.should eq("Bash")
  end
end
