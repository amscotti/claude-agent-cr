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
*   **File Checkpointing**: Track and rewind file changes, plus `rewind_conversation` to truncate the transcript itself.
*   **Sandbox Support**: Configure sandboxed execution environments, including credential masking/denial via `sandbox.credentials`.
*   **Managed Settings**: Pass policy-tier settings to the CLI in-memory via `managed_settings` (honored below IT-controlled managed sources).
*   **Subagent Streaming**: `forward_subagent_text` streams subagent text deltas into the SDK message stream.
*   **Plugin Configs**: `PluginConfig` with per-plugin `skip_mcp_discovery` for hosts that manage a plugin's MCP connections themselves.
*   **Extended Thinking**: `ThinkingConfig.adaptive` / `enabled` / `disabled` (with `display` support for `"summarized"` / `"omitted"` thinking blocks), plus fine-grained `effort` tiers (`Low`, `Medium`, `High`, `Xhigh`, `Max`) — `xhigh` is the default Claude Code tier for Opus 4.7.
*   **Pre-warming**: `ClaudeAgent.startup` spins up the CLI subprocess ahead of the first query.
*   **Tracing**: Automatic W3C trace context propagation (`TRACEPARENT` / `TRACESTATE`) when present in the caller's environment.
*   **Streaming**: Real-time message streaming using Crystal's native fibers.
*   **Type Safety**: Fully typed message and event structures, including `TaskUpdatedMessage` (with `TERMINAL_TASK_STATUSES`), `tool_use_meta` sidecar, `stop_details`/`refusal?`, `ApiRetryMessage`, `MemoryRecallMessage`, `StatusMessage`, and `MirrorErrorMessage`, with graceful handling of unknown content types.

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
        version: ~> 0.8.0
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
    when ClaudeAgent::TaskUpdatedMessage
      # Background tasks can finish ONLY via this message (e.g. a task
      # stopped via TaskStop reports status="killed" here, with no
      # TaskNotification). Clear active-task bookkeeping on a terminal status.
      puts "Task updated: #{message.task_id} status=#{message.status} " \
           "(terminal=#{message.terminal?})"
    when ClaudeAgent::RateLimitEvent
      puts "Rate limit status: #{message.rate_limit_info.status}"
    when ClaudeAgent::ElicitationCompleteMessage
      puts "Elicitation complete for #{message.mcp_server_name}"
    when ClaudeAgent::PromptSuggestionMessage
      puts "Suggestion: #{message.suggestion}"
    when ClaudeAgent::AssistantMessage
      # Refusal detection without text-matching the content:
      if message.refusal?
        details = message.stop_details
        puts "Refused: #{details.try(&.category)} — #{details.try(&.explanation)}"
      end

      # Display-friendly labels for tool calls (CLI v2.1.179+). The
      # sidecar is an array of per-block entries; use #tool_use_meta_for
      # to look one up by tool_use block id.
      message.tool_use_meta.try &.each do |meta|
        puts "Tool call: #{meta.display_name} (#{meta.id})"
      end
    when ClaudeAgent::ResultMessage
      # What triggered this result — an object like {"kind": "human"} or
      # {"kind": "task-notification"}:
      puts "Done: #{message.subtype} (origin=#{message.origin.try(&.kind) || "unknown"})"
    when ClaudeAgent::UnknownMessage
      puts "Unknown event type: #{message.type}"
    end
  end
end
```

> **Background task lifecycle:** a task's terminal state can arrive *only* as a
> `TaskUpdatedMessage` with no accompanying `TaskNotificationMessage`. Use
> `message.terminal?` or the `ClaudeAgent::TERMINAL_TASK_STATUSES` set
> (`completed`, `failed`, `stopped`, `killed`) to clear active-task tracking
> from either message type.

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

Define custom tools that run in-process using the SDK MCP server architecture. This allows you to expose Crystal-native methods directly to the Claude agent, running in the same process without external network calls or separate tool processes.

#### 1. Designing and Defining Tools

Tools are defined using `ClaudeAgent.tool`, which takes a name, description, and an input validation schema constructed via the type-safe `Schema` builder. 

```crystal
require "claude-agent-cr"

