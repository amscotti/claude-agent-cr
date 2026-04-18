# Claude Agent SDK for Crystal

An unofficial Anthropic Agent SDK for Crystal, enabling developers to build autonomous AI agents powered by Claude and the Claude Code CLI.

This library provides a programmatic interface to the [Claude Code](https://code.claude.com/docs/en/overview) CLI, allowing you to create agents that can execute commands, edit files, and perform complex multi-step workflows.

> Note: A large portion of this library was written with the assistance of AI (Claude), including code, tests, and documentation.

## Features

*   **One-Shot Queries**: Simple interface for single-turn agent tasks.
*   **Interactive Sessions**: Full bidirectional agent control for chat applications.
*   **V2 Streaming Interface**: Send/receive patterns for real-time communication.
*   **Tool Use**: Access to Claude's built-in tools (Bash, File Edit, etc.) and support for custom tools.
*   **SDK MCP Servers**: In-process MCP servers with custom tools via control protocol (same architecture as official SDKs).
*   **External MCP Servers**: Connect to external MCP servers (stdio, HTTP, SSE transports).
*   **Runtime MCP Management**: `set_mcp_servers`, `enable_mcp_channel`, and `reload_plugins` to mutate the session without restarting the subprocess.
*   **Preset Types**: Type-safe presets for system prompts and tools to prevent typos.
*   **System Prompt Options**: Inline strings, `SystemPromptPreset` (with `exclude_dynamic_sections` for cache-friendly prompts), or `SystemPromptFile` loaded from disk.
*   **Type-Safe Schemas**: Crystal's answer to Zod - generate JSON schemas from types.
*   **Structured Outputs**: Get validated JSON responses matching your schema.
*   **Dynamic Controls**: Change model and permission mode live, inspect MCP status, stop tasks, `get_context_usage`, `prompt_suggestion`.
*   **Skills**: Enable SDK-managed skill access (`"all"` or a named list) with automatic `setting_sources` defaults.
*   **Task Budgets**: API-side token budget awareness via `task_budget` so the model paces tool use.
*   **Server Info**: Access CLI initialization metadata like commands, models, and output styles.
*   **Subagents**: Define specialized agents with rich fields (`disallowed_tools`, `memory`, `initial_prompt`, `max_turns`, `background`, `effort`, `permission_mode`, per-agent `mcp_servers`).
*   **Hooks & Permissions**: Granular control over what the agent is allowed to do with full hook support (PreToolUse, PostToolUse, PreCompact, Notification, TeammateIdle, TaskCompleted, ConfigChange, etc.).
*   **Permission Modes**: `default`, `acceptEdits`, `plan`, `bypassPermissions`, `auto`, `dontAsk`.
*   **Session Management**: Resume, fork, delete, and continue conversations with precise message-level resume.
*   **Session History & Subagents**: List saved sessions, fork a session branch (`fork_session`), list subagents (`list_subagents`), read subagent transcripts (`get_subagent_messages`), delete sessions (`delete_session`).
*   **Transcript Controls**: `should_query: false` to append user messages without triggering a turn; `include_system_messages` on `get_session_messages`.
*   **File Checkpointing**: Track and rewind file changes.
*   **Sandbox Support**: Configure sandboxed execution environments.
*   **Extended Thinking**: `ThinkingConfig.adaptive` / `enabled` / `disabled`, plus fine-grained `effort` tiers (`Low`, `Medium`, `High`, `Xhigh`, `Max`) — `xhigh` is the default Claude Code tier for Opus 4.7.
*   **Pre-warming**: `ClaudeAgent.startup` spins up the CLI subprocess ahead of the first query.
*   **Tracing**: Automatic W3C trace context propagation (`TRACEPARENT` / `TRACESTATE`) when present in the caller's environment.
*   **Streaming**: Real-time message streaming using Crystal's native fibers.
*   **Type Safety**: Fully typed message and event structures, including new `ApiRetryMessage`, `MemoryRecallMessage`, `StatusMessage`, and `MirrorErrorMessage`, with graceful handling of unknown content types.

## Prerequisites

*   **Crystal**: >= 1.10.0
*   **Claude Code CLI**: You must have the `claude` CLI installed and authenticated.
    *   Install via curl: `curl -fsSL https://claude.ai/install.sh | bash`
    *   Authenticate: `claude login`

## Installation

1.  Add the dependency to your `shard.yml`:

    ```yaml
    dependencies:
      claude-agent-cr:
        github: amscotti/claude-agent-cr
        version: ~> 0.5.0
    ```

2.  Run `shards install`

## Usage

### Basic Query

For simple, one-off tasks where you want the agent to do something and return the result.

```crystal
require "claude-agent-cr"

begin
  ClaudeAgent.query("Create a file named hello.txt with 'Hello World'") do |message|
    # Stream the agent's thought process and output
    if message.is_a?(ClaudeAgent::AssistantMessage)
      print message.text
    end
  end
rescue ex : ClaudeAgent::CLINotFoundError
  puts "Please install Claude CLI"
end
```

### Interactive Conversation

For building chatbots or interactive agent sessions.

```crystal
require "claude-agent-cr"

ClaudeAgent::AgentClient.open do |client|
  # Initial query
  client.query("Check the current directory status")
  
  # Process responses
  client.each_response do |message|
    case message
    when ClaudeAgent::AssistantMessage
      puts "Claude: #{message.text}"
    when ClaudeAgent::PermissionRequest
      # Automatically approve or handle via callback
      puts "Agent wants to use #{message.tool_name}..."
    end
  end
  
  # Follow up
  client.send_user_message("Now create a summary file.")
  
  client.each_response do |message|
    # ... handle responses
  end
end
```

### Dynamic Controls

Change live session settings while an `AgentClient` is connected.

```crystal
ClaudeAgent::AgentClient.open do |client|
  client.query("Review this repository")
  client.each_response { |message| puts message }

  client.set_permission_mode(ClaudeAgent::PermissionMode::Plan)
  client.set_model("claude-sonnet-4-5")

  status = client.get_mcp_status
  puts "Configured MCP servers: #{status.mcp_servers.size}"

  # Apply flag settings, generate a title, toggle proactive mode
  client.apply_flag_settings({"verbose" => JSON::Any.new(true)})
  title = client.generate_session_title("Repository review session", persist: true)
  puts "Generated title: #{title}"
  client.set_proactive(true)
  client.enable_remote_control(true)
end
```

### Rich Event Messages

Streaming clients can react to typed init, task, rate-limit, prompt-suggestion,
elicitation-complete, and fallback event messages.

```crystal
ClaudeAgent::AgentClient.open do |client|
  client.query("Inspect this repository and suggest one test improvement")

  client.each_response do |message|
    case message
    when ClaudeAgent::InitMessage
      puts "Output style: #{message.output_style}"
      puts "Slash commands: #{message.slash_commands.join(", ")}"
    when ClaudeAgent::TaskStartedMessage
      puts "Task started: #{message.description}"
    when ClaudeAgent::TaskProgressMessage
      puts "Task tokens: #{message.usage.total_tokens}"
    when ClaudeAgent::TaskNotificationMessage
      puts "Task status: #{message.status}"
    when ClaudeAgent::RateLimitEvent
      puts "Rate limit status: #{message.rate_limit_info.status}"
    when ClaudeAgent::ElicitationCompleteMessage
      puts "Elicitation complete for #{message.mcp_server_name}"
    when ClaudeAgent::PromptSuggestionMessage
      puts "Suggestion: #{message.suggestion}"
    when ClaudeAgent::UnknownMessage
      puts "Unknown event type: #{message.type}"
    end
  end
end
```

### Server Info

Inspect the Claude CLI initialization metadata for available commands and output styles.
`get_server_info` returns a typed `ClaudeAgent::ServerInfo` wrapper.
`AgentClient#supported_agents` and `AgentClient#supported_commands` provide
small convenience helpers over that metadata.

```crystal
ClaudeAgent::AgentClient.open do |client|
  if info = client.get_server_info
    puts "Commands available: #{info.commands.size}"
    puts "Output style: #{info.output_style || "default"}"
    puts "Supported agents: #{client.supported_agents.map(&.name).join(", ")}"
  end
end
```

### Settings And Async Message Controls

Inspect effective settings, receive prompt suggestions, and cancel a queued user message.

```crystal
ClaudeAgent::AgentClient.open(ClaudeAgent::AgentOptions.new(prompt_suggestions: true)) do |client|
  settings = client.settings
  applied = settings["applied"]?.try(&.as_h?)
  puts "Model: #{applied.try(&.["model"]?.try(&.as_s?)) || "(unknown)"}"

  queued_uuid = UUID.random.to_s
  client.query("Answer with exactly: FIRST")
  client.send_user_message("Queued follow-up", uuid: queued_uuid)
  puts "Cancelled: #{client.cancel_async_message(queued_uuid)}"
end
```

### MCP Elicitation

Handle MCP user-input requests programmatically when a server requires form or URL-based auth.

```crystal
hooks = ClaudeAgent::HookConfig.new(
  elicitation: [->(input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
    puts "Elicitation from #{input.mcp_server_name}: #{input.elicitation_message}"
    ClaudeAgent::HookResult.elicitation("decline")
  }],
)

options = ClaudeAgent::AgentOptions.new(
  hooks: hooks,
  on_elicitation: ->(request : ClaudeAgent::ElicitationRequest) {
    request.mode == "url" ? ClaudeAgent::ElicitationResponse.decline : ClaudeAgent::ElicitationResponse.accept
  },
)
```

### Hook And Permission Overrides

Hooks and permission callbacks can now return runtime modifications that the CLI honors.

```crystal
rewrite_bash = ->(input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
  if input.tool_name == "Bash"
    ClaudeAgent::HookResult.allow_with_input({
      "command" => JSON::Any.new("pwd"),
    })
  else
    ClaudeAgent::HookResult.allow
  end
}

hooks = ClaudeAgent::HookConfig.new(
  pre_tool_use: [ClaudeAgent::HookMatcher.new(matcher: "Bash", hooks: [rewrite_bash])],
)

ClaudeAgent::AgentClient.open(ClaudeAgent::AgentOptions.new(hooks: hooks)) do |client|
  client.query("Use Bash to run ls -la")
  client.each_response { |message| puts message }
end
```

### Configuration

You can customize the agent's behavior using `AgentOptions`.

```crystal
options = ClaudeAgent::AgentOptions.new(
  model: "claude-opus-4-7",
  max_turns: 10,
  # Restrict tools
  allowed_tools: ["Read", "LS"],
  # Handle permissions automatically
  permission_mode: ClaudeAgent::PermissionMode::Default,
  # System prompt
  system_prompt: "You are a coding assistant."
)

ClaudeAgent.query("List files", options) { |msg| puts msg }
```

### Preset Types

Use type-safe presets instead of strings to prevent typos and get IDE autocomplete:

```crystal
# System prompt presets
options = ClaudeAgent::AgentOptions.new(
  system_prompt: ClaudeAgent::SystemPromptPreset.claude_code
)

# With additional instructions appended
options = ClaudeAgent::AgentOptions.new(
  system_prompt: ClaudeAgent::SystemPromptPreset.claude_code("Always use Crystal best practices.")
)

# Tools presets
options = ClaudeAgent::AgentOptions.new(
  tools: ClaudeAgent::ToolsPreset.claude_code
)

# String values still work for flexibility
options = ClaudeAgent::AgentOptions.new(
  system_prompt: "You are a helpful assistant.",
  tools: ["Read", "Write", "Bash"]
)
```

### Custom Tools (SDK MCP Servers)

Define custom tools that run in-process using the SDK MCP server architecture.

```crystal
# 1. Define tools using Schema builder
greet_tool = ClaudeAgent.tool(
  name: "greet",
  description: "Greet a user by name",
  schema: ClaudeAgent::Schema.object({
    "name" => ClaudeAgent::Schema.string("The name to greet"),
  }, required: ["name"])
) do |args|
  name = args["name"].as_s
  ClaudeAgent::ToolResult.text("Hello, #{name}!")
end

calculator_tool = ClaudeAgent.tool(
  name: "add",
  description: "Add two numbers",
  schema: ClaudeAgent::Schema.object({
    "a" => ClaudeAgent::Schema.number("First number"),
    "b" => ClaudeAgent::Schema.number("Second number"),
  }, required: ["a", "b"])
) do |args|
  a = args["a"].as_f
  b = args["b"].as_f
  ClaudeAgent::ToolResult.text("#{a} + #{b} = #{a + b}")
end

# 2. Bundle tools into an SDK MCP server
server = ClaudeAgent.create_sdk_mcp_server(
  name: "my-tools",
  tools: [greet_tool, calculator_tool]
)

# 3. Configure the agent with the server
mcp_servers = {} of String => ClaudeAgent::MCPServerConfig
mcp_servers["my-tools"] = server

options = ClaudeAgent::AgentOptions.new(
  mcp_servers: mcp_servers,
  # Tool names follow pattern: mcp__<server>__<tool>
  allowed_tools: ["mcp__my-tools__greet", "mcp__my-tools__add"]
)

# 4. Use the agent - tools run in your Crystal process
ClaudeAgent.query("Greet Alice and calculate 2 + 3", options) do |msg|
  puts msg if msg.is_a?(ClaudeAgent::AssistantMessage)
end
```

### V2 Streaming Session

For bidirectional communication with send/receive patterns.

```crystal
require "claude-agent-cr"

# Block form (recommended) - automatically handles cleanup
ClaudeAgent::StreamingSession.open do |session|
  session.send("What is 2 + 2?")

  session.each_message do |msg|
    case msg
    when ClaudeAgent::AssistantMessage
      puts msg.text if msg.has_text?
    when ClaudeAgent::ResultMessage
      puts "Done! Cost: $#{msg.cost_usd}"
    end
  end
end

# Manual control for complex interactions
session = ClaudeAgent::StreamingSession.new
session.start
session.send("Hello!")
msg = session.receive  # Blocking receive
session.close
```

### Type-Safe Schema Builder

Crystal's answer to Zod - use the type system to generate JSON schemas for tool definitions and structured outputs.

```crystal
# Define a schema for tool input or structured output
user_schema = ClaudeAgent::Schema.object({
  "name"   => ClaudeAgent::Schema.string("User's name"),
  "age"    => ClaudeAgent::Schema.integer("Age", minimum: 0, maximum: 150),
  "email"  => ClaudeAgent::Schema.string("Email", format: "email"),
  "tags"   => ClaudeAgent::Schema.array(ClaudeAgent::Schema.string, "User tags"),
  "role"   => ClaudeAgent::Schema.enum(["admin", "user", "guest"], "User role"),
  "active" => ClaudeAgent::Schema.boolean("Is user active"),
}, required: ["name", "email"])

# Available schema types:
# - Schema.string(description, min_length:, max_length:, pattern:, format:)
# - Schema.integer(description, minimum:, maximum:)
# - Schema.number(description, minimum:, maximum:)  # for floats
# - Schema.boolean(description)
# - Schema.array(items_schema, description, min_items:, max_items:)
# - Schema.object(properties, required:, description:, additional_properties:)
# - Schema.enum(values, description)  # string literals
# - Schema.optional(schema)  # union with null
# - Schema.union(schema1, schema2, ...)  # oneOf

# Use with custom tool definition
my_tool = ClaudeAgent.tool(
  name: "create_user",
  description: "Creates a new user",
  schema: user_schema
) do |args|
  ClaudeAgent::ToolResult.text("Created user: #{args["name"]}")
end

# Or use with structured outputs (see Structured Outputs section)
```

### Hooks

Intercept tool usage to block or modify actions. All hook inputs include common context fields (`session_id`, `transcript_path`, `cwd`, `permission_mode`, `hook_event_name`) plus event-specific fields. The SDK supports all hook events:

| Event | Event-Specific Fields |
|-------|----------------------|
| **PreToolUse** | `tool_name`, `tool_input`, `tool_use_id` |
| **PostToolUse** | `tool_name`, `tool_input`, `tool_use_id`, `tool_result`/`tool_response` |
| **PostToolUseFailure** | `tool_name`, `tool_input`, `tool_use_id`, `error`, `is_interrupt` |
| **PermissionRequest** | `tool_name`, `tool_input`, `tool_use_id`, `permission_suggestions` |
| **Elicitation** | `mcp_server_name`, `elicitation_message`, `elicitation_mode`, `elicitation_url`, `elicitation_id`, `requested_schema` |
| **ElicitationResult** | `mcp_server_name`, `elicitation_action`, `elicitation_content`, `elicitation_id` |
| **PreCompact** | `trigger`, `custom_instructions` |
| **Notification** | `notification_message`, `notification_title`, `notification_type` |
| **UserPromptSubmit** | `user_prompt` |
| **Stop** | `stop_hook_active` |
| **SubagentStart** | `agent_id`, `agent_type` |
| **SubagentStop** | `agent_id`, `agent_type`, `agent_transcript_path`, `stop_hook_active` |
| **SessionStart** | `source` ("startup", "resume", "clear", "compact") |
| **SessionEnd** | `session_end_reason` ("clear", "logout", etc.) |

For local hook callbacks, `permission_mode` is normalized to the CLI-style values such as
`default`, `acceptEdits`, `plan`, and `bypassPermissions`.

`HookMatcher` also supports an optional `timeout` value in seconds for control-protocol hook registrations.

```crystal
# Block 'rm' commands (PreToolUse with tool_use_id)
block_rm = ->(input : ClaudeAgent::HookInput, id : String, ctx : ClaudeAgent::HookContext) {
  if input.tool_name == "Bash" && input.tool_input.try(&.["command"]?.try(&.as_s.includes?("rm")))
    ClaudeAgent::HookResult.deny("Deletion blocked by policy.")
  else
    ClaudeAgent::HookResult.allow
  end
}

# Audit tool executions (PostToolUse with tool_response and tool_input)
audit_hook = ->(input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
  puts "Tool: #{input.tool_name} (#{input.tool_use_id})"
  puts "Result: #{input.tool_result}"
  ClaudeAgent::HookResult.allow
}

# Archive transcript before compaction (PreCompact with transcript_path)
pre_compact_handler = ->(input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
  if path = input.transcript_path
    puts "Archiving transcript: #{path}"
    # File.copy(path, "/backups/#{input.session_id}.jsonl")
  end
  ClaudeAgent::HookResult.allow
}

hooks = ClaudeAgent::HookConfig.new(
  pre_tool_use: [ClaudeAgent::HookMatcher.new(matcher: "Bash", hooks: [block_rm], timeout: 15.0)],
  post_tool_use: [ClaudeAgent::HookMatcher.new(hooks: [audit_hook])],
  pre_compact: [pre_compact_handler],
)

options = ClaudeAgent::AgentOptions.new(hooks: hooks)
```

### Subagents

Define specialized agents that can be spawned by the main agent to handle focused subtasks.

```crystal
agents = {
  "code-reviewer" => ClaudeAgent::AgentDefinition.new(
    description: "Expert code reviewer",
    prompt: "You are an expert code reviewer. Analyze code for quality and issues.",
    tools: ["Read", "Glob", "Grep"],
    model: "sonnet"
  ),
  "test-writer" => ClaudeAgent::AgentDefinition.new(
    description: "Test case generator",
    prompt: "Generate comprehensive test cases.",
    tools: ["Read", "Write"],
    model: "haiku"
  ),
}

options = ClaudeAgent::AgentOptions.new(
  agents: agents,
  allowed_tools: ["Read", "Task"],  # Task tool required for spawning subagents
)
```


### External MCP Servers

Connect to external MCP (Model Context Protocol) servers to extend Claude's capabilities.

```crystal
# Build the MCP servers hash
mcp_servers = {} of String => ClaudeAgent::MCPServerConfig

# Stdio server (local process)
mcp_servers["playwright"] = ClaudeAgent::ExternalMCPServerConfig.stdio(
  "npx",
  ["-y", "@playwright/mcp@latest"]
)

# HTTP server (remote)
mcp_servers["docs"] = ClaudeAgent::ExternalMCPServerConfig.http(
  "https://code.claude.com/docs/mcp"
)

# SSE server (remote streaming)
mcp_servers["events"] = ClaudeAgent::ExternalMCPServerConfig.sse(
  "https://api.example.com/mcp/sse",
  headers: {"Authorization" => "Bearer token"}
)

options = ClaudeAgent::AgentOptions.new(
  mcp_servers: mcp_servers,
  # Allow all tools from these servers (wildcard pattern)
  allowed_tools: ["mcp__playwright__*", "mcp__docs__*", "mcp__events__*"]
)
```


### Structured Outputs

Get validated JSON responses matching your schema.

```crystal
# Define the output schema
schema = ClaudeAgent::Schema.object({
  "name"  => ClaudeAgent::Schema.string("User name"),
  "email" => ClaudeAgent::Schema.string("Email address"),
  "age"   => ClaudeAgent::Schema.integer("Age"),
}, required: ["name", "email"])

options = ClaudeAgent::AgentOptions.new(
  # Use the factory method - it handles conversion automatically
  output_format: ClaudeAgent::OutputFormat.json_schema(
    schema,
    name: "UserInfo",
    description: "Extracted user information"
  )
)

ClaudeAgent.query("Extract user info from: John Doe, john@example.com, 30", options) do |msg|
  if msg.is_a?(ClaudeAgent::ResultMessage)
    if structured = msg.structured_output
      puts structured.to_pretty_json
      # => {"name": "John Doe", "email": "john@example.com", "age": 30}
    end
  end
end
```

### Session Management

Resume, fork, and continue conversations.

```crystal
# Continue most recent conversation
options = ClaudeAgent::AgentOptions.new(
  continue_conversation: true
)

# Resume a specific session
options = ClaudeAgent::AgentOptions.new(
  resume: "session-uuid-here"
)

# Resume at a specific message (precise resume point)
options = ClaudeAgent::AgentOptions.new(
  resume: "session-uuid-here",
  resume_session_at: "message-uuid-here"
)

# Fork a session (create a branch)
options = ClaudeAgent::AgentOptions.new(
  resume: "session-uuid-here",
  fork_session: true
)
```

### Skills, Task Budgets, and System Prompts

Recent Claude Code releases add a handful of options that the SDK wires up
automatically.

```crystal
# Enable all installed skills (Skill(*) allow-rule). Also defaults
# setting_sources to ["user", "project"] so the CLI discovers them.
ClaudeAgent::AgentOptions.new(skills: "all")

# Or restrict to a named set
ClaudeAgent::AgentOptions.new(skills: ["git", "playwright"])

# Cache-friendly preset: strips per-user dynamic sections from the prompt.
ClaudeAgent::AgentOptions.new(
  system_prompt: ClaudeAgent::SystemPromptPreset.claude_code(
    "Focus on code review.",
    true, # exclude_dynamic_sections
  ),
)

# Load the system prompt from a file.
ClaudeAgent::AgentOptions.new(
  system_prompt: ClaudeAgent::SystemPromptFile.new("./prompts/reviewer.md"),
)

# API-side token budget awareness and a fixed session title.
ClaudeAgent::AgentOptions.new(
  task_budget: ClaudeAgent::TaskBudget.new(120_000),
  title: "refactor session",
)
```

### Pre-warming and Context Usage

```crystal
# Start the subprocess while you prepare the first prompt.
client = ClaudeAgent.startup(ClaudeAgent::AgentOptions.new)

client.query("Return OK")
client.each_response { |msg| puts msg if msg.is_a?(ClaudeAgent::ResultMessage) }

# Inspect context window usage (requires a CLI that supports it).
usage = client.get_context_usage
puts "#{usage.total_tokens}/#{usage.max_tokens} (#{usage.percentage.round(1)}%)"
usage.categories.each { |cat| puts "  #{cat.name}: #{cat.tokens}" }

client.stop
```

### Runtime MCP and Plugin Management

```crystal
ClaudeAgent::AgentClient.open do |client|
  client.reload_plugins           # refresh plugin directory
  client.prompt_suggestion        # ask the CLI for a next-step suggestion

  # Lazily activate an MCP server that advertises its tools channel on demand.
  client.enable_mcp_channel("playwright")

  # Replace the active MCP server set without restarting the subprocess.
  client.set_mcp_servers({
    "fetch" => JSON::Any.new({
      "type" => JSON::Any.new("http"),
      "url"  => JSON::Any.new("https://example.com/mcp"),
    }),
  })
end
```

### Transcript Controls

```crystal
ClaudeAgent::AgentClient.open do |client|
  # Seed context without triggering an assistant turn.
  client.send_user_message("Remember: my favourite colour is teal.", should_query: false)
  client.query("What is my favourite colour?")
end

# Include system entries (tool results, status lines) when replaying history.
ClaudeAgent.get_session_messages(
  "session-uuid",
  directory: Dir.current,
  include_system_messages: true,
)
```

### Session Forks and Subagents

```crystal
# Fork a session into a new branch with fresh UUIDs. Optionally slice the
# transcript up to a specific message UUID and give the fork its own title.
fork = ClaudeAgent.fork_session(
  "session-uuid",
  directory: Dir.current,
  up_to_message_id: "message-uuid",
  title: "experimental branch",
)
puts fork.session_id

# Discover subagents that were spawned inside a session and read a transcript.
ClaudeAgent.list_subagents("session-uuid", directory: Dir.current).each do |agent_id|
  messages = ClaudeAgent.get_subagent_messages(
    "session-uuid",
    agent_id,
    directory: Dir.current,
  )
  puts "#{agent_id}: #{messages.size} messages"
end

# Delete a session plus its sibling subagent transcript directory.
ClaudeAgent.delete_session("session-uuid", directory: Dir.current)
```

### Session History

List saved sessions and read the top-level user/assistant messages from a transcript.
You can also look up a single session and mutate session metadata.

```crystal
# List recent sessions for the current project
sessions = ClaudeAgent.list_sessions(directory: Dir.current, limit: 10)
sessions.each do |session|
  puts "#{session.summary} (#{session.session_id})"
end

# Read messages from a specific session transcript
messages = ClaudeAgent.get_session_messages(
  "session-uuid-here",
  directory: Dir.current,
  limit: 20,
  offset: 0
)

messages.each do |message|
  puts "#{message.type}: #{message.message[\"content\"]?}"
end

# Look up one session directly
info = ClaudeAgent.get_session_info("session-uuid-here", directory: Dir.current)
puts info.try(&.summary)

# Rename or tag a session
ClaudeAgent.rename_session("session-uuid-here", "Refactor investigation", directory: Dir.current)
ClaudeAgent.tag_session("session-uuid-here", "experiment", directory: Dir.current)

# Clear a tag
ClaudeAgent.tag_session("session-uuid-here", nil, directory: Dir.current)
```

### File Checkpointing

Track and rewind file changes.

```crystal
options = ClaudeAgent::AgentOptions.new(
  enable_file_checkpointing: true,
  replay_user_messages: true,
  permission_mode: ClaudeAgent::PermissionMode::AcceptEdits
)

checkpoint_uuid = nil

ClaudeAgent::AgentClient.open(options) do |client|
  client.query("Create a file named test.txt")

  client.each_response do |msg|
    if msg.is_a?(ClaudeAgent::UserMessage) && msg.uuid
      checkpoint_uuid = msg.uuid  # Save checkpoint
    end
  end

  # Later: rewind to checkpoint
  client.rewind_files(checkpoint_uuid.not_nil!) if checkpoint_uuid
end
```

### Sandbox Configuration

Configure sandboxed execution environments for safer operation.

```crystal
sandbox = ClaudeAgent::SandboxSettings.new(
  enabled: true,
  auto_allow_bash_if_sandboxed: true,
  excluded_commands: ["rm", "sudo"],
  network: ClaudeAgent::SandboxNetworkSettings.new(
    allow_local_binding: true,
    http_proxy_port: 8080
  )
)

options = ClaudeAgent::AgentOptions.new(
  sandbox: sandbox
)
```

### Extended Thinking

Control extended thinking behavior with the typed `thinking` config plus
`effort`, or the legacy `max_thinking_tokens` option.

- `ThinkingConfig.adaptive` → `--thinking adaptive`
- `ThinkingConfig.disabled` → `--thinking disabled`
- `ThinkingConfig.enabled(n)` → `--max-thinking-tokens n`

```crystal
# Opus 4.7 defaults to xhigh effort inside Claude Code; other tiers are still
# available for backing off to lower latency or dialing up Max effort.
options = ClaudeAgent::AgentOptions.new(
  model: "claude-opus-4-7",
  thinking: ClaudeAgent::ThinkingConfig.adaptive,
  effort: ClaudeAgent::Effort::Xhigh,
)

# Explicit budget with the classic flag
options = ClaudeAgent::AgentOptions.new(
  thinking: ClaudeAgent::ThinkingConfig.enabled(10_000),
)

# Legacy fallback still works
legacy = ClaudeAgent::AgentOptions.new(
  max_thinking_tokens: 10_000,
)
```

### Interrupt and Dynamic Control

Interrupt an ongoing run, swap models mid-conversation, inspect live state,
and request a fresh context usage breakdown — all against an already-started
client.

```crystal
require "claude-agent-cr"

ClaudeAgent::AgentClient.open do |client|
  # Kick off a long-running task
  client.query("Count from 1 to 100 slowly, one line at a time.")

  spawn do
    sleep 2.seconds
    client.interrupt            # Signal the CLI to stop current operation
  end

  client.each_response do |message|
    puts message.text if message.is_a?(ClaudeAgent::AssistantMessage) && message.has_text?
    break if message.is_a?(ClaudeAgent::ResultMessage)
  end

  # Follow up immediately after the interrupt
  client.query("Just say hello.")
  client.each_response do |message|
    puts message.text if message.is_a?(ClaudeAgent::AssistantMessage) && message.has_text?
    break if message.is_a?(ClaudeAgent::ResultMessage)
  end

  # Swap settings live
  client.set_permission_mode(ClaudeAgent::PermissionMode::AcceptEdits)
  client.set_model("claude-opus-4-7")

  # Inspect initialization metadata and live session state
  if info = client.get_server_info
    puts "Commands available: #{info.commands.size}"
    puts "Output style: #{info.output_style || "default"}"
  end

  mcp_status = client.get_mcp_status
  mcp_status.mcp_servers.each do |server|
    puts "MCP #{server.name}: #{server.status}"
  end

  # Context window usage (requires a CLI that supports `get_context_usage`)
  begin
    usage = client.get_context_usage
    puts "#{usage.total_tokens}/#{usage.max_tokens} tokens (#{usage.percentage.round(1)}%)"
    usage.categories.each { |category| puts "  #{category.name}: #{category.tokens}" }
  rescue ex
    puts "Context usage not available on this CLI: #{ex.message}"
  end

  # Refresh plugins / MCP servers without restarting the subprocess
  client.reload_plugins
  client.enable_mcp_channel("playwright") # only needed for lazy servers

  # Cancel a queued follow-up message before the model processes it
  queued = UUID.random.to_s
  client.send_user_message("Queued follow-up", uuid: queued)
  puts "Cancelled queued message: #{client.cancel_async_message(queued)}"
end
```

### Error Handling

Every SDK error inherits from `ClaudeAgent::Error`. Rescue the specific
subclasses for actionable error handling, or the base class to catch
everything.

```crystal
require "claude-agent-cr"

begin
  ClaudeAgent::AgentClient.open do |client|
    client.query("Hello")

    client.each_response do |message|
      case message
      when ClaudeAgent::AssistantMessage
        puts message.text if message.has_text?
      when ClaudeAgent::ResultMessage
        break
      end
    end
  end
rescue ex : ClaudeAgent::CLINotFoundError
  # Claude Code CLI is not installed or not on PATH.
  STDERR.puts "Install Claude Code: curl -fsSL https://claude.ai/install.sh | bash"
  STDERR.puts "Attempted CLI path: #{ex.cli_path}" if ex.cli_path
rescue ex : ClaudeAgent::ProcessError
  # Subprocess exited with a non-zero status; `exit_code` and `stderr` are set.
  STDERR.puts "CLI exited #{ex.exit_code}: #{ex.stderr}"
rescue ex : ClaudeAgent::ConnectionError
  # Subprocess failed to start, the control-protocol handshake failed, or a
  # pending request was cancelled mid-flight.
  STDERR.puts "Connection error: #{ex.message}"
rescue ex : ClaudeAgent::JSONDecodeError
  # A stream-json line could not be parsed. `raw_data` preserves the payload.
  STDERR.puts "Malformed CLI output: #{ex.raw_data}"
rescue ex : ClaudeAgent::PermissionDeniedError
  # A tool request was denied and the SDK surfaced it as a hard error.
  STDERR.puts "Permission denied for #{ex.tool_name}: #{ex.message}"
rescue ex : ClaudeAgent::TimeoutError
  STDERR.puts "Timed out waiting for Claude Code: #{ex.message}"
rescue ex : ClaudeAgent::ConfigurationError
  STDERR.puts "Invalid SDK configuration: #{ex.message}"
rescue ex : ClaudeAgent::Error
  # Catch-all for any other SDK-level error.
  STDERR.puts "SDK error: #{ex.message}"
end
```

### ClaudeAgent::AgentOptions Reference

A single place to see every configuration knob the SDK exposes. Every field
is optional; uncomment or remove the ones you don't need.

```crystal
require "claude-agent-cr"

options = ClaudeAgent::AgentOptions.new(
  # --- Core model + system prompt ----------------------------------------
  model: "claude-opus-4-7",              # alias or full model ID
  fallback_model: "claude-haiku-4-5",    # used on rate-limit or model failure
  system_prompt: "You are a helpful assistant.", # String, preset, or file:
  # system_prompt: ClaudeAgent::SystemPromptPreset.claude_code(
  #   "Always use Crystal best practices.",
  #   true, # exclude_dynamic_sections -> cacheable prefix across users
  # ),
  # system_prompt: ClaudeAgent::SystemPromptFile.new("./prompt.md"),
  append_system_prompt: "Prefer standard library APIs.",

  # --- Tools ---------------------------------------------------------------
  tools: ClaudeAgent::ToolsPreset.claude_code,        # or Array(String)
  allowed_tools: ["Read", "Glob", "Grep", "Task"],
  disallowed_tools: ["Bash"],
  skills: "all",                                       # or ["git", "playwright"]

  # --- Permissions ---------------------------------------------------------
  permission_mode: ClaudeAgent::PermissionMode::AcceptEdits,
  # Other modes: Default, Plan, BypassPermissions, Auto, DontAsk
  allow_dangerously_skip_permissions: false,
  permission_prompt_tool_name: nil,                    # delegate prompts to a tool
  can_use_tool: nil,                                   # PermissionCallback

  # --- Budgets & turn limits ----------------------------------------------
  max_turns: 10,
  max_budget_usd: 1.0,
  task_budget: ClaudeAgent::TaskBudget.new(120_000),  # API-side token budget
  title: "refactor session",                           # fixed session title

  # --- Extended thinking ---------------------------------------------------
  thinking: ClaudeAgent::ThinkingConfig.adaptive,      # adaptive | enabled(n) | disabled
  effort: ClaudeAgent::Effort::Xhigh,                  # Low | Medium | High | Xhigh | Max
  max_thinking_tokens: nil,                            # legacy fallback

  # --- MCP servers ---------------------------------------------------------
  mcp_servers: {
    "playwright" => ClaudeAgent::ExternalMCPServerConfig.stdio(
      "npx", ["-y", "@playwright/mcp@latest"],
    ).as(ClaudeAgent::MCPServerConfig),
  },
  strict_mcp_config: false,

  # --- Subagents -----------------------------------------------------------
  agents: {
    "reviewer" => ClaudeAgent::AgentDefinition.new(
      description: "Read-only code reviewer",
      prompt: "Audit code without modifying it.",
      tools: ["Read", "Glob", "Grep"],
      disallowed_tools: ["Bash", "Write", "Edit"],
      model: "sonnet",
      max_turns: 3,
    ),
  },
  agent: "reviewer",                                   # boot a specific subagent

  # --- Hooks & async features ---------------------------------------------
  hooks: ClaudeAgent::HookConfig.new,                  # (register matchers here)
  on_elicitation: nil,                                 # MCP user-input callback
  prompt_suggestions: true,
  agent_progress_summaries: true,
  include_partial_messages: true,                      # + fine-grained streaming
  replay_user_messages: false,

  # --- Output & structured responses --------------------------------------
  output_format: nil,                                  # OutputFormat.json_schema(...)

  # --- CLI / environment ---------------------------------------------------
  cli_path: nil,                                       # override discovery
  env: {"CLAUDE_AGENT_TRACING" => "1"},
  betas: ["extended-thinking-2025-01-24"],
  add_dirs: ["./vendor"],
  plugins: ["./plugins/my-plugin"],
  cwd: Dir.current,
  user: "alice",
  stderr: ->(line : String) { STDERR.puts(line) },     # observe CLI stderr
  max_buffer_size: nil,                                # override stream buffer

  # --- Settings sources ----------------------------------------------------
  setting_sources: ["user", "project"],                # [] disables all
  settings_path: nil,                                  # explicit settings.json

  # --- Session management --------------------------------------------------
  continue_conversation: false,
  resume: nil,                                         # session ID to resume
  resume_session_at: nil,                              # message UUID to resume from
  session_id: nil,                                     # explicit session ID
  fork_session: false,                                 # fork on resume
  no_session_persistence: false,

  # --- Safety & checkpointing ---------------------------------------------
  enable_file_checkpointing: true,
  sandbox: ClaudeAgent::SandboxSettings.new(enabled: true),
)

ClaudeAgent.query("Review the current directory.", options) do |message|
  puts message
end
```

## Status

> Developed against Claude Code CLI **v2.1.84+**. The SDK is forward-compatible:
> features that require newer CLI versions are gracefully no-op or surface a
> clear error on older CLIs.

| Feature | Status | Notes |
|---------|--------|-------|
| One-shot queries | ✅ Working | Single-turn queries work reliably |
| Interactive sessions | ✅ Working | Multi-turn conversations with tool use |
| Custom tools (in-process) | ✅ Working | SDK MCP servers via control protocol |
| External MCP Servers | ✅ Working | Stdio, HTTP, and SSE transports |
| Runtime MCP Management | ✅ Working | `set_mcp_servers`, `enable_mcp_channel`, `reload_plugins` |
| Schema Builder | ✅ Working | Type-safe JSON schema generation |
| Hooks | ✅ Working | PreToolUse, PostToolUse, PreCompact, Notification, TeammateIdle, TaskCompleted, ConfigChange, and more |
| V2 Streaming | ✅ Working | Send/receive patterns |
| Subagents | ✅ Working | Rich `AgentDefinition` fields for specialized agents |
| Structured Outputs | ✅ Working | JSON schema validation |
| Session Management | ✅ Working | Resume, fork, continue, resume_session_at, delete |
| Session Fork / Subagent Transcripts | ✅ Working | `fork_session`, `list_subagents`, `get_subagent_messages`, `delete_session` |
| Dynamic Controls | ✅ Working | Model, permissions, MCP status, flag settings, remote control, proactive mode, session titles, `get_context_usage`, `prompt_suggestion` |
| Permission Modes | ✅ Working | `default`, `acceptEdits`, `plan`, `bypassPermissions`, `auto`, `dontAsk` |
| Skills | ✅ Working | `"all"` or a named list; auto-injects `Skill`/`Skill(name)` and default setting sources |
| Task Budgets | ✅ Working | `task_budget` + `title` options |
| System Prompt Variants | ✅ Working | Strings, `SystemPromptPreset` (with `exclude_dynamic_sections`), and `SystemPromptFile` |
| Server Info | ✅ Working | Access initialization metadata like commands and output styles |
| Rich Event Messages | ✅ Working | Typed init/task/rate-limit/prompt-suggestion/elicitation events, `ApiRetryMessage`, `MemoryRecallMessage`, `StatusMessage`, `MirrorErrorMessage`, and unknown-message fallback |
| Hook Propagation | ✅ Working | Hook callbacks can modify inputs and return CLI hook outputs |
| Permission Propagation | ✅ Working | Permission callbacks can update input, permissions, interrupt; context now exposes `tool_use_id`, `agent_id`, `blocked_path` |
| Session History | ✅ Working | List, inspect, rename, and tag local sessions |
| File Checkpointing | ✅ Working | Track and rewind file changes |
| Sandbox Configuration | ✅ Working | Full sandbox settings support |
| Extended Thinking | ✅ Working | `thinking` (adaptive/enabled/disabled), `effort` (including `xhigh`), `max_thinking_tokens` |
| Pre-warming | ✅ Working | `ClaudeAgent.startup` starts the CLI without sending a prompt |
| Trace Propagation | ✅ Working | Forwards `TRACEPARENT`/`TRACESTATE` env vars to the CLI |
| Unknown Content Types | ✅ Working | Graceful handling of future content block types |
| Compact Boundary | ✅ Working | Detect when CLI compacts session history |

### Handling Compact Boundaries

When the CLI compacts a session, it emits a `CompactBoundaryMessage`:

```crystal
client.each_response do |message|
  case message
  when ClaudeAgent::CompactBoundaryMessage
    puts "Session compacted: #{message.compact_metadata.trigger}"
    puts "Pre-compaction tokens: #{message.compact_metadata.pre_tokens}"
  end
end
```

### Tool Use ID Access

Tool use IDs are available on `ToolUseBlock` within `AssistantMessage.content`:

```crystal
when ClaudeAgent::AssistantMessage
  message.content.each do |block|
    if block.is_a?(ClaudeAgent::ToolUseBlock)
      puts "Tool: #{block.name}, ID: #{block.id}"
    end
  end
end
```

### Thinking Content Access

For extended thinking models, `ResultMessage.stop_reason` is also available
to inspect why the turn ended.

```crystal
when ClaudeAgent::AssistantMessage
  message.content.each do |block|
    case block
    when ClaudeAgent::ThinkingBlock
      puts "Thinking: #{block.thinking}"
    when ClaudeAgent::RedactedThinkingBlock
      puts "Redacted thinking (signature present)"
    end
  end
when ClaudeAgent::ResultMessage
  puts "Stop reason: #{message.stop_reason}"
end
```

When `include_partial_messages` is enabled, the SDK also opts into
fine-grained tool streaming so `StreamEvent` payloads can include incremental
delta events such as `content_block_delta` and `input_json_delta` when the CLI
emits them.

## Changelog

### 0.5.0

- **New**: `skills` option on `AgentOptions` accepting `"all"`, a list of skill names, or an empty list; automatically injects `Skill`/`Skill(name)` entries into `allowed_tools` and defaults `setting_sources` to `["user","project"]`
- **New**: `SystemPromptFile` variant for `--system-prompt-file`, and `exclude_dynamic_sections` on `SystemPromptPreset` for cacheable prompts
- **New**: `task_budget` option (`--task-budget`) and `title` option (`--title`)
- **New**: `PermissionMode::Auto` and `PermissionMode::DontAsk`
- **New**: `Effort::Xhigh` tier, which Claude Code uses as the default for Claude Opus 4.7
- **New**: Thinking config now maps to the correct CLI flags: `--thinking adaptive`, `--thinking disabled`, or `--max-thinking-tokens <n>` for `enabled`
- **New**: Expanded `AgentDefinition` fields — `disallowed_tools`, `skills`, `memory`, `mcp_servers`, `initial_prompt`, `max_turns`, `background`, `effort`, `permission_mode`
- **New**: Runtime MCP / plugin control methods — `AgentClient#get_context_usage`, `reload_plugins`, `prompt_suggestion`, `set_mcp_servers`, `enable_mcp_channel`
- **New**: Typed `ContextUsageResponse` with per-category token usage, model info, and autocompact thresholds
- **New**: Session helpers — `ClaudeAgent.fork_session`, `ClaudeAgent.delete_session`, `ClaudeAgent.list_subagents`, `ClaudeAgent.get_subagent_messages`
- **New**: `include_system_messages` option on `ClaudeAgent.get_session_messages`
- **New**: `should_query: false` on `send_user_message` / `query` appends a message without triggering an assistant turn
- **New**: `ClaudeAgent.startup` pre-warms the Claude Code subprocess and returns a ready `AgentClient`
- **New**: Additional hook events — `TeammateIdle`, `TaskCompleted`, `ConfigChange`
- **New**: `PermissionContext` gains `tool_use_id`, `agent_id`, and `blocked_path`
- **New**: `ResultMessage` gains `terminal_reason` and `errors` fields
- **New**: Typed system messages — `ApiRetryMessage`, `MemoryRecallMessage`, `StatusMessage` (for the `requesting` status), and top-level `MirrorErrorMessage`
- **New**: `InitMessage#memory_paths` accessor; `MCPServerStatus` gains `capabilities`
- **New**: Automatic W3C trace context propagation (`TRACEPARENT` / `TRACESTATE`)
- **New**: Empty `setting_sources=[]` now emits a single `--setting-sources=` token instead of being misparsed
- **New**: Eight new examples — 33 (session forks & subagents), 34 (advanced subagent definitions), 35 (auto/dontAsk permission modes), 36 (transcript controls), 37 (forward-compatible options), 38 (context usage + startup), 39 (new hooks), 40 (runtime MCP/plugin controls)

### 0.4.0

- **New**: Session history helpers: `ClaudeAgent.list_sessions`, `ClaudeAgent.get_session_info`, and `ClaudeAgent.get_session_messages`
- **New**: Session metadata mutation helpers: `ClaudeAgent.rename_session` and `ClaudeAgent.tag_session`
- **New**: Dynamic control APIs: `set_permission_mode`, `set_model`, `get_mcp_status`, `reconnect_mcp_server`, `toggle_mcp_server`, `stop_task`, `apply_flag_settings`, `enable_remote_control`, `set_proactive`, `generate_session_title`
- **New**: `get_server_info` for initialization metadata like commands and output styles
- **New**: Richer system/event message typing: `InitMessage`, `TaskStartedMessage`, `TaskProgressMessage`, `TaskNotificationMessage`, `UnknownMessage`
- **New**: Typed `RateLimitEvent` and `RateLimitInfo`
- **Improved**: `include_partial_messages` now enables fine-grained tool streaming for richer `StreamEvent` deltas
- **New**: TypeScript-parity `prompt_suggestions`, `PromptSuggestionMessage`, `settings`, and `cancel_async_message`
- **New**: TypeScript-parity MCP elicitation callbacks, hook events, and `ElicitationCompleteMessage`
- **New**: Typed thinking config support (`thinking`, `effort`) and `ResultMessage.stop_reason`
- **New**: Optional live E2E specs covering dynamic controls, session history, hook overrides, task events, structured output, and typed init metadata
- **Improved**: Hook matcher timeout support and initialization payload parity for hooks and agents
- **Improved**: Hook and permission callbacks now propagate runtime updates through the CLI control protocol

### 0.3.0

- **New**: Common context fields on all `HookInput` events: `session_id`, `transcript_path`, `cwd`, `permission_mode`, `hook_event_name`
- **New**: Event-specific fields matching official SDKs: `tool_use_id`, `tool_response`, `error`, `is_interrupt`, `stop_hook_active`, `agent_id`, `agent_type`, `agent_transcript_path`, `notification_type`, `source`, `session_end_reason`, `permission_suggestions`
- **New**: `PermissionRequest` hook event for visibility into permission dialogs
- **New**: `CompactBoundaryMessage` type for detecting session compaction (TypeScript SDK feature)
- **New**: Examples for hook lifecycle (20), tool auditing (21), PreCompact archiving (22), and PermissionRequest (23)
- For control protocol hooks, CLI-provided values (e.g., `transcript_path`) take precedence over locally-derived values

**Notes on requested features vs official SDKs:**
- `error_type`/`error_code` fields in ResultMessage: **Not in official SDKs** - use `subtype` and `is_error` instead
- `SessionInfo` with `message_count`/`current_tokens`: **Not in official SDKs** - use `num_turns` and `usage` on ResultMessage
- `AssistantMessage.tool_use_id`: **Not in official SDKs** - access via `ToolUseBlock.id` in content blocks

### 0.2.0

- **New**: `UnknownBlock` for graceful handling of unknown content block types (forward-compatible)
- **New**: `Notification` hook for agent status updates (forward to Slack, dashboards, etc.)
- **New**: `resume_session_at` option for precise message-level session resumption
- **New**: `HookInput` fields for PreCompact (`trigger`, `custom_instructions`) and Notification (`notification_message`, `notification_title`)
- **Fix**: ControlHookCallbackRequest now properly dispatched (PreCompact and other hooks now work)
- **Fix**: Hook callback routing improved with proper input field extraction

## Verified Examples

The following examples have been tested and verified with CLI v2.1.84:

- One-shot queries and streaming (examples 01, 02, 03)
- Tool restrictions and permission modes (examples 04, 05)
- Permission callbacks and SDK MCP servers (examples `06_permission_callback`, `06_sdk_mcp_server`)
- Interactive sessions, permission handling, and chat flows (examples 07, 08, 09, 10)
- Local tool definitions and MCP server testing (examples 11, 12)
- Hooks, audit hooks, and lifecycle hooks (examples 13, 20, 21, 22, 28)
- V2 streaming sessions (example 14)
- Subagents and rich task events (examples 15, 27)
- Structured JSON output (example 16)
- Playwright MCP integration (example 17)
- Session history, dynamic controls, and server info (examples 25, 26, 29)
- Session mutation APIs (example 30)
- Prompt suggestions and async message controls (example 31)
- MCP elicitation callback surface (example 32)
- Session fork / subagent transcript helpers (example 33)
- Expanded `AgentDefinition` fields (example 34)
- Auto/DontAsk permission modes and rich permission context (example 35)
- Transcript controls — `should_query`, `include_system_messages` (example 36)
- Forward-compatible options — skills, task_budget, title, SystemPromptFile (example 37)
- `get_context_usage` + `startup` pre-warming (example 38)
- New hook events — TeammateIdle, TaskCompleted, ConfigChange (example 39)
- Runtime MCP + plugin controls (example 40)

Examples with environment-dependent behavior:

- `examples/18_mcp_github.cr` requires `GITHUB_TOKEN`
- `examples/19_mcp_remote.cr` depends on remote MCP availability
- `examples/23_hook_permission_request.cr` only shows the hook when Claude would actually prompt for permission in the current environment
- `examples/32_elicitation_support.cr` requires `ELICITATION_MCP_URL` and a compatible MCP server that actually requests user input
- `examples/38_context_usage.cr`, `examples/39_new_hooks.cr`, and `examples/40_mcp_runtime.cr` exercise features that require a newer Claude Code CLI; older CLIs degrade gracefully

Quick guide:

- Best local/default examples: `01`, `02`, `07`, `14`, `16`, `25`, `26`, `27`, `28`, `29`, `31`, `33`, `36`, `37`
- Best hook-focused examples: `13`, `20`, `21`, `22`, `23`, `28`, `39`
- Best MCP-focused examples: `06_sdk_mcp_server`, `12`, `17`, `18`, `19`, `40`
- Best session-focused examples: `25`, `30`, `33`, `36`

## Optional Live E2E Specs

The main spec suite is deterministic and does not require a live Claude connection.
For parity-critical live checks against the real Claude CLI, run:

```bash
CLAUDE_AGENT_RUN_E2E=1 crystal spec spec/e2e_spec.cr
```

These optional E2E specs cover live initialization metadata, dynamic controls,
session history, hook-based tool input overrides, rich task events,
structured outputs, and typed init-message metadata.

## Contributing

1.  Fork it (<https://github.com/amscotti/claude-agent-cr/fork>)
2.  Create your feature branch (`git checkout -b my-new-feature`)
3.  Commit your changes (`git commit -am 'Add some feature'`)
4.  Push to the branch (`git push origin my-new-feature`)
5.  Create a new Pull Request

## License

MIT
