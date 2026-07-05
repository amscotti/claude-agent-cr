require "json"
require "../tools/sdk_mcp_server"
require "../hooks"
require "../permissions"

module ClaudeAgent
  # Permission modes supported by the Claude Code CLI
  enum PermissionMode
    Default           # Normal permission prompts
    AcceptEdits       # Auto-approve file edits
    Plan              # Planning mode, no execution
    BypassPermissions # Bypass all permission checks (requires explicit opt-in)
    Auto              # CLI-managed automatic decisions (CLI v2.1.90+)
    DontAsk           # Never prompt (fail closed on anything not explicitly allowed)

    def to_cli_value : String
      case self
      when Default           then "default"
      when AcceptEdits       then "acceptEdits"
      when Plan              then "plan"
      when BypassPermissions then "bypassPermissions"
      when Auto              then "auto"
      when DontAsk           then "dontAsk"
      else                        "default"
      end
    end
  end

  struct AgentDefinition
    include JSON::Serializable
    property name : String?
    property description : String
    property prompt : String
    property tools : Array(String)?
    @[JSON::Field(key: "disallowedTools")]
    property disallowed_tools : Array(String)?
    # Model alias ("sonnet", "opus", "haiku", "inherit") or full model ID.
    property model : String?
    property skills : Array(String)?
    property memory : String? # "user" | "project" | "local"
    # Each entry is a server name (String) or an inline {name: config} Hash.
    @[JSON::Field(key: "mcpServers")]
    property mcp_servers : Array(JSON::Any)?
    @[JSON::Field(key: "initialPrompt")]
    property initial_prompt : String?
    @[JSON::Field(key: "maxTurns")]
    property max_turns : Int32?
    property? background : Bool?
    # Effort can be "low" | "medium" | "high" | "max" or an Int tier value.
    property effort : JSON::Any?
    @[JSON::Field(key: "permissionMode")]
    property permission_mode : String?

    def initialize(
      @description : String,
      @prompt : String,
      @name : String? = nil,
      @tools : Array(String)? = nil,
      @disallowed_tools : Array(String)? = nil,
      @model : String? = nil,
      @skills : Array(String)? = nil,
      @memory : String? = nil,
      @mcp_servers : Array(JSON::Any)? = nil,
      @initial_prompt : String? = nil,
      @max_turns : Int32? = nil,
      @background : Bool? = nil,
      @effort : JSON::Any? = nil,
      @permission_mode : String? = nil,
    )
    end
  end

  struct OutputFormat
    include JSON::Serializable
    property type : String # "json_schema" | "text"
    property schema : Hash(String, JSON::Any)?
    property name : String?
    property description : String?

    def initialize(@type : String, @schema : Hash(String, JSON::Any)? = nil, @name : String? = nil, @description : String? = nil)
    end

    # Create a JSON schema output format from a Schema::ObjectSchema
    def self.json_schema(schema : Schema::ObjectSchema, name : String? = nil, description : String? = nil) : OutputFormat
      new("json_schema", schema.to_json_schema, name, description)
    end

    # Create a JSON schema output format from a plain hash (auto-converts to JSON::Any)
    def self.json_schema(schema : Hash, name : String? = nil, description : String? = nil) : OutputFormat
      new("json_schema", convert_to_json_any(schema), name, description)
    end

    # Create a text output format
    def self.text : OutputFormat
      new("text")
    end

    # Convert a plain Crystal hash to Hash(String, JSON::Any) recursively
    private def self.convert_to_json_any(value : Hash) : Hash(String, JSON::Any)
      result = {} of String => JSON::Any
      value.each do |k, v|
        result[k.to_s] = to_json_any(v)
      end
      result
    end

    private def self.to_json_any(value) : JSON::Any
      case value
      when Hash
        JSON::Any.new(convert_to_json_any(value))
      when Array
        JSON::Any.new(value.map { |v| to_json_any(v) })
      when String
        JSON::Any.new(value)
      when Int32, Int64
        JSON::Any.new(value.to_i64)
      when Float32, Float64
        JSON::Any.new(value.to_f64)
      when Bool
        JSON::Any.new(value)
      when Nil
        JSON::Any.new(nil)
      when JSON::Any
        value
      else
        JSON::Any.new(value.to_s)
      end
    end
  end

  # Network sandbox settings
  struct SandboxNetworkSettings
    include JSON::Serializable
    property? allow_local_binding : Bool = false
    property allow_unix_sockets : Array(String)?
    property? allow_all_unix_sockets : Bool = false
    property http_proxy_port : Int32?
    property socks_proxy_port : Int32?
    @[JSON::Field(key: "allowedDomains")]
    property allowed_domains : Array(String)?
    @[JSON::Field(key: "deniedDomains")]
    property denied_domains : Array(String)?
    @[JSON::Field(key: "allowManagedDomainsOnly")]
    property? allow_managed_domains_only : Bool?
    @[JSON::Field(key: "allowMachLookup")]
    property allow_mach_lookup : Array(String)?

    def initialize(
      @allow_local_binding : Bool = false,
      @allow_unix_sockets : Array(String)? = nil,
      @allow_all_unix_sockets : Bool = false,
      @http_proxy_port : Int32? = nil,
      @socks_proxy_port : Int32? = nil,
      @allowed_domains : Array(String)? = nil,
      @denied_domains : Array(String)? = nil,
      @allow_managed_domains_only : Bool? = nil,
      @allow_mach_lookup : Array(String)? = nil,
    )
    end
  end

  # Sandbox violation patterns to ignore
  struct SandboxIgnoreViolations
    include JSON::Serializable
    property file : Array(String)?
    property network : Array(String)?

    def initialize(
      @file : Array(String)? = nil,
      @network : Array(String)? = nil,
    )
    end
  end

  # A credential file or directory to protect inside the sandbox.
  # `mode: "deny"` (the only supported mode for files) blocks reads.
  struct SandboxCredentialFile
    include JSON::Serializable
    property path : String
    property mode : String = "deny"

    def initialize(@path : String, @mode : String = "deny")
    end
  end

  # An environment variable to protect inside the sandbox.
  # `"deny"` unsets the variable for sandboxed commands; `"mask"` shows
  # sandboxed commands a sentinel value and the host proxy swaps
  # sentinel -> real on egress to `inject_hosts`.
  struct SandboxCredentialEnvVar
    include JSON::Serializable
    property name : String
    property mode : String = "deny"
    # Only meaningful when `mode` is "mask": hosts the real value may be
    # injected into. Defaults to `network.allowedDomains` when unset.
    @[JSON::Field(key: "injectHosts")]
    property inject_hosts : Array(String)?

    def initialize(@name : String, @mode : String = "deny", @inject_hosts : Array(String)? = nil)
    end
  end

  # Credential handling for sandboxed commands. Controls how credential
  # files and environment variables are denied or masked when bash runs
  # inside the sandbox. Wire shape matches the TS SDK's
  # `sandbox.credentials` settings (0.3.187 / 0.3.199).
  struct SandboxCredentialsSettings
    include JSON::Serializable
    # Credential files/directories to deny inside the sandbox.
    property files : Array(SandboxCredentialFile)?
    # Environment variables to deny or mask inside the sandbox.
    @[JSON::Field(key: "envVars")]
    property env_vars : Array(SandboxCredentialEnvVar)?
    # Allow sentinel -> real substitution on the plain-HTTP proxy path.
    # Defaults to false; only enable for trusted-network test fixtures.
    @[JSON::Field(key: "allowPlaintextInject")]
    property? allow_plaintext_inject : Bool?

    def initialize(
      @files : Array(SandboxCredentialFile)? = nil,
      @env_vars : Array(SandboxCredentialEnvVar)? = nil,
      @allow_plaintext_inject : Bool? = nil,
    )
    end
  end

  # Sandbox configuration matching official SDKs
  struct SandboxSettings
    include JSON::Serializable
    property? enabled : Bool = false
    property? auto_allow_bash_if_sandboxed : Bool = false
    property excluded_commands : Array(String)?
    property? allow_unsandboxed_commands : Bool = false
    property network : SandboxNetworkSettings?
    property ignore_violations : SandboxIgnoreViolations?
    property? enable_weaker_nested_sandbox : Bool = false
    # Credential file/env-var denial (or masking) for sandboxed commands.
    # Matches the TS SDK's `sandbox.credentials` (0.3.187 / 0.3.199).
    property credentials : SandboxCredentialsSettings?
    # Matches TS SDK v0.2.91+: when sandboxing is enabled but dependencies
    # are missing, should `query()` abort with an error result (true, the
    # safer default) or silently fall back to running unsandboxed (false).
    @[JSON::Field(key: "failIfUnavailable")]
    property? fail_if_unavailable : Bool = true

    def initialize(
      @enabled : Bool = false,
      @auto_allow_bash_if_sandboxed : Bool = false,
      @excluded_commands : Array(String)? = nil,
      @allow_unsandboxed_commands : Bool = false,
      @network : SandboxNetworkSettings? = nil,
      @ignore_violations : SandboxIgnoreViolations? = nil,
      @enable_weaker_nested_sandbox : Bool = false,
      @credentials : SandboxCredentialsSettings? = nil,
      @fail_if_unavailable : Bool = true,
    )
    end
  end

  # Tool preset configuration
  struct ToolsPreset
    include JSON::Serializable
    property type : String   # "preset"
    property preset : String # "claude_code" or "default"

    def initialize(@preset : String)
      @type = "preset"
    end

    def self.claude_code : ToolsPreset
      new("claude_code")
    end

    def self.default : ToolsPreset
      new("default")
    end
  end

  # Plugin configuration. Currently only local plugins (a directory path)
  # are supported. When the host already manages a plugin's MCP connections
  # itself, set `skip_mcp_discovery: true` so the engine loads the plugin's
  # skills/hooks without re-reading its `.mcp.json`. Matches the TS SDK's
  # per-plugin `skipMcpDiscovery` (0.3.172).
  struct PluginConfig
    include JSON::Serializable
    property type : String = "local"
    property path : String
    @[JSON::Field(key: "skipMcpDiscovery")]
    property? skip_mcp_discovery : Bool = false

    def initialize(@path : String, @skip_mcp_discovery : Bool = false)
      @type = "local"
    end
  end

  # A plugin may be a bare path (local plugin) or a full PluginConfig.
  # Arrays are invariant in Crystal, so `plugins` accepts either a
  # homogeneous list of paths or a homogeneous list of configs (matches
  # how the Python/TS SDKs serialize them).
  alias PluginEntry = String | PluginConfig

  # System prompt preset configuration
  struct SystemPromptPreset
    include JSON::Serializable
    property type : String   # "preset"
    property preset : String # "claude_code"
    property append : String?
    # When true, strips per-user dynamic sections (working directory,
    # auto-memory, git status) from the system prompt so the cacheable prefix
    # is identical across users. The stripped content is re-injected into the
    # first user message. Requires CLI support; older CLIs ignore this field.
    property? exclude_dynamic_sections : Bool = false

    def initialize(
      @preset : String,
      @append : String? = nil,
      @exclude_dynamic_sections : Bool = false,
    )
      @type = "preset"
    end

    def self.claude_code(
      append : String? = nil,
      exclude_dynamic_sections : Bool = false,
    ) : SystemPromptPreset
      new("claude_code", append, exclude_dynamic_sections)
    end
  end

  # System prompt loaded from a file on disk (maps to `--system-prompt-file`).
  struct SystemPromptFile
    include JSON::Serializable
    property type : String # "file"
    property path : String

    def initialize(@path : String)
      @type = "file"
    end
  end

  # Union types for preset support - allows both strings and preset objects
  alias SystemPromptOption = String | SystemPromptPreset | SystemPromptFile
  alias ToolsOption = Array(String) | ToolsPreset

  # Skills option: "all", a list of skill names, or an empty list to suppress.
  alias SkillsOption = String | Array(String)

  # API-side task budget in tokens. When set, the model is made aware of its
  # remaining token budget so it can pace tool use and wrap up before the
  # limit. Sent as `--task-budget <total>` on the CLI.
  struct TaskBudget
    include JSON::Serializable
    property total : Int32

    def initialize(@total : Int32)
    end
  end

  struct ExternalMCPServerConfig
    include JSON::Serializable

    # Transport type - "stdio" (default for command-based), "http", or "sse"
    property type : String?

    # For stdio servers (local processes)
    property command : String?
    property args : Array(String)?
    property env : Hash(String, String)?

    # For http/sse servers (remote)
    property url : String?
    property headers : Hash(String, String)?

    def initialize(
      @command : String? = nil,
      @args : Array(String)? = nil,
      @env : Hash(String, String)? = nil,
      @type : String? = nil,
      @url : String? = nil,
      @headers : Hash(String, String)? = nil,
    )
    end

    # Factory for stdio servers (local processes)
    def self.stdio(command : String, args : Array(String)? = nil, env : Hash(String, String)? = nil)
      new(command: command, args: args, env: env)
    end

    # Factory for HTTP servers (remote)
    def self.http(url : String, headers : Hash(String, String)? = nil)
      new(type: "http", url: url, headers: headers)
    end

    # Factory for SSE servers (remote streaming)
    def self.sse(url : String, headers : Hash(String, String)? = nil)
      new(type: "sse", url: url, headers: headers)
    end
  end

  alias MCPServerConfig = SDKMCPServer | ExternalMCPServerConfig

  # Callback type for stderr output
  alias StderrCallback = Proc(String, Nil)

  struct ElicitationRequest
    getter server_name : String
    getter message : String
    getter mode : String?
    getter url : String?
    getter elicitation_id : String?
    getter requested_schema : Hash(String, JSON::Any)?

    def initialize(
      @server_name : String,
      @message : String,
      @mode : String? = nil,
      @url : String? = nil,
      @elicitation_id : String? = nil,
      @requested_schema : Hash(String, JSON::Any)? = nil,
    )
    end
  end

  struct ElicitationResponse
    getter action : String
    getter content : Hash(String, JSON::Any)?

    def initialize(@action : String, @content : Hash(String, JSON::Any)? = nil)
    end

    def self.accept(content : Hash(String, JSON::Any)? = nil) : ElicitationResponse
      new("accept", content)
    end

    def self.decline : ElicitationResponse
      new("decline")
    end

    def self.cancel : ElicitationResponse
      new("cancel")
    end
  end

  alias ElicitationCallback = Proc(ElicitationRequest, ElicitationResponse)

  abstract struct ThinkingConfig
    getter type : String

    def initialize(@type : String)
    end

    def budget_tokens : Int32?
      nil
    end

    def display : String?
      nil
    end

    def self.adaptive(display : String? = nil) : ThinkingConfigAdaptive
      ThinkingConfigAdaptive.new(display)
    end

    def self.enabled(budget_tokens : Int32, display : String? = nil) : ThinkingConfigEnabled
      ThinkingConfigEnabled.new(budget_tokens, display)
    end

    def self.disabled : ThinkingConfigDisabled
      ThinkingConfigDisabled.new
    end
  end

  struct ThinkingConfigAdaptive < ThinkingConfig
    getter display : String?

    def initialize(@display : String? = nil)
      super("adaptive")
    end
  end

  struct ThinkingConfigEnabled < ThinkingConfig
    getter budget_tokens : Int32
    getter display : String?

    def initialize(@budget_tokens : Int32, @display : String? = nil)
      super("enabled")
    end
  end

  struct ThinkingConfigDisabled < ThinkingConfig
    def initialize
      super("disabled")
    end
  end

  # Effort tiers accepted by the Claude Code CLI.
  # `Xhigh` sits between `High` and `Max` and is required by Claude Opus 4.7
  # (which defaults to `xhigh` in Claude Code).
  enum Effort
    Low
    Medium
    High
    Xhigh
    Max
  end

  struct AgentOptions
    include JSON::Serializable

    # Core configuration
    # Accepts String or SystemPromptPreset (e.g., SystemPromptPreset.claude_code)
    @[JSON::Field(ignore: true)]
    property system_prompt : SystemPromptOption?
    property append_system_prompt : String? # Append to default system prompt
    property model : String?
    property fallback_model : String?

    # Tool configuration
    property allowed_tools : Array(String)?
    property disallowed_tools : Array(String)?
    # Accepts Array(String) or ToolsPreset (e.g., ToolsPreset.claude_code)
    @[JSON::Field(ignore: true)]
    property tools : ToolsOption? # Specific tools list (different from allowed_tools)
    property permission_mode : PermissionMode = PermissionMode::Default
    property? allow_dangerously_skip_permissions : Bool = false # Required for bypassPermissions

    # Budget and limits
    property max_budget_usd : Float64?
    property max_turns : Int32?
    property max_thinking_tokens : Int32? # Extended thinking control
    property thinking : ThinkingConfig?
    property effort : Effort?
    property task_budget : TaskBudget? # API-side token budget awareness

    # Beta features
    property betas : Array(String)?

    # Skills enabled for the main session. Accepts "all", an array of skill
    # names, or an empty array to suppress all skills. When set, the SDK
    # auto-injects the `Skill` or `Skill(name)` entries into `allowed_tools`
    # and defaults `setting_sources` to `["user","project"]` when unset.
    @[JSON::Field(ignore: true)]
    property skills : SkillsOption?

    # Additional directories
    property add_dirs : Array(String)?

    # Plugins
    property plugins : Array(String) | Array(PluginConfig) | Nil

    # Session configuration
    property cwd : String?

    # MCP servers
    @[JSON::Field(ignore: true)]
    property mcp_servers : Hash(String, MCPServerConfig)?
    property? strict_mcp_config : Bool = false # Only use --mcp-config servers

    # Agent definitions for subagents
    property agents : Hash(String, AgentDefinition)?
    property agent : String? # Active agent to use
    property? prompt_suggestions : Bool = false
    property? agent_progress_summaries : Bool = false

    # Hooks
    @[JSON::Field(ignore: true)]
    property hooks : HookConfig?
    @[JSON::Field(ignore: true)]
    property on_elicitation : ElicitationCallback?

    # Permission callback
    @[JSON::Field(ignore: true)]
    property can_use_tool : PermissionCallback?
    property permission_prompt_tool_name : String? # MCP tool for permission prompts

    # Streaming options
    property? include_partial_messages : Bool = false
    # Emit all hook lifecycle events (`hook_started`, `hook_progress`,
    # `hook_response`) into the output stream. Maps to `--include-hook-events`.
    property? include_hook_events : Bool = false
    property? replay_user_messages : Bool = false # Re-emit user messages for acknowledgment
    # Stream subagent text/thinking blocks as assistant/user messages with
    # `parent_tool_use_id` set, so consumers can render a nested subagent
    # transcript live. Forwarded via the `initialize` control request as
    # `forwardSubagentText` (not a CLI flag). Matches the TS SDK (0.2.119).
    property? forward_subagent_text : Bool = false

    # Output format (structured outputs)
    property output_format : OutputFormat?

    # CLI configuration
    property cli_path : String?
    property env : Hash(String, String)?

    # Setting sources
    property setting_sources : Array(String)?
    property settings_path : String? # Path to settings file
    # Policy-tier settings passed to the CLI in-memory via the
    # `--managed-settings <json>` flag (a real flag hidden from
    # `claude --help`), honored *below* IT-controlled managed sources.
    # Restrictive-only: non-allowlisted keys are dropped by the CLI.
    # Useful for embedders that want to enforce defaults without writing a
    # managed-settings file to disk. Matches the TS SDK's `managedSettings`
    # (0.2.118).
    @[JSON::Field(ignore: true)]
    property managed_settings : Hash(String, JSON::Any)?

    # Session management
    property? continue_conversation : Bool = false
    property resume : String?            # Session ID to resume
    property resume_session_at : String? # Message UUID to resume from
    property session_id : String?
    property? fork_session : Bool = false
    property? no_session_persistence : Bool = false
    property title : String? # Optional session title; skips auto-generation

    # When true (the default), the SDK probes the Claude Code CLI once on
    # first start (`claude --help`) to learn which option flags it supports,
    # and silently drops forward-compatible SDK-only options that the CLI
    # would otherwise reject at argv-parse time (`--title`, `--task-budget`,
    # `--thinking`, `--system-prompt-file`, `--exclude-dynamic-sections`).
    # Set to false to force every option through unmodified.
    property? probe_cli_capabilities : Bool = true

    # Forward arbitrary CLI flags that aren't modeled as typed options.
    # Use this as an escape hatch for newly-added CLI flags the SDK has
    # not caught up to yet. Nil values emit the flag without an argument
    # (boolean switches); string values emit `--flag value` pairs.
    # Keys must be the flag name *without* the leading `--`.
    # Example: `{"ide" => nil, "debug-file" => "/tmp/claude.log"}`.
    property extra_args : Hash(String, String?)?

    # File checkpointing
    property? enable_file_checkpointing : Bool = false

    # Sandbox configuration
    property sandbox : SandboxSettings?

    # User identifier
    property user : String?

    # Stderr callback
    @[JSON::Field(ignore: true)]
    property stderr : StderrCallback?

    # Buffer size for CLI output
    property max_buffer_size : Int32?

    def initialize(
      @system_prompt : SystemPromptOption? = nil,
      @append_system_prompt : String? = nil,
      @model : String? = nil,
      @fallback_model : String? = nil,
      @allowed_tools : Array(String)? = nil,
      @disallowed_tools : Array(String)? = nil,
      @tools : ToolsOption? = nil,
      @permission_mode : PermissionMode = PermissionMode::Default,
      @allow_dangerously_skip_permissions : Bool = false,
      @max_budget_usd : Float64? = nil,
      @max_turns : Int32? = nil,
      @max_thinking_tokens : Int32? = nil,
      @thinking : ThinkingConfig? = nil,
      @effort : Effort? = nil,
      @task_budget : TaskBudget? = nil,
      @betas : Array(String)? = nil,
      @skills : SkillsOption? = nil,
      @add_dirs : Array(String)? = nil,
      @plugins : Array(String) | Array(PluginConfig) | Nil = nil,
      @cwd : String? = nil,
      @mcp_servers : Hash(String, MCPServerConfig)? = nil,
      @strict_mcp_config : Bool = false,
      @agents : Hash(String, AgentDefinition)? = nil,
      @agent : String? = nil,
      @prompt_suggestions : Bool = false,
      @agent_progress_summaries : Bool = false,
      @hooks : HookConfig? = nil,
      @on_elicitation : ElicitationCallback? = nil,
      @can_use_tool : PermissionCallback? = nil,
      @permission_prompt_tool_name : String? = nil,
      @include_partial_messages : Bool = false,
      @include_hook_events : Bool = false,
      @replay_user_messages : Bool = false,
      @forward_subagent_text : Bool = false,
      @output_format : OutputFormat? = nil,
      @cli_path : String? = nil,
      @env : Hash(String, String)? = nil,
      @setting_sources : Array(String)? = nil,
      @settings_path : String? = nil,
      @managed_settings : Hash(String, JSON::Any)? = nil,
      @continue_conversation : Bool = false,
      @resume : String? = nil,
      @resume_session_at : String? = nil,
      @session_id : String? = nil,
      @fork_session : Bool = false,
      @no_session_persistence : Bool = false,
      @title : String? = nil,
      @probe_cli_capabilities : Bool = true,
      @extra_args : Hash(String, String?)? = nil,
      @enable_file_checkpointing : Bool = false,
      @sandbox : SandboxSettings? = nil,
      @user : String? = nil,
      @stderr : StderrCallback? = nil,
      @max_buffer_size : Int32? = nil,
    )
    end
  end
end