greet_tool = ClaudeAgent.tool(
  name: "greet",
  description: "Greet a user by name",
  schema: ClaudeAgent::Schema.object({
    "name" => ClaudeAgent::Schema.string("The name to greet"),
  }, required: ["name"])
) do |args|
  # Access typed arguments from the parsed input hash
  name = args["name"].as_s
  ClaudeAgent::ToolResult.text("Hello, #{name}!")
end
```

#### 2. Robust In-Tool Error Handling

When writing custom tools, **never let unhandled exceptions escape the tool block**. An unhandled exception inside a tool handler will crash the background reader fiber, causing the control-protocol connection to sever and aborting the session. 

Instead, always capture internal exceptions and return a structured tool error response using `is_error: true`. This notifies the Claude model of the failure, allowing it to correct the arguments or report the issue back to the user cleanly.

```crystal
require "json"
require "claude-agent-cr"

fetch_data_tool = ClaudeAgent.tool(
  name: "fetch_data",
  description: "Fetch JSON data from a mock service",
  schema: ClaudeAgent::Schema.object({
    "id" => ClaudeAgent::Schema.string("The record identifier to retrieve"),
  }, required: ["id"])
) do |args|
  record_id = args["id"].as_s
  
  begin
    # Simulate an operation that could fail (e.g. database lookup or network call)
    if record_id == "404"
      raise "Record #{record_id} not found in database"
    end
    
    data = {"id" => record_id, "status" => "active", "timestamp" => Time.local.to_s}
    ClaudeAgent::ToolResult.text(data.to_json)
  rescue ex
    # Capture any error and safely return it as a tool error
    ClaudeAgent::ToolResult.text(
      content: "Failed to fetch data: #{ex.message}",
      is_error: true
    )
  end
end
```

#### 3. Complete End-to-End Working Example

Below is a complete, copy-pasteable script demonstrating how to import the SDK, define a custom calculator tool, handle tool failures safely, bundle them into an SDK MCP server, and execute an agent turn with comprehensive parent-level error handling.

```crystal
require "json"
require "claude-agent-cr"

# 1. Define a tool with strict schema and internal error handling
divide_tool = ClaudeAgent.tool(
  name: "divide",
  description: "Divide two numbers",
  schema: ClaudeAgent::Schema.object({
    "numerator"   => ClaudeAgent::Schema.number("The top number"),
    "denominator" => ClaudeAgent::Schema.number("The bottom number"),
  }, required: ["numerator", "denominator"])
) do |args|
  begin
    num = args["numerator"].as_f
    den = args["denominator"].as_f
    
    if den == 0.0
      raise "Cannot divide by zero"
    end
    
    result = num / den
    ClaudeAgent::ToolResult.text("#{num} / #{den} = #{result}")
  rescue ex
    # Return error back to Claude so it knows not to divide by zero next time
    ClaudeAgent::ToolResult.text("Error: #{ex.message}", is_error: true)
  end
end

# 2. Bundle the tool into an SDK MCP server config
sdk_server = ClaudeAgent.create_sdk_mcp_server(
  name: "math-engine",
  tools: [divide_tool]
)

mcp_servers = {} of String => ClaudeAgent::MCPServerConfig
mcp_servers["math-engine"] = sdk_server

# 3. Configure the Agent options
options = ClaudeAgent::AgentOptions.new(
  model: "claude-sonnet-4-5",
  mcp_servers: mcp_servers,
  # Tool names follow the namespacing rule: mcp__<server_name>__<tool_name>
  allowed_tools: ["mcp__math-engine__divide"],
  permission_mode: ClaudeAgent::PermissionMode::AcceptEdits
)

# 4. Start the agent client and execute with robust connection/CLI error handling
begin
  puts "Booting Claude Agent with custom tools..."
  
  ClaudeAgent::AgentClient.open(options) do |client|
    client.query("Divide 10 by 2, and then divide 5 by 0.")
    
    client.each_response do |message|
      case message
      when ClaudeAgent::AssistantMessage
        # Print Claude's reasoning and responses
        print message.text if message.has_text?
      when ClaudeAgent::ResultMessage
        puts "\n[Result] Turn finished with status: #{message.subtype}"
      end
    end
  end
rescue ex : ClaudeAgent::CLINotFoundError
  STDERR.puts "Fatal: Claude Code CLI is not installed or not in PATH."
