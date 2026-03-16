require "../src/claude-agent-cr"

# This example uses a real PreToolUse hook to rewrite a Bash command before the
# CLI executes it. The agent asks for a harmless `echo ...` command, but the
# hook changes it to `pwd`, which demonstrates end-to-end hook propagation
# through the control protocol.

rewrite_bash = ->(input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
  tool_input = input.tool_input

  command = tool_input && tool_input["command"]?.try(&.as_s?)

  if input.tool_name == "Bash" && command
    puts "[PreToolUse] Rewriting Bash command: #{command} -> pwd"
    ClaudeAgent::HookResult.allow_with_input({
      "command" => JSON::Any.new("pwd"),
    })
  else
    ClaudeAgent::HookResult.allow
  end
}

log_permissions = ->(input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
  puts "[PermissionRequest] #{input.tool_name}: suggestions=#{input.permission_suggestions.try(&.size) || 0}"
  ClaudeAgent::HookResult.permission_request({
    "type" => JSON::Any.new("allow"),
  })
}

hooks = ClaudeAgent::HookConfig.new(
  pre_tool_use: [ClaudeAgent::HookMatcher.new(matcher: "Bash", hooks: [rewrite_bash])],
  permission_request: [ClaudeAgent::HookMatcher.new(matcher: "Bash", hooks: [log_permissions])],
)

options = ClaudeAgent::AgentOptions.new(
  allowed_tools: ["Bash"],
  permission_mode: ClaudeAgent::PermissionMode::Default,
  hooks: hooks,
  max_turns: 3,
)

ClaudeAgent::AgentClient.open(options) do |client|
  client.query("Use Bash to run `echo should-be-overridden`, then tell me exactly what command output you saw.")

  client.each_response do |message|
    case message
    when ClaudeAgent::AssistantMessage
      print message.text if message.has_text?
    when ClaudeAgent::ResultMessage
      puts
      puts
      puts "Done. If the hook fired, Claude should describe the output of `pwd` rather than `echo should-be-overridden`."
    end
  end
end
