require "../src/claude-agent-cr"

# Example 40: Runtime MCP + plugin controls
#
# Demonstrates the set of control-protocol methods exposed on `AgentClient`
# for mutating the session without restarting the subprocess:
#
#   * `set_mcp_servers`    - replace the active MCP server configuration
#   * `enable_mcp_channel` - lazily activate an MCP server's tools channel
#   * `reload_plugins`     - pick up new commands/agents/MCP servers
#   * `prompt_suggestion`  - ask the CLI for a next-step suggestion
#
# These require a Claude Code CLI that understands the corresponding
# control subtypes; older CLIs return an error on the control channel,
# which the example catches and reports.

STDOUT.sync = true

options = ClaudeAgent::AgentOptions.new(
  allowed_tools: [] of String,
  max_turns: 1,
  append_system_prompt: "Be terse.",
)

# Wrap control-protocol calls in a short timeout so older CLIs that silently
# drop unknown subtypes don't stall the example for the default 60s per call.
def attempt(label : String, &block : -> Nil)
  puts "- #{label}"
  channel = Channel(String).new(1)

  spawn do
    block.call
    channel.send("ok") unless channel.closed?
  rescue ex
    channel.send("error: #{ex.message}") unless channel.closed?
  end

  select
  when outcome = channel.receive
    puts "    #{outcome}"
  when timeout(5.seconds)
    puts "    timed out (CLI may not support this subtype)"
  end

  channel.close
end

begin
  client = ClaudeAgent.startup(options)

  begin
    puts "Control requests:"

    attempt("reload_plugins") { client.reload_plugins }
    attempt("prompt_suggestion") { client.prompt_suggestion }
    attempt("enable_mcp_channel(\"demo\")") { client.enable_mcp_channel("demo") }

    # NOTE: `set_mcp_servers` is intentionally *not* invoked here because
    # exercising it spawns real MCP server processes, which is rarely what
    # you want in a docs-style demo. Shape of the call:
    #
    #   client.set_mcp_servers({
    #     "demo" => JSON::Any.new({
    #       "type"    => JSON::Any.new("stdio"),
    #       "command" => JSON::Any.new("/path/to/your/mcp-binary"),
    #     }),
    #   })
  ensure
    client.stop
  end
rescue ClaudeAgent::CLINotFoundError
  puts "Claude CLI not installed; skipped the demo."
rescue ex
  puts "Demo skipped: #{ex.message}"
end