rescue ex : ClaudeAgent::UnsupportedOptionError
  STDERR.puts "Fatal: CLI rejected options: #{ex.option}. Try running `claude upgrade`."
rescue ex : ClaudeAgent::ProcessError
  STDERR.puts "Fatal: Claude process exited unexpectedly: #{ex.stderr}"
rescue ex : ClaudeAgent::Error
  STDERR.puts "Fatal: SDK error occurred: #{ex.message}"
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
| **TeammateIdle** | `agent_id`, `agent_type` — background agent is idle and available |
| **TaskCompleted** | `task_id`, `task_status`, `task_summary`, `tool_use_id` |
| **ConfigChange** | `config_change_source`, `config_change_diff` — settings/permissions changed mid-session |

For local hook callbacks, `permission_mode` is normalized to the CLI-style values such as
`default`, `acceptEdits`, `plan`, `bypassPermissions`, `auto`, and `dontAsk`.

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

Plugins can be loaded as bare paths or as `PluginConfig` entries. Set
`skip_mcp_discovery: true` on a plugin when the host already manages that
plugin's MCP connections — the engine loads the plugin's skills/hooks without
re-reading its `.mcp.json`. Such plugins are passed to the CLI via
`--plugin-dir-no-mcp` instead of `--plugin-dir`:

```crystal
options = ClaudeAgent::AgentOptions.new(
  plugins: [
    ClaudeAgent::PluginConfig.new("./plugins/my-plugin", skip_mcp_discovery: true),
    "./plugins/other-plugin", # bare path still works
  ],
)
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

  # Rewind the conversation transcript itself (not just file state) to a
  # previous user message, establishing a durable resume anchor there. A
  # subsequent `resume` continues from the rewound point. Pass dry_run to
  # preview without mutating.
  client.rewind_conversation(checkpoint_uuid.not_nil!) if checkpoint_uuid
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
  ),
  # Credential handling for sandboxed commands (CLI v2.1.187+):
  credentials: ClaudeAgent::SandboxCredentialsSettings.new(
    files: [
      # "deny" blocks reads of credential files inside the sandbox.
      ClaudeAgent::SandboxCredentialFile.new("~/.aws/credentials"),
    ],
    env_vars: [
      # "deny" unsets the variable; "mask" shows a sentinel inside the
      # sandbox and injects the real value only on egress to inject_hosts.
      ClaudeAgent::SandboxCredentialEnvVar.new(
        "AWS_SECRET_ACCESS_KEY",
        mode: "mask",
        inject_hosts: ["*.amazonaws.com"],
      ),
    ],
  ),
)

options = ClaudeAgent::AgentOptions.new(
  sandbox: sandbox
)
```

Credential `files` support `mode: "deny"` only; `env_vars` support `"deny"`
(unset inside the sandbox) or `"mask"` (sentinel value inside the sandbox,
swapped for the real secret at the proxy for `inject_hosts` destinations).

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
  # A stream-json line could not be parsed. `raw_data` preserves the payload
  # (truncated to 500 chars for diagnostics).
  STDERR.puts "Malformed CLI output: #{ex.raw_data}"
rescue ex : ClaudeAgent::TimeoutError
  STDERR.puts "Timed out waiting for Claude Code: #{ex.message}"
rescue ex : ClaudeAgent::ConfigurationError
  STDERR.puts "Invalid SDK configuration: #{ex.message}"
rescue ex : ClaudeAgent::UnsupportedOptionError
  # An AgentOptions flag was rejected by the installed Claude Code CLI.
  # `option` is the specific flag (e.g., "--title"); `cli_path` is the
  # resolved binary. Upgrade the CLI or stop setting that option.
  STDERR.puts "CLI rejected #{ex.option}: #{ex.message}"
rescue ex : ClaudeAgent::Error
  # Catch-all for any other SDK-level error.
  STDERR.puts "SDK error: #{ex.message}"
