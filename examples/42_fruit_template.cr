# Fruit template: a showcase of the newly-added SDK features.
#
# This example exercises the features brought over from the Python / TS SDKs:
#   - TaskUpdatedMessage + TERMINAL_TASK_STATUSES (background task lifecycle)
#   - tool_use_meta sidecar (display-friendly tool-call labels)
#   - stop_details / refusal? on AssistantMessage
#   - origin on ResultMessage
#   - forward_subagent_text option (live subagent deltas)
#   - managed_settings option (policy-tier settings via --managed-settings)
#   - SandboxCredentialsSettings (credential deny/mask in the sandbox)
#   - PluginConfig with skip_mcp_discovery (--plugin-dir-no-mcp)
#
# It is intentionally broad so it doubles as a smoke test: run it against a
# real Claude Code CLI to confirm the new message fields parse end-to-end.
require "../src/claude-agent-cr"

# managed_settings: enforce a deny rule in-memory (emitted as
# `--managed-settings <json>`), honored below IT-managed sources.
permissions = {} of String => JSON::Any
permissions["deny"] = JSON::Any.new([JSON::Any.new("Bash(rm:*)")] of JSON::Any)
managed = {} of String => JSON::Any
managed["permissions"] = JSON::Any.new(permissions)

# Sandbox credentials: mask an AWS env var so sandboxed commands see a
# sentinel; the host proxy injects the real value only for AWS hosts.
credentials = ClaudeAgent::SandboxCredentialsSettings.new(
  env_vars: [
    ClaudeAgent::SandboxCredentialEnvVar.new(
      "AWS_SECRET_ACCESS_KEY",
      mode: "mask",
      inject_hosts: ["*.amazonaws.com"],
    ),
  ],
  files: [
    ClaudeAgent::SandboxCredentialFile.new("~/.aws/credentials"),
  ],
)
sandbox = ClaudeAgent::SandboxSettings.new(
  enabled: false, # flip to true to exercise credential masking end-to-end
  credentials: credentials,
)

options = ClaudeAgent::AgentOptions.new(
  allowed_tools: ["Read", "Glob", "Grep"],
  forward_subagent_text: true, # NEW: stream subagent text deltas (via initialize)
  managed_settings: managed,   # NEW: policy-tier settings (via --managed-settings)
  sandbox: sandbox,            # NEW: includes credential deny/mask
  max_turns: 3,
)

ClaudeAgent::AgentClient.open(options) do |client|
  client.query("What are three kinds of fruit? Answer in one sentence each.")

  client.each_response do |message|
    case message
    when ClaudeAgent::AssistantMessage
      # NEW: refusal detection without text-matching.
      if message.refusal?
        details = message.stop_details
        puts "[refusal] category=#{details.try(&.category)} #{details.try(&.explanation)}"
      end

      # NEW: render display-friendly labels for tool calls when the CLI
      # emits the tool_use_meta sidecar (an array of per-block entries).
      message.tool_use_meta.try &.each do |meta|
        icon = meta.icon_url ? "  icon=#{meta.icon_url}" : ""
        server = meta.server_display_name ? " via #{meta.server_display_name}" : ""
        puts "[tool-call] #{meta.display_name}#{server} (id=#{meta.id})#{icon}"
      end

      print message.text if message.has_text?
    when ClaudeAgent::TaskUpdatedMessage
      # NEW: terminal task updates that arrive WITHOUT a TaskNotification.
      # Without this case, active-task tracking could hang.
      state = message.terminal? ? "TERMINAL" : "running"
      puts "[task_updated] #{message.task_id} status=#{message.status} (#{state})"
    when ClaudeAgent::TaskNotificationMessage
      puts "[task_#{message.status}] #{message.task_id}"
    when ClaudeAgent::ResultMessage
      puts
      puts "Done: #{message.subtype}"
      # NEW: what triggered this result — an object like {"kind":"human"}
      # or {"kind":"task-notification"}.
      puts "Origin: #{message.origin.try(&.kind) || "(unknown)"}"
    end
  end
end
