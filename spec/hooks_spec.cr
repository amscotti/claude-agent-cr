require "./spec_helper"

describe ClaudeAgent::HookMatcher do
  it "matches tool names" do
    matcher = ClaudeAgent::HookMatcher.new(matcher: "Bash")
    matcher.matches?("Bash").should be_true
    matcher.matches?("Read").should be_false
  end

  it "matches regex" do
    matcher = ClaudeAgent::HookMatcher.new(matcher: "^Bash.*")
    matcher.matches?("Bash").should be_true
    matcher.matches?("BashCommand").should be_true
    matcher.matches?("Read").should be_false
  end
end

describe ClaudeAgent::ControlHookCallbackRequest do
  it "parses hook_callback control request" do
    json = %({"subtype": "hook_callback", "hook": "pre_compact", "input": {"key": "value"}})
    req = ClaudeAgent::ControlHookCallbackRequest.from_json(json)
    req.subtype.should eq("hook_callback")
    req.hook.should eq("pre_compact")
    req.input.should_not be_nil
    req.input.try(&.["key"].as_s.should eq("value"))
  end

  it "parses hook_callback without input" do
    json = %({"subtype": "hook_callback", "hook": "pre_compact"})
    req = ClaudeAgent::ControlHookCallbackRequest.from_json(json)
    req.hook.should eq("pre_compact")
    req.input.should be_nil
  end
end

describe ClaudeAgent::HookResult do
  it "creates allow result" do
    res = ClaudeAgent::HookResult.allow
    res.hook_specific_output.should be_nil
  end

  it "creates deny result" do
    res = ClaudeAgent::HookResult.deny("Bad tool")
    output = res.hook_specific_output
    output.should_not be_nil
    if output
      output.permission_decision.should eq("deny")
      output.permission_decision_reason.should eq("Bad tool")
    end
  end
end

describe ClaudeAgent::HookConfig do
  it "supports notification hook" do
    config = ClaudeAgent::HookConfig.new(
      notification: [->(_input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
        ClaudeAgent::HookResult.allow
      }]
    )
    config.notification.should_not be_nil
    config.notification.try(&.size).should eq(1)
  end

  it "supports pre_compact hook" do
    config = ClaudeAgent::HookConfig.new(
      pre_compact: [->(_input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
        ClaudeAgent::HookResult.allow
      }]
    )
    config.pre_compact.should_not be_nil
  end

  it "supports permission_request hook with matcher" do
    config = ClaudeAgent::HookConfig.new(
      permission_request: [ClaudeAgent::HookMatcher.new(
        matcher: "Bash",
        hooks: [->(_input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
          ClaudeAgent::HookResult.allow
        }]
      )]
    )
    config.permission_request.should_not be_nil
    config.permission_request.try(&.size).should eq(1)
  end
end

