require "../src/claude-agent-cr"

# Example 34: Advanced subagent definitions
#
# Demonstrates the full AgentDefinition surface: beyond `description`,
# `prompt`, `tools`, and `model`, agents can also declare:
#
#   * `disallowed_tools` - deny specific tools inside this agent
#   * `skills`           - enable named skills for this agent
#   * `memory`           - scope auto-memory files ("user" | "project" | "local")
#   * `mcp_servers`      - list of MCP server names or inline {name: config}
#   * `initial_prompt`   - seed the first user turn
#   * `max_turns`        - hard cap on conversation turns
#   * `background`       - run as a background agent
#   * `effort`           - "low" | "medium" | "high" | "max" (or integer tier)
#   * `permission_mode`  - per-agent permission mode override
#
# This example builds the definitions, prints the JSON the SDK would send
# to the CLI, and then (if the CLI is available) asks the main agent to
# delegate a tiny task to the "auditor" subagent so you can see the
# definitions flowing through end-to-end.

# An inline MCP server reference, plus a compact inline definition for one.
mcp_refs = [
  JSON::Any.new("playwright"),
  JSON::Any.new({
    "fetch" => JSON::Any.new({
      "type" => JSON::Any.new("http"),
      "url"  => JSON::Any.new("https://example.com/mcp"),
    }),
  }),
]

agents = {
  "auditor" => ClaudeAgent::AgentDefinition.new(
    description: "Read-only auditor that reports repo layout; never edits.",
    prompt: "You audit repositories. You must not write, edit, or execute code.",
    name: "Read-only Auditor",
    tools: ["Read", "Glob", "Grep"],
    disallowed_tools: ["Bash", "Edit", "Write"],
    model: "sonnet",
    memory: "project",
    max_turns: 2,
    initial_prompt: "Produce a 1-line summary of the repo layout.",
    effort: JSON::Any.new("low"),
    permission_mode: "plan",
  ),
  "researcher" => ClaudeAgent::AgentDefinition.new(
    description: "Background research agent with skills enabled.",
    prompt: "You are a research agent. Use skills when relevant.",
    skills: ["git"],
    mcp_servers: mcp_refs,
    background: true,
    effort: JSON::Any.new(3_i64),
  ),
}

options = ClaudeAgent::AgentOptions.new(
  agents: agents,
  agent: "auditor",
  allowed_tools: ["Read", "Glob", "Grep", "Task"],
  permission_mode: ClaudeAgent::PermissionMode::BypassPermissions,
  max_turns: 4,
)

# ---------------------------------------------------------------------------
# Dump the JSON shape the SDK would send to the CLI.
# ---------------------------------------------------------------------------
puts "Agent definitions (expanded fields):"
puts "-" * 60
agents.each do |name, defn|
  puts JSON.parse(defn.to_json).to_pretty_json.gsub(/^/m, "  [#{name}] ")
  puts
end
puts "-" * 60
puts

# ---------------------------------------------------------------------------
# If the CLI is available, run a tiny delegation so the caller can see
# the subagent fields reach the model.
# ---------------------------------------------------------------------------
begin
  ClaudeAgent::AgentClient.open(options) do |client|
    puts "Delegating to the auditor subagent..."
    client.query("Use the auditor agent to audit this repo in one sentence.")

    client.each_response do |message|
      case message
      when ClaudeAgent::AssistantMessage
        prefix = message.from_subagent? ? "[auditor] " : ""
        puts "#{prefix}#{message.text}" if message.has_text?
      when ClaudeAgent::ResultMessage
        puts
        puts "Done in #{message.num_turns} turns (subtype=#{message.subtype})."
      end
    end
  end
rescue ClaudeAgent::CLINotFoundError
  puts "Claude CLI not installed; skipping live delegation."
rescue ex
  puts "Live delegation skipped: #{ex.message}"
end