end
```

### CLI Capability Probe

Forward-compatible SDK options like `task_budget`, `thinking`, and
`SystemPromptFile` map to CLI flags that only newer Claude Code releases
understand. When the SDK hands an unknown flag to an older CLI, the
subprocess aborts at argv-parse time with
`error: unknown option '--task-budget'`, which previously surfaced to
callers as an opaque connection-closed error.

To prevent that, `CLIClient` probes `claude --help` once per `cli_path` at
start time, caches the advertised flag set, and silently drops any
forward-compatible optional flag the CLI does not recognize. A short
warning is emitted through your `stderr` callback (or to standard error)
whenever a flag is dropped.

- Core flags (`--model`, `--print`, `--output-format`, `--verbose`, etc.)
  are never filtered. Only the SDK-only forward-compatible flags listed in
  `CLIClient::OPTIONAL_CLI_FLAGS` are eligible for filtering.
- `options.title` is not a CLI argument at all. The SDK applies it via the
  session-file mutation path (`ClaudeAgent.rename_session` / the
  `generate_session_title` control request). Similarly,
  `SystemPromptPreset#exclude_dynamic_sections` flows through the
  `initialize` control request as `excludeDynamicSections`.
- Set `AgentOptions#probe_cli_capabilities = false` to disable the probe
  entirely and pass every option through unmodified. Use this when you
  know the installed CLI supports every flag you configure and you want
  to avoid the one-time `claude --help` subprocess.
- If the CLI ever aborts with an `unknown option` stderr line that slips
  past the probe, the SDK raises a typed `ClaudeAgent::UnsupportedOptionError`
  with `option` and `cli_path` populated, so callers can recover cleanly
  instead of parsing error strings.

```crystal
options = ClaudeAgent::AgentOptions.new(
  task_budget: ClaudeAgent::TaskBudget.new(120_000),  # dropped on older CLIs
  thinking: ClaudeAgent::ThinkingConfig.adaptive,     # dropped on older CLIs
  title: "refactor session",                          # session-file only
  probe_cli_capabilities: true,                       # default
  stderr: ->(line : String) { puts "[claude] #{line}" },
)

begin
  ClaudeAgent::AgentClient.open(options) { |client| client.query("Hi") }
rescue ex : ClaudeAgent::UnsupportedOptionError
  puts "CLI does not support #{ex.option}; upgrade with `claude upgrade`."
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
  probe_cli_capabilities: true,                        # default; filters forward-only flags

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
  forward_subagent_text: true,                         # stream subagent text deltas

  # --- Output & structured responses --------------------------------------
  output_format: nil,                                  # OutputFormat.json_schema(...)

  # --- CLI / environment ---------------------------------------------------
  cli_path: nil,                                       # override discovery
  env: {"CLAUDE_AGENT_TRACING" => "1"},
  betas: ["extended-thinking-2025-01-24"],
  add_dirs: ["./vendor"],
  # Plugins accept bare paths OR PluginConfig entries:
  plugins: [
    ClaudeAgent::PluginConfig.new("./plugins/my-plugin", skip_mcp_discovery: true),
    "./plugins/other",
  ],
  cwd: Dir.current,
  user: "alice",
  stderr: ->(line : String) { STDERR.puts(line) },     # observe CLI stderr
  max_buffer_size: nil,                                # override stream buffer

  # --- Settings sources ----------------------------------------------------
  setting_sources: ["user", "project"],                # [] disables all
  settings_path: nil,                                  # explicit settings.json
  managed_settings: nil,                               # policy-tier settings (in-memory, below IT-managed)

  # --- Session management --------------------------------------------------
  continue_conversation: false,
  resume: nil,                                         # session ID to resume
  resume_session_at: nil,                              # message UUID to resume from
  session_id: nil,                                     # explicit session ID
  fork_session: false,                                 # fork on resume
  no_session_persistence: false,

  # --- Safety & checkpointing ---------------------------------------------
  enable_file_checkpointing: true,
  sandbox: ClaudeAgent::SandboxSettings.new(
    enabled: true,
    credentials: ClaudeAgent::SandboxCredentialsSettings.new(
      env_vars: [ClaudeAgent::SandboxCredentialEnvVar.new("AWS_SECRET_ACCESS_KEY", mode: "mask")],
    ),
  ),
)

ClaudeAgent.query("Review the current directory.", options) do |message|
  puts message
end
```

## Status

> Developed against Claude Code CLI **v2.1.201**. The SDK is forward-compatible:
> features that require newer CLI versions are gracefully no-op or surface a
> clear error on older CLIs.

## Deployment

For production deployments, the SDK supports executing agents and in-process tools across multiple transport models: **Stdio**, **HTTP (webhooks)**, and **SSE (Server-Sent Events)**.