describe ClaudeAgent::HookInput do
  it "supports common context fields" do
    input = ClaudeAgent::HookInput.new(
      session_id: "sess-123",
      transcript_path: "/home/user/.claude/projects/myproject/sessions/sess-123.jsonl",
      cwd: "/home/user/myproject",
      permission_mode: "Default",
      hook_event_name: "PreToolUse",
    )
    input.session_id.should eq("sess-123")
    input.transcript_path.should eq("/home/user/.claude/projects/myproject/sessions/sess-123.jsonl")
    input.cwd.should eq("/home/user/myproject")
    input.permission_mode.should eq("Default")
    input.hook_event_name.should eq("PreToolUse")
  end

  it "has nil common context fields by default" do
    input = ClaudeAgent::HookInput.new
    input.session_id.should be_nil
    input.transcript_path.should be_nil
    input.cwd.should be_nil
    input.permission_mode.should be_nil
    input.hook_event_name.should be_nil
  end

  it "supports notification fields with context" do
    input = ClaudeAgent::HookInput.new(
      session_id: "sess-456",
      hook_event_name: "Notification",
      notification_message: "Agent status update",
      notification_title: "Status",
    )
    input.session_id.should eq("sess-456")
    input.hook_event_name.should eq("Notification")
    input.notification_message.should eq("Agent status update")
    input.notification_title.should eq("Status")
  end

  it "supports pre_compact fields with context" do
    input = ClaudeAgent::HookInput.new(
      session_id: "sess-789",
      hook_event_name: "PreCompact",
      transcript_path: "/tmp/transcript.jsonl",
      trigger: "manual",
      custom_instructions: "Focus on key context",
    )
    input.session_id.should eq("sess-789")
    input.hook_event_name.should eq("PreCompact")
    input.transcript_path.should eq("/tmp/transcript.jsonl")
    input.trigger.should eq("manual")
    input.custom_instructions.should eq("Focus on key context")
  end

  it "deserializes from JSON with common fields" do
    json = %({"session_id":"s1","transcript_path":"/tmp/t.jsonl","cwd":"/home","permission_mode":"Default","hook_event_name":"Stop"})
    input = ClaudeAgent::HookInput.from_json(json)
    input.session_id.should eq("s1")
    input.transcript_path.should eq("/tmp/t.jsonl")
    input.cwd.should eq("/home")
    input.permission_mode.should eq("Default")
    input.hook_event_name.should eq("Stop")
  end

  it "supports PreToolUse fields" do
    input = ClaudeAgent::HookInput.new(
      hook_event_name: "PreToolUse",
      tool_name: "Bash",
      tool_input: {"command" => JSON::Any.new("ls")},
      tool_use_id: "tu_123",
    )
    input.tool_name.should eq("Bash")
    input.tool_use_id.should eq("tu_123")
    input.tool_input.try(&.["command"].as_s).should eq("ls")
  end

  it "supports PostToolUse fields" do
    input = ClaudeAgent::HookInput.new(
      hook_event_name: "PostToolUse",
      tool_name: "Bash",
      tool_use_id: "tu_456",
      tool_result: "file1.txt\nfile2.txt",
      tool_response: "file1.txt\nfile2.txt",
      tool_input: {"command" => JSON::Any.new("ls")},
    )
    input.tool_result.should eq("file1.txt\nfile2.txt")
    input.tool_response.should eq("file1.txt\nfile2.txt")
    input.tool_use_id.should eq("tu_456")
    input.tool_input.should_not be_nil
  end

  it "supports PostToolUseFailure fields" do
    input = ClaudeAgent::HookInput.new(
      hook_event_name: "PostToolUseFailure",
      tool_name: "Bash",
      tool_use_id: "tu_789",
      error: "command not found",
      is_interrupt: false,
    )
    input.error.should eq("command not found")
    input.is_interrupt.should eq(false)
    input.tool_use_id.should eq("tu_789")
  end

  it "supports Stop hook fields" do
    input = ClaudeAgent::HookInput.new(
      hook_event_name: "Stop",
      stop_hook_active: true,
    )
    input.stop_hook_active.should eq(true)
  end

  it "supports SubagentStart fields" do
    input = ClaudeAgent::HookInput.new(
      hook_event_name: "SubagentStart",
      agent_id: "agent-001",
      agent_type: "code-reviewer",
    )
    input.agent_id.should eq("agent-001")
    input.agent_type.should eq("code-reviewer")
  end

  it "supports SubagentStop fields" do
    input = ClaudeAgent::HookInput.new(
      hook_event_name: "SubagentStop",
      agent_id: "agent-001",
      agent_type: "code-reviewer",
      agent_transcript_path: "/tmp/subagent.jsonl",
      stop_hook_active: false,
    )
    input.agent_id.should eq("agent-001")
    input.agent_type.should eq("code-reviewer")
    input.agent_transcript_path.should eq("/tmp/subagent.jsonl")
    input.stop_hook_active.should eq(false)
  end

  it "supports Notification fields with type" do
    input = ClaudeAgent::HookInput.new(
      hook_event_name: "Notification",
      notification_message: "Permission needed",
      notification_title: "Alert",
      notification_type: "permission_prompt",
    )
    input.notification_type.should eq("permission_prompt")
  end

  it "supports SessionStart fields" do
    input = ClaudeAgent::HookInput.new(
      hook_event_name: "SessionStart",
      source: "startup",
    )
    input.source.should eq("startup")
  end

  it "supports SessionEnd fields" do
    input = ClaudeAgent::HookInput.new(
      hook_event_name: "SessionEnd",
      session_end_reason: "clear",
    )
    input.session_end_reason.should eq("clear")
  end

  it "supports PermissionRequest fields" do
    input = ClaudeAgent::HookInput.new(
      hook_event_name: "PermissionRequest",
      tool_name: "Write",
      tool_use_id: "tu_perm",
      permission_suggestions: [JSON::Any.new("allow_once")],
    )
    input.tool_name.should eq("Write")
    input.permission_suggestions.try(&.size).should eq(1)
  end

  it "deserializes PostToolUseFailure from JSON" do
    json = %({"hook_event_name":"PostToolUseFailure","tool_name":"Bash","error":"fail","is_interrupt":true,"stop_hook_active":false})
    input = ClaudeAgent::HookInput.from_json(json)
    input.hook_event_name.should eq("PostToolUseFailure")
    input.error.should eq("fail")
    input.is_interrupt.should eq(true)
  end

  it "deserializes SubagentStop from JSON" do
    json = %({"hook_event_name":"SubagentStop","agent_id":"a1","agent_type":"reviewer","agent_transcript_path":"/tmp/a.jsonl","stop_hook_active":true})
    input = ClaudeAgent::HookInput.from_json(json)
    input.agent_id.should eq("a1")
    input.agent_type.should eq("reviewer")
    input.agent_transcript_path.should eq("/tmp/a.jsonl")
    input.stop_hook_active.should eq(true)
  end
end
