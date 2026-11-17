require "json"

module ClaudeAgent
  # Well-known model IDs accepted as free-form strings by `AgentOptions#model`
  # and `AgentClient#set_model`. These are convenience constants only — the
  # model field remains a plain `String`, so any CLI-supported ID works.
  # Availability depends on the installed Claude Code CLI and account access.
  #
  # Intentionally omits `claude-mythos-preview` (preview-only; not tracked here).
  module Models
    # Claude 5 family
    OPUS_5_5   = "claude-opus-5-5"
    SONNET_5_5 = "claude-sonnet-5-5"
    HAIKU_5_5  = "claude-haiku-5-5"
    FABLE_5_2  = "claude-fable-5-2"
    FABLE_5_1  = "claude-fable-5-1"
    MYTHOS_5_2 = "claude-mythos-5-2"
    MYTHOS_5_1 = "claude-mythos-5-1"
    SONNET_5   = "claude-sonnet-5"
    OPUS_5     = "claude-opus-5"
    FABLE_5    = "claude-fable-5"
    MYTHOS_5   = "claude-mythos-5"

    # Short aliases accepted by some CLI builds (when supported).
    FABLE  = "fable"
    MYTHOS = "mythos"

    # Claude 4.x family
    OPUS_4_8   = "claude-opus-4-8"
    OPUS_4_7   = "claude-opus-4-7"
    OPUS_4_6   = "claude-opus-4-6"
    OPUS_4_5   = "claude-opus-4-5"
    SONNET_4_6 = "claude-sonnet-4-6"
    # Deprecated upstream (EOL November 30, 2026); kept for compatibility.
    SONNET_4_5 = "claude-sonnet-4-5"
    HAIKU_4_5  = "claude-haiku-4-5"

    # Snapshot / dated IDs commonly used in API clients
    OPUS_4_5_20251101 = "claude-opus-4-5-20251101"
    # Deprecated upstream (EOL November 30, 2026); kept for compatibility.
    SONNET_4_5_20250929 = "claude-sonnet-4-5-20250929"
    HAIKU_4_5_20251001  = "claude-haiku-4-5-20251001"
  end

  # Recognized fast-mode runtime states reported on `system`/`init`.
  FAST_MODE_STATES = Set{"off", "cooldown", "on"}

  # Known reasons why fast mode is disabled when `fast_mode_state` is off/unavailable.
  # Open set for forward compatibility with newer CLI builds.
  FAST_MODE_DISABLED_REASONS = Set{
    "free",
    "preference",
    "extra_usage_disabled",
    "network_error",
    "unknown",
    "not_first_party",
    "disabled_by_env",
    "model_not_allowed",
    "sdk_opt_in_required",
    "pending",
  }

  struct ServerCommand
    getter name : String
    getter description : String?
    getter argument_hint : String?
    getter aliases : Array(String)?
    getter builtin : Bool?

    def initialize(
      @name : String,
      @description : String? = nil,
      @argument_hint : String? = nil,
      @aliases : Array(String)? = nil,
      @builtin : Bool? = nil,
    )
    end

    def builtin? : Bool
      @builtin == true
    end

    def self.from_any(value : JSON::Any) : ServerCommand?
      data = value.as_h?
      return unless data

      name = data["name"]?.try(&.as_s?)
      return unless name

      aliases = data["aliases"]?.try(&.as_a?).try(&.compact_map(&.as_s?))

      new(
        name,
        data["description"]?.try(&.as_s?),
        data["argumentHint"]?.try(&.as_s?),
        aliases,
        data["builtin"]?.try(&.as_bool?),
      )
    end
  end

  struct ServerAgentInfo
    getter name : String
    getter description : String?
    getter model : String?

    def initialize(@name : String, @description : String? = nil, @model : String? = nil)
    end

    def self.from_any(value : JSON::Any) : ServerAgentInfo?
      data = value.as_h?
      return unless data

      name = data["name"]?.try(&.as_s?)
      return unless name

      new(
        name,
        data["description"]?.try(&.as_s?),
        data["model"]?.try(&.as_s?),
      )
    end
  end

  struct ServerModelInfo
    getter value : String
    getter display_name : String?
    getter description : String?
    getter? supports_effort : Bool?
    getter supported_effort_levels : Array(String)
    getter? supports_adaptive_thinking : Bool?
    getter? supports_fast_mode : Bool?
    getter resolved_model : String?
    getter? supports_auto_mode : Bool?

    def initialize(
      @value : String,
      @display_name : String? = nil,
      @description : String? = nil,
      @supports_effort : Bool? = nil,
      @supported_effort_levels : Array(String) = [] of String,
      @supports_adaptive_thinking : Bool? = nil,
      @supports_fast_mode : Bool? = nil,
      @resolved_model : String? = nil,
      @supports_auto_mode : Bool? = nil,
    )
    end

    def supports_auto_mode : Bool?
      @supports_auto_mode
    end

    def self.from_any(value : JSON::Any) : ServerModelInfo?
      data = value.as_h?
      return unless data

      model_value = data["value"]?.try(&.as_s?)
      return unless model_value

      supports_auto_mode = data["supportsAutoMode"]?.try(&.as_bool?)
      supports_auto_mode = data["supports_auto_mode"]?.try(&.as_bool?) if supports_auto_mode.nil?

      new(
        model_value,
        data["displayName"]?.try(&.as_s?),
        data["description"]?.try(&.as_s?),
        data["supportsEffort"]?.try(&.as_bool?),
        string_array(data["supportedEffortLevels"]?),
        data["supportsAdaptiveThinking"]?.try(&.as_bool?),
        data["supportsFastMode"]?.try(&.as_bool?),
        data["resolvedModel"]?.try(&.as_s?) || data["resolved_model"]?.try(&.as_s?),
        supports_auto_mode,
      )
    end

    private def self.string_array(value : JSON::Any?) : Array(String)
      value.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
    end
  end

  # Plugin descriptor from system/init and reload_plugins (name + manifest version).
  struct ServerPluginInfo
    getter name : String
    getter version : String?
    getter path : String?
    getter source : String?

    def initialize(
      @name : String,
      @version : String? = nil,
      @path : String? = nil,
      @source : String? = nil,
    )
    end

    def self.from_any(value : JSON::Any) : ServerPluginInfo?
      data = value.as_h?
      return unless data

      name = data["name"]?.try(&.as_s?)
      return unless name

      new(
        name,
        data["version"]?.try(&.as_s?),
        data["path"]?.try(&.as_s?),
        data["source"]?.try(&.as_s?),
      )
    end
  end

  # Plugin load failure descriptor reported in `system`/`init` `plugin_errors`.
  struct ServerPluginError
    getter plugin : String
    getter type : String
    getter message : String
    getter path : String?
    getter install_command : String?
    getter managed_lock : Hash(String, JSON::Any)?

    def initialize(
      @plugin : String,
      @type : String,
      @message : String,
      @path : String? = nil,
      @install_command : String? = nil,
      @managed_lock : Hash(String, JSON::Any)? = nil,
    )
    end

    def self.from_any(value : JSON::Any) : ServerPluginError?
      data = value.as_h?
      return unless data

      plugin = data["plugin"]?.try(&.as_s?)
      type = data["type"]?.try(&.as_s?)
      message = data["message"]?.try(&.as_s?)
      return unless plugin && type && message

      new(
        plugin: plugin,
        type: type,
        message: message,
        path: data["path"]?.try(&.as_s?),
        install_command: data["install_command"]?.try(&.as_s?) || data["installCommand"]?.try(&.as_s?),
        managed_lock: data["managed_lock"]?.try(&.as_h?) || data["managedLock"]?.try(&.as_h?),
      )
    end
  end

  # Typed MCP server summary entry from `system`/`init` `mcp_servers`.
  struct ServerMcpServerInfo
    getter name : String
    getter status : String
    getter source : String?

    def initialize(
      @name : String,
      @status : String,
      @source : String? = nil,
    )
    end

    def self.from_any(value : JSON::Any) : ServerMcpServerInfo?
      data = value.as_h?
      return unless data

      name = data["name"]?.try(&.as_s?)
      status = data["status"]?.try(&.as_s?)
      return unless name && status

      new(
        name: name,
        status: status,
        source: data["source"]?.try(&.as_s?),
      )
    end
  end

  struct ServerAccountInfo
    getter email : String?
    getter organization : String?
    getter token_source : String?
    getter api_key_source : String?

    def initialize(
      @email : String? = nil,
      @organization : String? = nil,
      @token_source : String? = nil,
      @api_key_source : String? = nil,
    )
    end

    def self.from_any(value : JSON::Any?) : ServerAccountInfo?
      data = value.try(&.as_h?)
      return unless data

      new(
        data["email"]?.try(&.as_s?),
        data["organization"]?.try(&.as_s?),
        data["tokenSource"]?.try(&.as_s?),
        data["apiKeySource"]?.try(&.as_s?),
      )
    end
  end

  struct ServerInfo
    getter commands : Array(ServerCommand)
    getter agents : Array(ServerAgentInfo)
    getter output_style : String?
    getter available_output_styles : Array(String)
    getter models : Array(ServerModelInfo)
    getter account : ServerAccountInfo?
    getter pid : Int64?
    # Built-in tool names the CLI advertises for the session
    # (e.g., `["Task","Bash","Read",...]`).
    getter tools : Array(String)
    # Skill identifiers currently loaded in the session.
    getter skills : Array(String)
    # Summary of each configured MCP server (name + status + tools).
    # Raw JSON::Any entries so forward-compat fields are preserved.
    getter mcp_servers : Array(JSON::Any)
    # Loaded plugin descriptors (name, path, source, version).
    # Raw JSON::Any entries so forward-compat fields are preserved.
    # Prefer `#plugin_infos` for typed access including manifest `version`.
    getter plugins : Array(JSON::Any)
    # Current working directory reported by the CLI.
    getter cwd : String?
    # Model identifier the session opened with (distinct from the
    # `models` list which enumerates selectable models).
    getter model : String?
    # Permission mode the session opened with ("default", "acceptEdits",
    # ...). Camel-case on the wire; exposed here verbatim.
    getter permission_mode : String?
    # Fast-mode runtime state ("on" / "off" / ...).
    getter fast_mode_state : String?
    # Why fast mode is disabled when `fast_mode_state` is off/unavailable.
    # Present on init (and result messages via the host) when the CLI explains
    # the reason (account tier, model, org policy, etc.).
    getter fast_mode_disabled_reason : String?
    # Session's applied effort level, or null when none is sent. Set on
    # Remote Control bridge init frames. Matches TS SDK 0.3.234+.
    getter effort : JSON::Any?
    # Terminal-oriented slash commands, so Remote Control clients can
    # hide them. Matches TS SDK 0.3.229+.
    getter terminal_slash_commands : Array(String)?
    # CLI build advertised by the subprocess.
    getter claude_code_version : String?
    # Full init payload, including any forward-compat fields this struct
    # doesn't type directly.
    getter raw_data : Hash(String, JSON::Any)
    # Protocol capabilities advertised by this CLI (e.g. `"interrupt_receipt_v1"`).
    getter capabilities : Array(String)
    # Typed plugin load failure entries from `plugin_errors`.
    getter plugin_errors : Array(ServerPluginError)
    # Typed view of `mcp_servers` (`name`, `status`, `source`).
    getter mcp_server_infos : Array(ServerMcpServerInfo)
    # API key source reported on `system`/`init` (`apiKeySource`).
    getter api_key_source : String?
    # Active API beta flags reported on `system`/`init`.
    getter betas : Array(String)
    # Envelope UUID of the init message when present.
    getter uuid : String?
    # View mode reported by the CLI (`"focus"`, `"default"`, etc.).
    getter view_mode : String?
    # Startup timing breakdown (present when `CLAUDE_CODE_EMIT_STARTUP_TIMING=1`).
    getter startup_timing : Hash(String, JSON::Any)?

    def initialize(
      @commands : Array(ServerCommand) = [] of ServerCommand,
      @agents : Array(ServerAgentInfo) = [] of ServerAgentInfo,
      @output_style : String? = nil,
      @available_output_styles : Array(String) = [] of String,
      @models : Array(ServerModelInfo) = [] of ServerModelInfo,
      @account : ServerAccountInfo? = nil,
      @pid : Int64? = nil,
      @tools : Array(String) = [] of String,
      @skills : Array(String) = [] of String,
      @mcp_servers : Array(JSON::Any) = [] of JSON::Any,
      @plugins : Array(JSON::Any) = [] of JSON::Any,
      @cwd : String? = nil,
      @model : String? = nil,
      @permission_mode : String? = nil,
      @fast_mode_state : String? = nil,
      @fast_mode_disabled_reason : String? = nil,
      @effort : JSON::Any? = nil,
      @terminal_slash_commands : Array(String)? = nil,
      @claude_code_version : String? = nil,
      @raw_data : Hash(String, JSON::Any) = {} of String => JSON::Any,
      @capabilities : Array(String) = [] of String,
      @plugin_errors : Array(ServerPluginError) = [] of ServerPluginError,
      @mcp_server_infos : Array(ServerMcpServerInfo) = [] of ServerMcpServerInfo,
      @api_key_source : String? = nil,
      @betas : Array(String) = [] of String,
      @uuid : String? = nil,
      @view_mode : String? = nil,
      @startup_timing : Hash(String, JSON::Any)? = nil,
    )
    end

    def self.from_data(data : Hash(String, JSON::Any)) : ServerInfo
      commands = typed_array(data["commands"]?, ServerCommand)
      commands = string_array(data["slash_commands"]?).map { |name| ServerCommand.new(name) } if commands.empty?

      agents_raw = data["agents"]?
      agents = typed_array(agents_raw, ServerAgentInfo)
      agents = string_array(agents_raw).map { |name| ServerAgentInfo.new(name) } if agents.empty?

      new(
        commands: commands,
        agents: agents,
        output_style: data["output_style"]?.try(&.as_s?),
        available_output_styles: string_array(data["available_output_styles"]?),
        models: typed_array(data["models"]?, ServerModelInfo),
        account: ServerAccountInfo.from_any(data["account"]?),
        pid: data["pid"]?.try(&.as_i64?),
        tools: string_array(data["tools"]?),
        skills: string_array(data["skills"]?),
        mcp_servers: json_array(data["mcp_servers"]?),
        plugins: json_array(data["plugins"]?),
        cwd: data["cwd"]?.try(&.as_s?),
        model: data["model"]?.try(&.as_s?),
        permission_mode: data["permissionMode"]?.try(&.as_s?) || data["permission_mode"]?.try(&.as_s?),
        fast_mode_state: data["fast_mode_state"]?.try(&.as_s?) || data["fastModeState"]?.try(&.as_s?),
        fast_mode_disabled_reason: data["fast_mode_disabled_reason"]?.try(&.as_s?) ||
                                   data["fastModeDisabledReason"]?.try(&.as_s?),
        effort: data["effort"]?,
        terminal_slash_commands: data["terminal_slash_commands"]?.try(&.as_a?).try(&.compact_map(&.as_s?)) ||
                                 data["terminalSlashCommands"]?.try(&.as_a?).try(&.compact_map(&.as_s?)),
        claude_code_version: data["claude_code_version"]?.try(&.as_s?),
        raw_data: data,
        capabilities: string_array(data["capabilities"]?),
        plugin_errors: typed_array(data["plugin_errors"]? || data["pluginErrors"]?, ServerPluginError),
        mcp_server_infos: typed_array(data["mcp_servers"]?, ServerMcpServerInfo),
        api_key_source: data["apiKeySource"]?.try(&.as_s?) || data["api_key_source"]?.try(&.as_s?),
        betas: string_array(data["betas"]?),
        uuid: data["uuid"]?.try(&.as_s?),
        view_mode: data["viewMode"]?.try(&.as_s?) || data["view_mode"]?.try(&.as_s?),
        startup_timing: data["startup_timing"]?.try(&.as_h?) || data["startupTiming"]?.try(&.as_h?),
      )
    end

    private def self.json_array(value : JSON::Any?) : Array(JSON::Any)
      value.try(&.as_a?) || [] of JSON::Any
    end

    def slash_commands : Array(String)
      commands.map(&.name)
    end

    def command_named?(name : String) : ServerCommand?
      commands.find { |command| command.name == name }
    end

    def agent_named?(name : String) : ServerAgentInfo?
      agents.find { |agent| agent.name == name }
    end

    def supported_agent_names : Array(String)
      agents.map(&.name)
    end

    def model_named?(value : String) : ServerModelInfo?
      models.find { |model| model.value == value }
    end

    # Typed view of `#plugins`, including each plugin's manifest `version`
    # (CLI ≥ system/init + reload_plugins parity with TS 0.3.214).
    def plugin_infos : Array(ServerPluginInfo)
      plugins.compact_map { |item| ServerPluginInfo.from_any(item) }
    end

    def plugin_named?(name : String) : ServerPluginInfo?
      plugin_infos.find { |plugin| plugin.name == name }
    end

    def mcp_server_named?(name : String) : ServerMcpServerInfo?
      mcp_server_infos.find { |server| server.name == name }
    end

    private def self.string_array(value : JSON::Any?) : Array(String)
      value.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
    end

    private def self.typed_array(value : JSON::Any?, type : T.class) : Array(T) forall T
      value.try(&.as_a?).try(&.compact_map { |item| type.from_any(item) }) || [] of T
    end
  end
end
