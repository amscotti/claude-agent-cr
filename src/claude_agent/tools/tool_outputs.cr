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
    @[JSON::Field(key: "backgroundEndsWithFinalResponse")]
    getter background_ends_with_final_response : Bool?
    @[JSON::Field(key: "backgroundWakesOwner")]
    getter background_wakes_owner : Bool?

    def initialize(
      @stdout : String? = nil,
      @stderr : String? = nil,
      @interrupted : Bool? = nil,
      @timed_out_after_ms : Int64? = nil,
      @background_task_id : String? = nil,
      @backgrounded_by_user : Bool? = nil,
      @background_ends_with_final_response : Bool? = nil,
      @background_wakes_owner : Bool? = nil,
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
    @[JSON::Field(key: "toolsUsed")]
    getter tools_used : Array(String)?
    getter usage : JSON::Any?
    @[JSON::Field(key: "toolStats")]
    getter tool_stats : JSON::Any?
    @[JSON::Field(key: "worktreePath")]
    getter worktree_path : String?
    @[JSON::Field(key: "worktreeBranch")]
    getter worktree_branch : String?

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
      @tools_used : Array(String)? = nil,
      @usage : JSON::Any? = nil,
      @tool_stats : JSON::Any? = nil,
      @worktree_path : String? = nil,
      @worktree_branch : String? = nil,
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
            tools_used: parsed.tools_used,
            usage: parsed.usage,
            tool_stats: parsed.tool_stats,
            worktree_path: parsed.worktree_path,
            worktree_branch: parsed.worktree_branch,
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
  # Note: `results[]` entries may include `snippet` in `PostToolUse` hooks
  # (omitted in `tool_use_result`).
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

  # OfferChromeSetup tool structured result (`outcome`: `"connected"`,
  # `"not_now"`, or `"no_attempt_yet"`).
  struct OfferChromeSetupOutput
    include JSON::Serializable

    getter outcome : String?

    def initialize(@outcome : String? = nil)
    end

    def self.parse(value : JSON::Any | String?) : OfferChromeSetupOutput?
      ToolOutputParser.parse(value) { |json| from_json(json) }
    end
  end

  # Built-in tool name constants for allow/disallow lists and matchers.
  # Includes all 54 canonical built-in tool names plus legacy constants
  # (`TASK`, `READ_MCP_RESOURCE`, `READ_MCP_RESOURCE_DIR`) kept for backward
  # compatibility.
  module BuiltinTools
    AGENT                       = "Agent"
    ARTIFACT                    = "Artifact"
    ASK_USER_QUESTION           = "AskUserQuestion"
    BASH                        = "Bash"
    CLAUDE_DESIGN               = "ClaudeDesign"
    CRON_CREATE                 = "CronCreate"
    CRON_DELETE                 = "CronDelete"
    CRON_LIST                   = "CronList"
    EDIT                        = "Edit"
    END_CONVERSATION            = "EndConversation"
    ENTER_PLAN_MODE             = "EnterPlanMode"
    ENTER_WORKTREE              = "EnterWorktree"
    EXIT_PLAN_MODE              = "ExitPlanMode"
    EXIT_WORKTREE               = "ExitWorktree"
    GLOB                        = "Glob"
    GREP                        = "Grep"
    LIST_AGENTS                 = "ListAgents"
    LIST_MCP_RESOURCES_TOOL     = "ListMcpResourcesTool"
    LSP                         = "LSP"
    MONITOR                     = "Monitor"
    NOTEBOOK_EDIT               = "NotebookEdit"
    OFFER_CHROME_SETUP          = "OfferChromeSetup"
    POWER_SHELL                 = "PowerShell"
    PROJECTS                    = "Projects"
    PROPOSE_SKILLS              = "propose_skills"
    PROPOSE_GOAL                = "ProposeGoal"
    PUSH_NOTIFICATION           = "PushNotification"
    READ                        = "Read"
    READ_MCP_RESOURCE_DIR_TOOL  = "ReadMcpResourceDirTool"
    READ_MCP_RESOURCE_TOOL      = "ReadMcpResourceTool"
    READ_NOTIFICATIONS          = "ReadNotifications"
    REMOTE_TRIGGER              = "RemoteTrigger"
    REPORT_FINDINGS             = "ReportFindings"
    SCHEDULE_WAKEUP             = "ScheduleWakeup"
    SEND_FEEDBACK               = "SendFeedback"
    SEND_MESSAGE                = "SendMessage"
    SEND_USER_FILE              = "SendUserFile"
    SEND_USER_MESSAGE           = "SendUserMessage"
    SHARE_ONBOARDING_GUIDE      = "ShareOnboardingGuide"
    SHOW_ONBOARDING_ROLE_PICKER = "ShowOnboardingRolePicker"
    SKILL                       = "Skill"
    SUBAGENT_HANDBACK           = "SubagentHandback"
    TASK_CREATE                 = "TaskCreate"
    TASK_GET                    = "TaskGet"
    TASK_LIST                   = "TaskList"
    TASK_STOP                   = "TaskStop"
    TASK_UPDATE                 = "TaskUpdate"
    TODO_WRITE                  = "TodoWrite"
    TOOL_SEARCH                 = "ToolSearch"
    WAIT_FOR_MCP_SERVERS        = "WaitForMcpServers"
    WEB_FETCH                   = "WebFetch"
    WEB_SEARCH                  = "WebSearch"
    WORKFLOW                    = "Workflow"
    WRITE                       = "Write"

    # Legacy tool-name constants preserved for backward compatibility.
    # See `LEGACY_TOOL_NAME_ALIASES` for canonical replacements.
    TASK                  = "Task"
    READ_MCP_RESOURCE     = "ReadMcpResource"
    READ_MCP_RESOURCE_DIR = "ReadMcpResourceDir"

    BUILTIN_TOOL_NAMES = Set{
      AGENT,
      ARTIFACT,
      ASK_USER_QUESTION,
      BASH,
      CLAUDE_DESIGN,
      CRON_CREATE,
      CRON_DELETE,
      CRON_LIST,
      EDIT,
      END_CONVERSATION,
      ENTER_PLAN_MODE,
      ENTER_WORKTREE,
      EXIT_PLAN_MODE,
      EXIT_WORKTREE,
      GLOB,
      GREP,
      LIST_AGENTS,
      LIST_MCP_RESOURCES_TOOL,
      LSP,
      MONITOR,
      NOTEBOOK_EDIT,
      OFFER_CHROME_SETUP,
      POWER_SHELL,
      PROJECTS,
      PROPOSE_SKILLS,
      PROPOSE_GOAL,
      PUSH_NOTIFICATION,
      READ,
      READ_MCP_RESOURCE_DIR_TOOL,
      READ_MCP_RESOURCE_TOOL,
      READ_NOTIFICATIONS,
      REMOTE_TRIGGER,
      REPORT_FINDINGS,
      SCHEDULE_WAKEUP,
      SEND_FEEDBACK,
      SEND_MESSAGE,
      SEND_USER_FILE,
      SEND_USER_MESSAGE,
      SHARE_ONBOARDING_GUIDE,
      SHOW_ONBOARDING_ROLE_PICKER,
      SKILL,
      SUBAGENT_HANDBACK,
      TASK_CREATE,
      TASK_GET,
      TASK_LIST,
      TASK_STOP,
      TASK_UPDATE,
      TODO_WRITE,
      TOOL_SEARCH,
      WAIT_FOR_MCP_SERVERS,
      WEB_FETCH,
      WEB_SEARCH,
      WORKFLOW,
      WRITE,
    }

    LEGACY_TOOL_NAME_ALIASES = {
      TASK                  => AGENT,
      "KillShell"           => TASK_STOP,
      "KillBash"            => TASK_STOP,
      "ListPeers"           => LIST_AGENTS,
      "Brief"               => SEND_USER_MESSAGE,
      "ListMcpResources"    => LIST_MCP_RESOURCES_TOOL,
      READ_MCP_RESOURCE     => READ_MCP_RESOURCE_TOOL,
      READ_MCP_RESOURCE_DIR => READ_MCP_RESOURCE_DIR_TOOL,
    }
  end

  # All 54 canonical built-in tool names exported by the Claude Agent SDK.
  BUILTIN_TOOL_NAMES = BuiltinTools::BUILTIN_TOOL_NAMES

  # Map of legacy built-in tool names to their canonical `BuiltinTools` names.
  LEGACY_TOOL_NAME_ALIASES = BuiltinTools::LEGACY_TOOL_NAME_ALIASES

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