Refer to the dedicated [Deployment Guide](DEPLOYMENT.md) for:
- Environment configuration and path isolation (`CLAUDE_CONFIG_DIR`).
- Non-interactive shell and authentication setups (`ANTHROPIC_API_KEY`).
- Complete production-ready code examples using Kemal (HTTP) and standard HTTP servers (SSE/Stdio).
- Production deployment security checklists.

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

### 0.8.0

Parity release aligned with Claude Code CLI **v2.1.201** and the official Python (`0.2.110`) / TypeScript (`0.3.201`) SDKs. Brings over features added since 0.7.0, verified end-to-end against the live CLI.

**New features**:
- **`TaskUpdatedMessage` + `TERMINAL_TASK_STATUSES`**: Background tasks can finish *only* via a `system/task_updated` event (e.g. a task stopped via `TaskStop` reports `status="killed"` here with no `TaskNotification`). The new `TaskUpdatedMessage` parses these, `#terminal?` reports terminal status, and the `TERMINAL_TASK_STATUSES` set (`completed`, `failed`, `stopped`, `killed`) covers both lifecycle vocabularies — fixing a class of hangs in active-task tracking. Matches Python `0.2.101`.
- **`tool_use_meta` sidecar**: `AssistantMessage#tool_use_meta` exposes the CLI's display-metadata array — per-`tool_use`-block entries with `id`, `display_name`, `server_display_name`, and `icon_url` — plus a `#tool_use_meta_for(tool_use_id)` lookup, so SDK consumers can render human-readable tool-call chips instead of raw wire names. CLI v2.1.179+. New `ToolUseMeta` struct.
- **`origin` on `ResultMessage`**: Typed `MessageOrigin` (`kind` plus variant fields, with `human?` / `task_notification?` predicates) forwarded from the triggering message, so consumers can distinguish user-prompted results from background-task followups. TS `0.2.126`.
- **`rewind_conversation` control request**: `AgentClient#rewind_conversation(user_message_id, dry_run:)` truncates the transcript to a previous user message and establishes a durable resume anchor (distinct from `rewind_files`, which restores file state). New `ControlRewindConversationRequest`. TS `0.3.186`.
- **`stop_details` + `#refusal?`**: `AssistantMessage#stop_details` exposes the structured refusal detail (`category`, `explanation`, `fallback_credit_token`) paired with `stop_reason: "refusal"`; `#refusal?` lets consumers branch on refusals without text-matching. New `StopDetails` struct. TS `0.3.162`.
- **`managed_settings` option**: Pass policy-tier settings to the CLI in-memory via `--managed-settings <json>` (a real flag hidden from `claude --help`), honored below IT-controlled managed sources. TS `0.2.118`.
- **`forward_subagent_text` option**: Stream subagent text/thinking blocks as messages with `parent_tool_use_id` set. Forwarded via the `initialize` control request. TS `0.2.119`.
- **`sandbox.credentials` settings**: `SandboxCredentialsSettings` with typed `SandboxCredentialFile` (`path`, `mode: "deny"`) and `SandboxCredentialEnvVar` (`name`, `mode: "deny"|"mask"`, `inject_hosts`) entries controls how credential files and env vars are protected in sandboxed commands. Serialized under `sandbox.credentials` in the settings JSON. TS `0.3.187` / `0.3.199`.
- **`PluginConfig` + `skip_mcp_discovery`**: `plugins` now accepts `PluginConfig` entries alongside bare paths. `skip_mcp_discovery: true` emits `--plugin-dir-no-mcp` so the engine loads the plugin's skills/hooks without reading its `.mcp.json` when the host manages MCP itself. TS `0.3.172`.
- **`prompt_id` on `HookInput`**: Stable identifier for the current prompt so hooks can correlate events with OpenTelemetry prompt-level spans. TS `0.3.196`.
- **`RATE_LIMIT_TYPES` constant**: Documents the `rateLimitType` values the CLI emits, including the new `seven_day_overage_included` per-model weekly overage window. TS `0.3.191`.

**New example**: `examples/42_fruit_template.cr` — a showcase exercising the new message fields and options end-to-end.

### 0.7.0

Feature release aligned with Claude Code CLI **v2.1.158** and official Python/TypeScript SDKs.

