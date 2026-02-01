# Claude Agent SDK for Crystal

An unofficial Anthropic Agent SDK for Crystal, enabling developers to build autonomous AI agents powered by Claude and the Claude Code CLI.

This library provides a programmatic interface to the [Claude Code](https://code.claude.com/docs/en/overview) CLI, allowing you to create agents that can execute commands, edit files, and perform complex multi-step workflows.

> Note: A large portion of this library was written with the assistance of AI (Claude), including code, tests, and documentation.

## Features

*   **One-Shot Queries**: Simple interface for single-turn agent tasks.
*   **Interactive Sessions**: Full bidirectional agent control for chat applications.
*   **V2 Streaming Interface**: Send/receive patterns for real-time communication.
*   **Tool Use**: Access to Claude's built-in tools (Bash, File Edit, etc.) and support for custom tools.
*   **SDK MCP Servers**: In-process MCP servers with custom tools via control protocol (same as official SDKs).
*   **External MCP Servers**: Connect to external MCP servers (stdio, HTTP, SSE transports).
*   **Preset Types**: Type-safe presets for system prompts and tools to prevent typos.
*   **Type-Safe Schemas**: Crystal's answer to Zod - generate JSON schemas from types.
*   **Structured Outputs**: Get validated JSON responses matching your schema.
*   **Subagents**: Define specialized agents that can be spawned for focused subtasks.
*   **Hooks & Permissions**: Granular control over what the agent is allowed to do.
*   **Session Management**: Resume, fork, and continue conversations.
*   **File Checkpointing**: Track and rewind file changes.
*   **Sandbox Support**: Configure sandboxed execution environments.
*   **Extended Thinking**: Control thinking tokens for complex reasoning.
*   **Streaming**: Real-time message streaming using Crystal's native fibers.
*   **Type Safety**: Fully typed message and event structures.

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
        version: ~> 0.1.0
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

### Configuration

You can customize the agent's behavior using `AgentOptions`.

```crystal
options = ClaudeAgent::AgentOptions.new(
  model: "claude-sonnet-4-5-20250929",
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

Define custom tools that run in-process using the SDK MCP server architecture (same as official TypeScript/Python SDKs).

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

Intercept tool usage to block or modify actions.

```crystal
# Block 'rm' commands
block_rm = ->(input : ClaudeAgent::HookInput, id : String, ctx : ClaudeAgent::HookContext) {
  if input.tool_name == "Bash" && input.tool_input["command"].as_s.includes?("rm")
    ClaudeAgent::HookResult.deny("Deletion blocked by policy.")
  else
    ClaudeAgent::HookResult.allow
  end
}

hooks = ClaudeAgent::HookConfig.new(
  pre_tool_use: [ClaudeAgent::HookMatcher.new(matcher: "Bash", hooks: [block_rm])]
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

# Fork a session (create a branch)
options = ClaudeAgent::AgentOptions.new(
  resume: "session-uuid-here",
  fork_session: true
)
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

Control thinking tokens for complex reasoning tasks.

```crystal
options = ClaudeAgent::AgentOptions.new(
  model: "claude-sonnet-4-5-20250929",
  max_thinking_tokens: 10000,  # Minimum 1024
  betas: ["extended-thinking-2025-01-24"]
)
```

## Status

> Tested with Claude Code CLI **v2.1.29**

| Feature | Status | Notes |
|---------|--------|-------|
| One-shot queries | ✅ Working | Single-turn queries work reliably |
| Interactive sessions | ✅ Working | Multi-turn conversations with tool use |
| Custom tools (in-process) | ✅ Working | SDK MCP servers via control protocol (same as official SDKs) |
| External MCP Servers | ✅ Working | Stdio, HTTP, and SSE transports |
| Schema Builder | ✅ Working | Type-safe JSON schema generation |
| Hooks | ✅ Working | Pre/post tool use, subagent, stop hooks |
| V2 Streaming | ✅ Working | Send/receive patterns |
| Subagents | ✅ Working | Spawning specialized agents for focused subtasks |
| Structured Outputs | ✅ Working | JSON schema validation |
| Session Management | ✅ Working | Resume, fork, continue |
| File Checkpointing | ✅ Working | Track and rewind file changes |
| Sandbox Configuration | ✅ Working | Full sandbox settings support |
| Extended Thinking | ✅ Working | max_thinking_tokens support |

## Known Issues

### Previously Reported CLI Bugs (Resolved in v2.1.29)

The following issues affected earlier versions of the Claude Code CLI but have been resolved as of **v2.1.29**:

- **Duplicate Tool Use IDs** ([anthropics/claude-code#20508](https://github.com/anthropics/claude-code/issues/20508)) - Multi-turn conversations with tool use previously failed due to duplicate `tool_use` IDs across turns.
- **Tool Use Concurrency Issues in Print Mode** ([anthropics/claude-code#8763](https://github.com/anthropics/claude-code/issues/8763)) - Parallel tool calls in `--print` mode previously caused errors.

If you encounter these issues, ensure you are running the latest Claude Code CLI version.

### In-Process SDK MCP Servers

In-process MCP servers (`SDKMCPServer` / `create_sdk_mcp_server`) are **fully integrated** using the same control protocol as the official TypeScript and Python SDKs.

```crystal
# Define custom tools
weather_tool = ClaudeAgent::SDKTool.new(
  name: "get_weather",
  description: "Get current weather for a city",
  input_schema: ClaudeAgent::Schema.object(
    {"city" => ClaudeAgent::Schema.string("City name")}
  ).to_h,
  handler: ->(args : Hash(String, JSON::Any)) {
    city = args["city"]?.try(&.as_s?) || "Unknown"
    ClaudeAgent::ToolResult.text("Weather in #{city}: 72°F, sunny")
  }
)

# Create SDK MCP server
server = ClaudeAgent.create_sdk_mcp_server(
  name: "my-tools",
  tools: [weather_tool]
)

# Use in options
mcp_config = {} of String => ClaudeAgent::MCPServerConfig
mcp_config["my-tools"] = server

options = ClaudeAgent::AgentOptions.new(
  mcp_servers: mcp_config,
  allowed_tools: ["mcp__my-tools__get_weather"]
)
```

### Verified Examples

The following examples have been tested and verified with CLI v2.1.29:

- One-shot queries and streaming (examples 01, 02, 03)
- Tool restrictions and permission modes (examples 04, 05)
- In-process SDK MCP servers with custom tools (example 06)
- Streaming responses with multi-tool use (example 09)
- Local tool definitions and MCP server testing (examples 11, 12)
- Hooks for blocking dangerous commands (example 13)
- V2 streaming sessions (example 14)
- Subagents with multi-turn tool use (example 15)
- Structured JSON output (example 16)

## Contributing

1.  Fork it (<https://github.com/amscotti/claude-agent-cr/fork>)
2.  Create your feature branch (`git checkout -b my-new-feature`)
3.  Commit your changes (`git commit -am 'Add some feature'`)
4.  Push to the branch (`git push origin my-new-feature`)
5.  Create a new Pull Request

## License

MIT
