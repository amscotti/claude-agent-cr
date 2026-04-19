require "json"

module ClaudeAgent
  struct ServerCommand
    getter name : String
    getter description : String?
    getter argument_hint : String?

    def initialize(@name : String, @description : String? = nil, @argument_hint : String? = nil)
    end

    def self.from_any(value : JSON::Any) : ServerCommand?
      data = value.as_h?
      return nil unless data

      name = data["name"]?.try(&.as_s?)
      return nil unless name

      new(
        name,
        data["description"]?.try(&.as_s?),
        data["argumentHint"]?.try(&.as_s?),
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
      return nil unless data

      name = data["name"]?.try(&.as_s?)
      return nil unless name

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

    def initialize(
      @value : String,
      @display_name : String? = nil,
      @description : String? = nil,
      @supports_effort : Bool? = nil,
      @supported_effort_levels : Array(String) = [] of String,
      @supports_adaptive_thinking : Bool? = nil,
      @supports_fast_mode : Bool? = nil,
    )
    end

    def self.from_any(value : JSON::Any) : ServerModelInfo?
      data = value.as_h?
      return nil unless data

      model_value = data["value"]?.try(&.as_s?)
      return nil unless model_value

      new(
        model_value,
        data["displayName"]?.try(&.as_s?),
        data["description"]?.try(&.as_s?),
        data["supportsEffort"]?.try(&.as_bool?),
        string_array(data["supportedEffortLevels"]?),
        data["supportsAdaptiveThinking"]?.try(&.as_bool?),
        data["supportsFastMode"]?.try(&.as_bool?),
      )
    end

    private def self.string_array(value : JSON::Any?) : Array(String)
      value.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
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
      return nil unless data

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
    # Loaded plugin descriptors (name, path, source).
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
    # CLI build advertised by the subprocess.
    getter claude_code_version : String?
    # Full init payload, including any forward-compat fields this struct
    # doesn't type directly.
    getter raw_data : Hash(String, JSON::Any)

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
      @claude_code_version : String? = nil,
      @raw_data : Hash(String, JSON::Any) = {} of String => JSON::Any,
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
        fast_mode_state: data["fast_mode_state"]?.try(&.as_s?),
        claude_code_version: data["claude_code_version"]?.try(&.as_s?),
        raw_data: data,
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

    private def self.string_array(value : JSON::Any?) : Array(String)
      value.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
    end

    private def self.typed_array(value : JSON::Any?, type : ServerCommand.class) : Array(ServerCommand)
      value.try(&.as_a?).try(&.compact_map { |item| type.from_any(item) }) || [] of ServerCommand
    end

    private def self.typed_array(value : JSON::Any?, type : ServerAgentInfo.class) : Array(ServerAgentInfo)
      value.try(&.as_a?).try(&.compact_map { |item| type.from_any(item) }) || [] of ServerAgentInfo
    end

    private def self.typed_array(value : JSON::Any?, type : ServerModelInfo.class) : Array(ServerModelInfo)
      value.try(&.as_a?).try(&.compact_map { |item| type.from_any(item) }) || [] of ServerModelInfo
    end
  end
end
