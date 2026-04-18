require "../src/claude-agent-cr"

# Example 35: Auto / DontAsk permission modes and rich permission context
#
# Recent Claude Code CLI releases introduced two new permission modes:
#
#   * `PermissionMode::Auto`    - CLI-managed automatic decisions
#   * `PermissionMode::DontAsk` - never prompt; fail closed on anything
#                                 that is not explicitly allowed
#
# Alongside the modes, the `can_use_tool` callback now receives three
# additional fields on its `PermissionContext`:
#
#   * `tool_use_id`  - unique id for this tool call (useful when multiple
#                      parallel tool calls are in flight)
#   * `agent_id`     - set when the call originates from a subagent
#   * `blocked_path` - populated for file-write requests blocked by safety
#                      checks, so callers can surface a targeted `addRules`
#                      suggestion

# ---------------------------------------------------------------------------
# 1. Show how each permission mode maps to a CLI flag value.
# ---------------------------------------------------------------------------
modes = [
  ClaudeAgent::PermissionMode::Default,
  ClaudeAgent::PermissionMode::AcceptEdits,
  ClaudeAgent::PermissionMode::Plan,
  ClaudeAgent::PermissionMode::BypassPermissions,
  ClaudeAgent::PermissionMode::Auto,
  ClaudeAgent::PermissionMode::DontAsk,
]

puts "PermissionMode -> CLI flag value:"
modes.each { |mode| puts "  #{mode.to_s.ljust(20)} -> #{mode.to_cli_value}" }
puts

# ---------------------------------------------------------------------------
# 2. Build a permission callback that inspects the new context fields and
#    suggests a scoped allow rule when a write is blocked.
# ---------------------------------------------------------------------------
decisions = [] of String

callback = ->(ctx : ClaudeAgent::PermissionContext) do
  decisions << <<-LINE
  tool=#{ctx.tool_name} tool_use_id=#{ctx.tool_use_id || "-"} \
  agent_id=#{ctx.agent_id || "(main)"} blocked_path=#{ctx.blocked_path || "-"}
  LINE

  if ctx.tool_name == "Bash" && ctx.agent_id.nil?
    # Deny bash from the main agent; allow everything else.
    ClaudeAgent::PermissionResult.deny("Bash not allowed from the main agent in this demo")
  elsif path = ctx.blocked_path
    # Demonstrate using blocked_path to build a targeted allow rule.
    update = ClaudeAgent::AddRulesUpdate.new(
      rules: [ClaudeAgent::PermissionRuleValue.new("Edit(#{path})")],
      behavior: ClaudeAgent::PermissionRuleBehavior::Allow,
      destination: ClaudeAgent::PermissionUpdateDestination::Session,
    )
    ClaudeAgent::PermissionResult.allow(updated_permissions: [update.as(ClaudeAgent::PermissionUpdate)])
  else
    ClaudeAgent::PermissionResult.allow
  end
end

options = ClaudeAgent::AgentOptions.new(
  allowed_tools: ["Read", "Glob", "Grep"],
  permission_mode: ClaudeAgent::PermissionMode::Auto,
  can_use_tool: callback,
  max_turns: 3,
)

# ---------------------------------------------------------------------------
# 3. Run a query so the CLI can exercise the callback (best-effort live demo).
# ---------------------------------------------------------------------------
begin
  ClaudeAgent::AgentClient.open(options) do |client|
    puts "Running with permission_mode=auto..."
    client.query("List the top-level files in this repo and pick your favourite.")

    client.each_response do |message|
      case message
      when ClaudeAgent::AssistantMessage
        puts message.text if message.has_text?
      when ClaudeAgent::ResultMessage
        puts
        puts "Result: #{message.subtype} in #{message.num_turns} turns"
      end
    end
  end
rescue ex : ClaudeAgent::CLINotFoundError
  puts "Claude CLI not installed; skipping live run."
rescue ex
  puts "Live run skipped: #{ex.message}"
end

puts
puts "Permission decisions observed (#{decisions.size}):"
decisions.each { |line| puts "  - #{line.strip}" }