**New features**:
- **Adaptive Thinking Display**: Added `display` option to `ThinkingConfig.adaptive` and `ThinkingConfig.enabled` (supporting `"summarized"` and `"omitted"`). Forwarded via `--thinking-display` CLI flag.
- **Hook Lifecycle Event Streaming**: Implemented `HookEventMessage` which parses `system` messages with subtypes `hook_started` and `hook_response`, yielding streamed CLI hook events when `include_hook_events` is enabled.
- **Post-Tool Output Overriding**: Added `updated_tool_output` to `HookSpecificOutput` mapped as `"updatedToolOutput"` inside the control protocol, enabling `PostToolUse` hooks to replace tool outputs before reaching the model.
- **Richer Permission Context**: Added `decision_reason`, `title`, `display_name`, and `description` to `PermissionContext` and `ControlPermissionRequest` to support highly detailed permission prompt callbacks.
- **Deferred Tool Execution**: Added `DeferredToolUse` struct and mapped it to the `deferred_tool_use` field on `ResultMessage` to support `"defer"` hook decisions and deferred tool execution.
- **Server Tool Blocks**: Added `ServerToolUseBlock` and `ServerToolResultBlock` to parse and expose server-side tool calls and advisor results without dropping them.
- **Sandbox Network Properties**: Added `allowedDomains`, `deniedDomains`, `allowManagedDomainsOnly`, and `allowMachLookup` properties to `SandboxNetworkSettings` to reflect sandbox networking constraints.

### 0.6.0

Hardening release. Surfaced latent bugs across wire protocol, robustness,
and error handling via a multi-angle audit against the Python SDK + live
Claude Code CLI v2.1.114, and fixed the high-severity findings.

**Breaking changes** (upgrade notes):

- **Removed `ClaudeAgent::PermissionDeniedError`.** The class was declared in `errors.cr` but never raised anywhere in the SDK. Any `rescue ex : ClaudeAgent::PermissionDeniedError` clauses in consumer code will now fail to compile — the branch was never executing, so it's safe to delete.
- **`MCPToolAnnotations` fields renamed to MCP-spec `*Hint` keys**:
  - `#read_only` → `#read_only_hint?` (JSON `readOnly` → `readOnlyHint`)
  - `#destructive` → `#destructive_hint?` (JSON `destructive` → `destructiveHint`)
  - `#open_world` → `#open_world_hint?` (JSON `openWorld` → `openWorldHint`)
  - Plus new `#idempotent_hint?` and `#title`.
  The old keys were never what the CLI actually emitted; any code reading the old getters was always seeing `nil`.
- **`QueryIterator#next` now re-raises errors** from the background fiber (CLI not found, subprocess crashed, unsupported option) instead of silently yielding `Iterator::Stop`. Callers iterating `ClaudeAgent.query(prompt)` (the non-block form) must now rescue or propagate.
- **`AgentOptions#skills` rejects unrecognized strings.** Only `"all"`, an `Array(String)` of skill names, or `nil` are accepted. Passing `"none"`, `"off"`, a single skill name, etc. now raises `ConfigurationError` instead of being silently ignored.
- **`AgentOptions#resume_session_at` without `resume` now raises** `ConfigurationError` at argv build time. Previously this caused an opaque subprocess crash during handshake.
- **`AgentOptions#skills: []` is a true no-op.** Empty array no longer defaults `setting_sources` to `["user","project"]` as a side effect. If you were relying on that side effect, set `setting_sources` explicitly.
- **`AgentOptions#skills: "all"` is no longer emitted on the initialize request.** Matches Python SDK wire format (`"all"` and omitted are equivalent at the wire level). Injection of the `Skill` allow-rule still happens client-side.
- **`InitMessage#memory_paths` and `MemoryRecallMessage#memory_paths` are `Hash(String, String)`** (namespace → path), not `Array(String)`. Reflects what the CLI actually emits.
- **`opts.agents` is no longer forwarded as `--agents` on argv.** Agent definitions flow through the `initialize` control request exclusively (matches Python and TypeScript SDKs).
- **`--setting-sources` always emits a single `=`-joined token** (e.g., `--setting-sources=user,project`). Previously the populated case used the two-token form.
- **`ClaudeAgent::CLIClient#send_sdk_init` removed.** It was dead code with a broken wire shape (missing `request_id`).

