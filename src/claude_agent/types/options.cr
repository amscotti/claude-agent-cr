require "json"
require "../tools/sdk_mcp_server"
require "../hooks"
require "../permissions"

module ClaudeAgent
  # Permission modes matching official SDK
  enum PermissionMode
    Default           # Normal permission prompts
    AcceptEdits       # Auto-approve file edits
    Plan              # Planning mode, no execution
    BypassPermissions # Bypass all permission checks (requires explicit opt-in)
  end

  struct AgentDefinition
    include JSON::Serializable
    property name : String?
    property description : String
    property prompt : String
    property tools : Array(String)?
    property model : String?

    def initialize(
      @description : String,
      @prompt : String,
      @name : String? = nil,
      @tools : Array(String)? = nil,
      @model : String? = nil,
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

    def initialize(
      @allow_local_binding : Bool = false,
      @allow_unix_sockets : Array(String)? = nil,
      @allow_all_unix_sockets : Bool = false,
      @http_proxy_port : Int32? = nil,
      @socks_proxy_port : Int32? = nil,
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

    def initialize(
      @enabled : Bool = false,
      @auto_allow_bash_if_sandboxed : Bool = false,
      @excluded_commands : Array(String)? = nil,
      @allow_unsandboxed_commands : Bool = false,
      @network : SandboxNetworkSettings? = nil,
      @ignore_violations : SandboxIgnoreViolations? = nil,
      @enable_weaker_nested_sandbox : Bool = false,
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

  # System prompt preset configuration
  struct SystemPromptPreset
    include JSON::Serializable
    property type : String   # "preset"
    property preset : String # "claude_code"
    property append : String?

    def initialize(@preset : String, @append : String? = nil)
      @type = "preset"
    end

    def self.claude_code(append : String? = nil) : SystemPromptPreset
      new("claude_code", append)
    end
  end

  # Union types for preset support - allows both strings and preset objects
  alias SystemPromptOption = String | SystemPromptPreset
  alias ToolsOption = Array(String) | ToolsPreset

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

    # Beta features
    property betas : Array(String)?

    # Additional directories
    property add_dirs : Array(String)?

    # Plugins
    property plugins : Array(String)?

    # Session configuration
    property cwd : String?

    # MCP servers
    @[JSON::Field(ignore: true)]
    property mcp_servers : Hash(String, MCPServerConfig)?
    property? strict_mcp_config : Bool = false # Only use --mcp-config servers

    # Agent definitions for subagents
    property agents : Hash(String, AgentDefinition)?
    property agent : String? # Active agent to use

    # Hooks
    @[JSON::Field(ignore: true)]
    property hooks : HookConfig?

    # Permission callback
    @[JSON::Field(ignore: true)]
    property can_use_tool : PermissionCallback?
    property permission_prompt_tool_name : String? # MCP tool for permission prompts

    # Streaming options
    property? include_partial_messages : Bool = false
    property? replay_user_messages : Bool = false # Re-emit user messages for acknowledgment

    # Output format (structured outputs)
    property output_format : OutputFormat?

    # CLI configuration
    property cli_path : String?
    property env : Hash(String, String)?

    # Setting sources
    property setting_sources : Array(String)?
    property settings_path : String? # Path to settings file

    # Session management
    property? continue_conversation : Bool = false
    property resume : String?            # Session ID to resume
    property resume_session_at : String? # Message UUID to resume from
    property session_id : String?
    property? fork_session : Bool = false
    property? no_session_persistence : Bool = false

    # File checkpointing
    property? enable_file_checkpointing : Bool = false

    # Sandbox configuration
    property sandbox : SandboxSettings?

    # User identifier (Python SDK)
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
      @betas : Array(String)? = nil,
      @add_dirs : Array(String)? = nil,
      @plugins : Array(String)? = nil,
      @cwd : String? = nil,
      @mcp_servers : Hash(String, MCPServerConfig)? = nil,
      @strict_mcp_config : Bool = false,
      @agents : Hash(String, AgentDefinition)? = nil,
      @agent : String? = nil,
      @hooks : HookConfig? = nil,
      @can_use_tool : PermissionCallback? = nil,
      @permission_prompt_tool_name : String? = nil,
      @include_partial_messages : Bool = false,
      @replay_user_messages : Bool = false,
      @output_format : OutputFormat? = nil,
      @cli_path : String? = nil,
      @env : Hash(String, String)? = nil,
      @setting_sources : Array(String)? = nil,
      @settings_path : String? = nil,
      @continue_conversation : Bool = false,
      @resume : String? = nil,
      @resume_session_at : String? = nil,
      @session_id : String? = nil,
      @fork_session : Bool = false,
      @no_session_persistence : Bool = false,
      @enable_file_checkpointing : Bool = false,
      @sandbox : SandboxSettings? = nil,
      @user : String? = nil,
      @stderr : StderrCallback? = nil,
      @max_buffer_size : Int32? = nil,
    )
    end
  end
end
