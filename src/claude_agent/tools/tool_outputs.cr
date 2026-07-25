require "json"

module ClaudeAgent
  # Optional typed helpers for parsing structured tool_result / tool_use_result
  # payloads. These are **not** automatic `ContentBlock` variants — call them
  # explicitly when you know which tool produced the content.
  #
  # Usage:
  # ```
  # if result = user_msg.tool_use_result
  #   if bash = BashToolOutput.parse(result)
  #     puts bash.timed_out_after_ms
  #   end
  # end
  # ```

  # Structured Bash tool output. Wire key for timeout is camelCase
  # `timedOutAfterMs` (TS SDK 0.3.210+ / `BashOutput` / `BashToolOutput`).
  struct BashToolOutput
    include JSON::Serializable

    getter stdout : String?
    getter stderr : String?
    getter interrupted : Bool?
    # Set when the command hit its timeout and was auto-backgrounded.
    @[JSON::Field(key: "timedOutAfterMs")]
    getter timed_out_after_ms : Int64?
    @[JSON::Field(key: "backgroundTaskId")]
    getter background_task_id : String?
    @[JSON::Field(key: "backgroundedByUser")]
    getter backgrounded_by_user : Bool?

    def initialize(
      @stdout : String? = nil,
      @stderr : String? = nil,
      @interrupted : Bool? = nil,
      @timed_out_after_ms : Int64? = nil,
      @background_task_id : String? = nil,
      @backgrounded_by_user : Bool? = nil,
    )
    end

    def self.parse(value : JSON::Any | String?) : BashToolOutput?
      ToolOutputParser.parse(value) { |json| from_json(json) }
    end

    # True when the command timed out and was auto-backgrounded.
    def timed_out? : Bool
      !timed_out_after_ms.nil?
    end
  end

  # Completed Agent / Task tool structured result. The CLI may emit
  # `resolvedModel` (camelCase) and/or a plain `model` field after a
  # mid-turn model swap. Matches TS SDK `AgentToolCompletedOutput` /
  # completed branch of `AgentOutput` (0.3.207 / 0.3.212).
  struct AgentToolCompletedOutput
    include JSON::Serializable

    getter status : String?
    # Resolved model id when present (`model` or `resolvedModel` on the wire).
    getter model : String?
    @[JSON::Field(key: "resolvedModel")]
    getter resolved_model : String?
    @[JSON::Field(key: "agentId")]
    getter agent_id : String?
    @[JSON::Field(key: "agentType")]
    getter agent_type : String?
    getter prompt : String?
    @[JSON::Field(key: "totalTokens")]
    getter total_tokens : Int64?
    @[JSON::Field(key: "totalDurationMs")]
    getter total_duration_ms : Int64?
    @[JSON::Field(key: "totalToolUseCount")]
    getter total_tool_use_count : Int64?

    def initialize(
      @status : String? = nil,
      @model : String? = nil,
      @resolved_model : String? = nil,
      @agent_id : String? = nil,
      @agent_type : String? = nil,
      @prompt : String? = nil,
      @total_tokens : Int64? = nil,
      @total_duration_ms : Int64? = nil,
      @total_tool_use_count : Int64? = nil,
    )
    end

    # Prefer explicit `model`, then `resolvedModel`.
    def effective_model : String?
      model || resolved_model
    end

    def self.parse(value : JSON::Any | String?) : AgentToolCompletedOutput?
      ToolOutputParser.parse(value) do |json|
        parsed = from_json(json)
        # Promote resolvedModel into model when model is absent.
        if parsed.model.nil? && !parsed.resolved_model.nil?
          AgentToolCompletedOutput.new(
            status: parsed.status,
            model: parsed.resolved_model,
            resolved_model: parsed.resolved_model,
            agent_id: parsed.agent_id,
            agent_type: parsed.agent_type,
            prompt: parsed.prompt,
            total_tokens: parsed.total_tokens,
            total_duration_ms: parsed.total_duration_ms,
            total_tool_use_count: parsed.total_tool_use_count,
          )
        else
          parsed
        end
      end
    end
  end

  # Skill tool structured result. `background: true` when a forked skill
  # was dispatched as a detached background agent (TS SDK 0.3.218+).
  struct SkillToolOutput
    include JSON::Serializable

    getter background : Bool?
    getter name : String?
    getter status : String?

    def initialize(
      @background : Bool? = nil,
      @name : String? = nil,
      @status : String? = nil,
    )
    end

    def background? : Bool
      background == true
    end

    def self.parse(value : JSON::Any | String?) : SkillToolOutput?
      ToolOutputParser.parse(value) { |json| from_json(json) }
    end
  end

  # NotebookEdit tool result. `old_source` enables cell-relative diffs for
  # replace/delete (TS SDK 0.3.191+).
  struct NotebookEditOutput
    include JSON::Serializable

    getter new_source : String?
    getter old_source : String?
    getter cell_id : String?
    getter cell_type : String?
    getter language : String?
    getter edit_mode : String?

    def initialize(
      @new_source : String? = nil,
      @old_source : String? = nil,
      @cell_id : String? = nil,
      @cell_type : String? = nil,
      @language : String? = nil,
      @edit_mode : String? = nil,
    )
    end

    def self.parse(value : JSON::Any | String?) : NotebookEditOutput?
      ToolOutputParser.parse(value) { |json| from_json(json) }
    end
  end

  # Agent tool when `Agent({resume})` targets a still-running agent
  # (`queued_to_running` status — TS 0.3.x AgentToolOutput).
  struct AgentToolQueuedOutput
    include JSON::Serializable

    getter status : String?
    @[JSON::Field(key: "agentId")]
    getter agent_id : String?
    getter message : String?

    def initialize(
      @status : String? = nil,
      @agent_id : String? = nil,
      @message : String? = nil,
    )
    end

    def queued_to_running? : Bool
      status == "queued_to_running"
    end

    def self.parse(value : JSON::Any | String?) : AgentToolQueuedOutput?
      ToolOutputParser.parse(value) { |json| from_json(json) }
    end
  end

  # ReadMcpResourceDir tool result — dedicated MCP resource directory listing
  # (TS SDK 0.3.186 `ReadMcpResourceDirTool`; no longer folded into ReadMcpResource).
  struct ReadMcpResourceDirOutput
    include JSON::Serializable

    getter server : String?
    getter uri : String?
    getter resources : Array(JSON::Any)?
    getter contents : Array(JSON::Any)?

    def initialize(
      @server : String? = nil,
      @uri : String? = nil,
      @resources : Array(JSON::Any)? = nil,
      @contents : Array(JSON::Any)? = nil,
    )
    end

    def self.parse(value : JSON::Any | String?) : ReadMcpResourceDirOutput?
      ToolOutputParser.parse(value) { |json| from_json(json) }
    end
  end

  # ReadMcpResource tool result for a single MCP resource body.
  struct ReadMcpResourceOutput
    include JSON::Serializable

    getter server : String?
    getter uri : String?
    getter contents : Array(JSON::Any)?
    getter content : JSON::Any?

    def initialize(
      @server : String? = nil,
      @uri : String? = nil,
      @contents : Array(JSON::Any)? = nil,
      @content : JSON::Any? = nil,
    )
    end

    def self.parse(value : JSON::Any | String?) : ReadMcpResourceOutput?
      ToolOutputParser.parse(value) { |json| from_json(json) }
    end
  end

  # WebSearch / WebFetch style server-tool payload fragments when present as
  # structured tool_use_result (best-effort; wire shape varies by CLI version).
  struct WebSearchToolOutput
    include JSON::Serializable

    getter query : String?
    getter results : Array(JSON::Any)?
    @[JSON::Field(key: "searchResults")]
    getter search_results : Array(JSON::Any)?

    def initialize(
      @query : String? = nil,
      @results : Array(JSON::Any)? = nil,
      @search_results : Array(JSON::Any)? = nil,
    )
    end

    def hits : Array(JSON::Any)?
      results || search_results
    end

    def self.parse(value : JSON::Any | String?) : WebSearchToolOutput?
      ToolOutputParser.parse(value) { |json| from_json(json) }
    end
  end

  # Built-in tool name constants for allow/disallow lists and matchers.
  module BuiltinTools
    BASH                  = "Bash"
    READ                  = "Read"
    WRITE                 = "Write"
    EDIT                  = "Edit"
    GLOB                  = "Glob"
    GREP                  = "Grep"
    AGENT                 = "Agent"
    TASK                  = "Task"
    SKILL                 = "Skill"
    NOTEBOOK_EDIT         = "NotebookEdit"
    WEB_SEARCH            = "WebSearch"
    WEB_FETCH             = "WebFetch"
    ASK_USER_QUESTION     = "AskUserQuestion"
    READ_MCP_RESOURCE     = "ReadMcpResource"
    READ_MCP_RESOURCE_DIR = "ReadMcpResourceDir"
  end

  # Shared parse plumbing for tool output helpers.
  module ToolOutputParser
    def self.parse(value : Nil, &)
      nil
    end

    def self.parse(value : String, &)
      return if value.blank?
      begin
        yield value
      rescue JSON::ParseException | JSON::SerializableError
        nil
      end
    end

    def self.parse(value : JSON::Any, &)
      raw = value.raw
      case raw
      when Hash
        parse(value.to_json) { |json| yield json }
      when String
        # tool_result content may be a JSON-encoded string.
        parse(raw) { |json| yield json }
      end
    end
  end
end