Robustness:

- **Fix**: `CLIClient#stop` now runs a timed terminate → kill cascade (5s graceful, 5s SIGTERM, 2s SIGKILL) instead of blocking forever on `Process#wait`. Fixes the "hang when the CLI is alive but unresponsive" class of bugs.
- **Fix**: Unknown `control_request` subtypes now parse to a typed `ControlUnknownRequest` fallback and reply with a `control_response` error, instead of silently raising and leaving the CLI waiting forever. New `ControlUnknownRequest` struct added to the `ControlRequestInner` union.
- **Fix**: `claude --help` probe now has a 5-second timeout and is killed if it hangs (e.g., CLI stuck on an auth prompt).
- **Fix**: User-supplied hook callbacks (for `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PostToolUse`, `SubagentStart`, `SubagentStop`, `Stop`) are now wrapped in a rescue and log to the `stderr` callback. Previously, a callback that raised crashed the response reader fiber, skipping cleanup of pending control requests and leaking the subprocess.
- **Fix**: `AgentClient#stop` now closes the message channel **before** stopping the CLI subprocess, so fibers blocked inside `each_response` wake immediately on shutdown.
- **Fix**: The rolling `stderr_tail` buffer is now cleared on each `start`, so `detect_unknown_option_error` never surfaces a false positive from a previous session.
- **Fix**: Malformed stream-json lines now route through the configured `stderr` callback (with the offending line included, truncated) instead of raw `STDERR.puts`. The SDK's `JSONDecodeError` class is now actually used to carry the payload.

Wire protocol (non-breaking fixes):

- **Fix**: The capability probe no longer pre-emptively strips flags. The `--help` regex produced false negatives on current CLI versions (`--task-budget`, `--thinking`, `--system-prompt-file` are hidden from help but still accepted). Silently dropping a safety cap like `task_budget` was worse than letting the CLI fail with an actionable `UnsupportedOptionError`. The probe remains for diagnostics and error translation.
- **Fix**: `ControlResponse.mcp_response` now serializes the optional JSON-RPC `data` field on error responses.

Typed messages / new fields (additive):

- **New**: `AssistantMessageBody` exposes `id`, `usage`, `stop_reason`, `stop_sequence`, `container`, and `context_management`. `AssistantMessage` gains forwarders: `#message_id`, `#usage`, `#stop_reason`, `#stop_sequence`. Previously these fields were silently dropped — breaking token accounting for any SDK user.
- **New**: `InitMessage` / `ServerInfo` type `tools`, `skills`, `mcp_servers`, `plugins`, `cwd`, `model`, `permission_mode`, `fast_mode_state`, and `claude_code_version`. Raw data remains available via `server_info.raw_data`.
- **New**: `ControlUnknownRequest` fallback struct in the `ControlRequestInner` union.

Test suite:

- 52 new specs across `spec/stream_parsing_spec.cr` (subprocess buffering edges), `spec/integration_spec.cr` (mocked pipeline, always run in CI), `spec/errors_spec.cr` (error class construction), `spec/meta_spec.cr` (version + CHANGELOG sync health). Total test count: 391.

Documentation:

- Hook-events table in README extended with `TeammateIdle`, `TaskCompleted`, and `ConfigChange`.
- Permission-mode enumeration in docs now includes `auto` and `dontAsk`.

### 0.5.1

Audit release: validated every SDK option, message field, and control-request
shape against a live Claude Code CLI (v2.1.114) and the official Python SDK.
Fixed the wire-format mismatches that were causing subprocess crashes or
silent data loss.

Argv / CLI flag fixes:

- **Fix**: `options.title` is no longer forwarded as `--title` (that flag has never existed). Titles now flow through the `initialize` control request as the `title` field and are applied via `ClaudeAgent.rename_session` / `generate_session_title` where needed.
- **Fix**: `SystemPromptPreset#exclude_dynamic_sections` now flows through the `initialize` control request as `excludeDynamicSections` instead of a non-existent `--exclude-dynamic-sections` CLI flag.
- **Fix**: `permission_prompt_tool_name` now emits `--permission-prompt-tool` (the real CLI flag) instead of the non-existent `--permission-prompt-tool-name`.
- **Fix**: `enable_file_checkpointing` sets the `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=true` environment variable instead of emitting a non-existent `--enable-file-checkpointing` flag.
- **Fix**: `--betas` is now emitted as separate variadic tokens (e.g., `--betas beta1 beta2`) instead of a joined string, matching the CLI's variadic `<betas...>` parser.
- **Fix**: `--allowedTools` and `--disallowedTools` now use comma separators (matching the canonical form used by the Python SDK).
- **Fix**: `ToolsPreset.claude_code` now maps to `--tools default` (the canonical CLI value) instead of the SDK-internal preset name `claude_code`.
- **Fix**: When `system_prompt` is nil, the SDK emits `--system-prompt ""` so the subprocess runs in vanilla mode (matching Python/TS) rather than falling back to the interactive Claude Code default prompt.
- **Fix**: SDK MCP servers are now declared in `--mcp-config` with `type: "sdk"` so the CLI knows to route tool calls back as `mcp_message` control requests. Previously, SDK servers were silently dropped from the argv.

Wire-format fixes:

- **Fix**: The `shouldQuery` field on outgoing user messages is emitted in camelCase (matching the TS SDK's `SDKUserMessage.shouldQuery`) instead of snake_case `should_query`.
- **Fix**: `ControlResponse.mcp_response` now nests the JSON-RPC payload under the standard `response` wrapper (`{subtype, request_id, response: {mcp_response: ...}}`) instead of placing `mcp_response` at the top level.
- **Fix**: `InitMessage#memory_paths` and `MemoryRecallMessage#memory_paths` now return the correct shape from the CLI (see 0.6.0 for the breaking type change).

New capabilities / fields:

- **New**: `ResultMessage` exposes `api_error_status`, `model_usage`, `permission_denials`, and `fast_mode_state`, matching the fields the CLI actually emits.
- **New**: `AgentOptions#include_hook_events` maps to `--include-hook-events` and emits hook lifecycle events (`hook_started`, `hook_progress`, `hook_response`) into the output stream.
- **New**: `AgentOptions#extra_args` accepts a `Hash(String, String?)` of arbitrary CLI flags for forward compatibility with newly-added Claude Code flags the SDK has not yet modeled.
- **New**: `SandboxSettings#fail_if_unavailable` (default `true`, matching TS v0.2.91+): when sandboxing is enabled but dependencies are missing, the CLI fails fast by default instead of silently running unsandboxed.
- **New**: `CLIClient` probes the installed CLI with `claude --help` once per `cli_path` and silently drops any forward-compatible SDK-only flag (`--task-budget`, `--thinking`, `--system-prompt-file`) the CLI does not advertise. Core flags are never filtered.
- **New**: `ClaudeAgent::UnsupportedOptionError` is raised when an "unknown option" stderr message is detected during a connection failure, carrying the offending flag name and the CLI path.
- **New**: `AgentOptions#probe_cli_capabilities` (default `true`) toggles the capability probe.

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

The following examples have been tested and verified with CLI v2.1.201:

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
- Adaptive thinking display (example 41)
- New-features showcase — `TaskUpdatedMessage`, `tool_use_meta`, `refusal?`, `origin`, `forward_subagent_text`, `managed_settings`, sandbox credentials (example 42, the fruit template)

Examples with environment-dependent behavior:

- `examples/18_mcp_github.cr` requires `GITHUB_TOKEN`
- `examples/19_mcp_remote.cr` depends on remote MCP availability
- `examples/23_hook_permission_request.cr` only shows the hook when Claude would actually prompt for permission in the current environment
- `examples/32_elicitation_support.cr` requires `ELICITATION_MCP_URL` and a compatible MCP server that actually requests user input
- `examples/38_context_usage.cr`, `examples/39_new_hooks.cr`, and `examples/40_mcp_runtime.cr` exercise features that require a newer Claude Code CLI; older CLIs degrade gracefully
- `examples/42_fruit_template.cr` exercises `tool_use_meta` and `sandbox.credentials` paths that only surface on CLI v2.1.179+/v2.1.187+; the rest degrades gracefully

Quick guide:

- Best local/default examples: `01`, `02`, `07`, `14`, `16`, `25`, `26`, `27`, `28`, `29`, `31`, `33`, `36`, `37`, `42`
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
