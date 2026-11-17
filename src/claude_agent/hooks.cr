require "json"
require "./types/control_messages"

module ClaudeAgent
  # Hook event types mirroring Claude Code CLI hook names.
  enum HookEvent
    PreToolUse         # Before tool execution (can block/modify)
    PostToolUse        # After successful tool execution
    PostToolUseFailure # After tool execution failure
    UserPromptSubmit   # When user submits prompt
    Stop               # When agent stops
    SubagentStart      # When subagent initializes
    SubagentStop       # When subagent completes
    PreCompact         # Before conversation compaction
    SessionStart       # Session initialization
    SessionEnd         # Session termination
    Notification       # Agent status notifications
    PermissionRequest  # When permission dialog would appear
    Elicitation        # When an MCP server asks for user input
    ElicitationResult  # After the user responds to an MCP elicitation
    TeammateIdle       # A background agent is idle and available
    TaskCompleted      # A background task finished
    ConfigChange       # Settings/permissions changed mid-session
    # Transform or hide assistant message text as it is displayed
    # (TS SDK 0.3.152 / Claude Code v2.1.152). Return displayContent via
    # HookSpecificOutput to rewrite, or suppress_output / empty content to hide.
    MessageDisplay
    # Fired when a new working directory is registered mid-session
    # (TS SDK 0.3.219 / control protocol DirectoryAdded lifecycle).
    DirectoryAdded
    PostToolBatch       # After a batch of tool executions completes
    UserPromptExpansion # When a user prompt is expanded (commands/@mentions)
    StopFailure         # When agent stops due to API/runtime failure
    PostCompact         # After conversation compaction completes
    PreModelSwitch      # Before switching active model mid-session
    PostModelSwitch     # After switching active model mid-session
    PermissionDenied    # When a tool call is denied by permission rules/classifier
    Setup               # Session setup / environment initialization
    TaskCreated         # When a background task is created
    WorktreeCreate      # When creating a git worktree for a task/session
    WorktreeRemove      # When removing a git worktree
    InstructionsLoaded  # When CLAUDE.md / instructions files are loaded
    CwdChanged          # When the session working directory changes
    FileChanged         # When a watched file changes on disk
  end

  # Forward declaration for types used in callback
  struct HookInput; end

  struct HookContext; end

  struct HookResult; end

  # Hook callback signature
  alias HookCallback = Proc(HookInput, String, HookContext, HookResult)

  struct HookMatcher
    property matcher : String? # Regex pattern for tool names
    property hooks : Array(HookCallback)
    property timeout : Float64?
    property on_failure : String? # "continue" | "block"
    @compiled_matcher : Regex?

    def initialize(
      @matcher : String? = nil,
      @hooks : Array(HookCallback) = [] of HookCallback,
      @timeout : Float64? = nil,
      @on_failure : String? = nil,
    )
      @compiled_matcher = @matcher.try { |pattern| Regex.new(pattern) }
    end

    def matches?(tool_name : String) : Bool
      if matcher = @compiled_matcher
        matcher.matches?(tool_name)
      else
        true
      end
    end
  end

  alias HookEntryList = Array(HookMatcher) | Array(HookCallback)

  struct HookConfig
    property pre_tool_use : Array(HookMatcher)?
    property post_tool_use : Array(HookMatcher)?
    property post_tool_use_failure : Array(HookMatcher)?
    property permission_request : Array(HookMatcher)?
    property elicitation : HookEntryList?
    property elicitation_result : HookEntryList?
    property user_prompt_submit : HookEntryList?
    property stop : HookEntryList?
    property subagent_start : HookEntryList?
    property subagent_stop : HookEntryList?
    property pre_compact : HookEntryList?
    property session_start : HookEntryList?
    property session_end : HookEntryList?
    property notification : HookEntryList?
    property teammate_idle : HookEntryList?
    property task_completed : HookEntryList?
    property config_change : HookEntryList?
    # MessageDisplay: transform/hide assistant text as it is displayed.
    property message_display : HookEntryList?
    # DirectoryAdded: a new working directory was registered mid-session.
    property directory_added : HookEntryList?
    property post_tool_batch : HookEntryList?
    property user_prompt_expansion : HookEntryList?
    property stop_failure : HookEntryList?
    property post_compact : HookEntryList?
    property pre_model_switch : HookEntryList?
    property post_model_switch : HookEntryList?
    property permission_denied : HookEntryList?
    property setup : HookEntryList?
    property task_created : HookEntryList?
    property worktree_create : HookEntryList?
    property worktree_remove : HookEntryList?
    property instructions_loaded : HookEntryList?
    property cwd_changed : HookEntryList?
    property file_changed : HookEntryList?

    def initialize(
      @pre_tool_use : Array(HookMatcher)? = nil,
      @post_tool_use : Array(HookMatcher)? = nil,
      @post_tool_use_failure : Array(HookMatcher)? = nil,
      @permission_request : Array(HookMatcher)? = nil,
      @elicitation : HookEntryList? = nil,
      @elicitation_result : HookEntryList? = nil,
      @user_prompt_submit : HookEntryList? = nil,
      @stop : HookEntryList? = nil,
      @subagent_start : HookEntryList? = nil,
      @subagent_stop : HookEntryList? = nil,
      @pre_compact : HookEntryList? = nil,
      @session_start : HookEntryList? = nil,
      @session_end : HookEntryList? = nil,
      @notification : HookEntryList? = nil,
      @teammate_idle : HookEntryList? = nil,
      @task_completed : HookEntryList? = nil,
      @config_change : HookEntryList? = nil,
      @message_display : HookEntryList? = nil,
      @directory_added : HookEntryList? = nil,
      @post_tool_batch : HookEntryList? = nil,
      @user_prompt_expansion : HookEntryList? = nil,
      @stop_failure : HookEntryList? = nil,
      @post_compact : HookEntryList? = nil,
      @pre_model_switch : HookEntryList? = nil,
      @post_model_switch : HookEntryList? = nil,
      @permission_denied : HookEntryList? = nil,
      @setup : HookEntryList? = nil,
      @task_created : HookEntryList? = nil,
      @worktree_create : HookEntryList? = nil,
      @worktree_remove : HookEntryList? = nil,
      @instructions_loaded : HookEntryList? = nil,
      @cwd_changed : HookEntryList? = nil,
      @file_changed : HookEntryList? = nil,
    )
    end
  end

  # Reasoning effort level active when a hook fires.
  struct HookEffort
    include JSON::Serializable

    property level : String

    def initialize(@level : String)
    end
  end

  # Summary of an in-flight background task reported on Stop / SubagentStop inputs.
  struct BackgroundTaskSummary
    include JSON::Serializable

    property id : String
    property type : String
    property status : String
    property description : String
    property command : String? = nil
    property agent_type : String? = nil
    property server : String? = nil
    property tool : String? = nil
    property name : String? = nil

    def initialize(
      @id : String,
      @type : String,
      @status : String,
      @description : String,
      @command : String? = nil,
      @agent_type : String? = nil,
      @server : String? = nil,
      @tool : String? = nil,
      @name : String? = nil,
    )
    end
  end

  # Summary of a session-scoped scheduled wakeup reported on Stop / SubagentStop inputs.
  struct SessionCronSummary
    include JSON::Serializable

    property id : String
    property schedule : String
    property? recurring : Bool
    property prompt : String

    def recurring : Bool
      @recurring
    end

    def initialize(
      @id : String,
      @schedule : String,
      @recurring : Bool,
      @prompt : String,
    )
    end
  end

  struct HookInput
    include JSON::Serializable
    # Common context fields for all hook events
    property session_id : String?
    property transcript_path : String?
    property cwd : String?
    property permission_mode : String?
    property hook_event_name : String?
    # Tool-related fields (PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest)
    property tool_name : String?
    property tool_input : Hash(String, JSON::Any)?
    property tool_use_id : String?
    property tool_result : String?   # PostToolUse tool response
    property tool_response : String? # Alias for tool_result
    # PostToolUseFailure fields
    property error : String?
    @[JSON::Field(key: "is_interrupt")]
    property is_interrupt : Bool?
    # UserPromptSubmit fields
    property user_prompt : String?
    # Stop / SubagentStop fields
    @[JSON::Field(key: "stop_hook_active")]
    property stop_hook_active : Bool?
    # SubagentStart / SubagentStop fields
    property agent_id : String?
    property agent_type : String?
    property agent_transcript_path : String?
    # Notification hook fields
    property notification_message : String?
    property notification_title : String?
    property notification_type : String?
    # PreCompact hook fields
    property trigger : String? # "manual" | "auto"
    property custom_instructions : String?
    # SessionStart fields
    # "startup" | "resume" | "clear" | "compact" | "fork"
    # (`"fork"` is reported when the session begins as a fork, Claude Code v2.1.214+)
    property source : String?
    # SessionEnd fields
    property session_end_reason : String? # "clear" | "logout" | "prompt_input_exit" | etc.
    # PermissionRequest fields
    property permission_suggestions : Array(JSON::Any)?
    # Elicitation / ElicitationResult fields
    property mcp_server_name : String?
    property elicitation_message : String?
    property elicitation_mode : String?
    property elicitation_url : String?
    property elicitation_id : String?
    property requested_schema : Hash(String, JSON::Any)?
    property elicitation_action : String?
    property elicitation_content : Hash(String, JSON::Any)?
    # TaskCompleted hook fields
    property task_id : String?
    property task_status : String?
    property task_summary : String?
    # ConfigChange hook fields
    property config_change_source : String? # e.g. "settings", "permissions"
    property config_change_diff : Hash(String, JSON::Any)?
    # MessageDisplay fields — assistant text about to be shown to the user.
    # Hooks can rewrite via HookSpecificOutput#display_content.
    property message_content : String?
    # DirectoryAdded: absolute path of the newly registered working directory.
    property directory_path : String?
    # Stable identifier for the current prompt, emitted by the CLI so hooks
    # can correlate their events with OpenTelemetry prompt-level spans.
    # Matches the TS SDK's `prompt_id` (0.3.196). Absent on older CLIs.
    property prompt_id : String?
    # Provenance of the MCP server exposing the tool (PreToolUse, PostToolUse,
    # PostToolUseFailure, PermissionRequest, PermissionDenied).
    property mcp_server : MCPServerProvenance?
    # Active reasoning effort level when the hook fired.
    property effort : HookEffort?
    # Tool execution duration in milliseconds (PostToolUse, PostToolUseFailure).
    property duration_ms : Int64?
    # Text content of the last assistant message before stopping (Stop, SubagentStop).
    property last_assistant_message : String?
    # In-flight background work reported on Stop / SubagentStop.
    property background_tasks : Array(BackgroundTaskSummary)?
    # Session-scoped scheduled wakeups reported on Stop / SubagentStop.
    property session_crons : Array(SessionCronSummary)?

    def initialize(
      @session_id : String? = nil,
      @transcript_path : String? = nil,
      @cwd : String? = nil,
      @permission_mode : String? = nil,
      @hook_event_name : String? = nil,
      @tool_name : String? = nil,
      @tool_input : Hash(String, JSON::Any)? = nil,
      @tool_use_id : String? = nil,
      @tool_result : String? = nil,
      @tool_response : String? = nil,
      @error : String? = nil,
      @is_interrupt : Bool? = nil,
      @user_prompt : String? = nil,
      @stop_hook_active : Bool? = nil,
      @agent_id : String? = nil,
      @agent_type : String? = nil,
      @agent_transcript_path : String? = nil,
      @notification_message : String? = nil,
      @notification_title : String? = nil,
      @notification_type : String? = nil,
      @trigger : String? = nil,
      @custom_instructions : String? = nil,
      @source : String? = nil,
      @session_end_reason : String? = nil,
      @permission_suggestions : Array(JSON::Any)? = nil,
      @mcp_server_name : String? = nil,
      @elicitation_message : String? = nil,
      @elicitation_mode : String? = nil,
      @elicitation_url : String? = nil,
      @elicitation_id : String? = nil,
      @requested_schema : Hash(String, JSON::Any)? = nil,
      @elicitation_action : String? = nil,
      @elicitation_content : Hash(String, JSON::Any)? = nil,
      @task_id : String? = nil,
      @task_status : String? = nil,
      @task_summary : String? = nil,
      @config_change_source : String? = nil,
      @config_change_diff : Hash(String, JSON::Any)? = nil,
      @message_content : String? = nil,
      @directory_path : String? = nil,
      @prompt_id : String? = nil,
      @mcp_server : MCPServerProvenance? = nil,
      @effort : HookEffort? = nil,
      @duration_ms : Int64? = nil,
      @last_assistant_message : String? = nil,
      @background_tasks : Array(BackgroundTaskSummary)? = nil,
      @session_crons : Array(SessionCronSummary)? = nil,
    )
    end
  end

  struct HookContext
    property session_id : String
    property cwd : String?

    def initialize(@session_id : String, @cwd : String? = nil)
    end
  end

  struct HookSpecificOutput
    include JSON::Serializable
    property hook_event_name : String
    property permission_decision : String? # "allow" | "deny" | "ask" | "defer"
    property permission_decision_reason : String?
    property decision : Hash(String, JSON::Any)?      # PermissionRequest decision payload
    property updated_input : Hash(String, JSON::Any)? # Modified tool input
    property additional_context : String?             # Additional context for Claude
    property updated_tool_output : JSON::Any?         # Replaces tool output before it goes to model
    property updated_mcp_tool_output : JSON::Any?
    property action : String?
    property content : Hash(String, JSON::Any)?
    # MessageDisplay: rewritten assistant text shown to the user (wire key
    # `displayContent`). Empty string hides the content.
    @[JSON::Field(key: "displayContent")]
    property display_content : String?
    # PostToolUse only: short host-asserted note about a tool call's
    # result that the auto-mode permission classifier reads alongside
    # that result (wire key `classifierContext`). Matches TS 0.3.236+.
    @[JSON::Field(key: "classifierContext")]
    property classifier_context : String?
    # UserPromptSubmit/UserPromptExpansion only: hide the original prompt
    # from the transcript (wire key `suppressOriginalPrompt`).
    # Matches TS SDK 0.3.238+.
    @[JSON::Field(key: "suppressOriginalPrompt")]
    property suppress_original_prompt : Bool?
    # SessionStart / UserPromptSubmit: sets the session title.
    @[JSON::Field(key: "sessionTitle")]
    property session_title : String?
    # SessionStart: initial user message for the session.
    @[JSON::Field(key: "initialUserMessage")]
    property initial_user_message : String?
    # SessionStart / CwdChanged / FileChanged: paths to watch for FileChanged events.
    @[JSON::Field(key: "watchPaths")]
    property watch_paths : Array(String)?
    # SessionStart: re-scan skill and command directories after hooks complete.
    @[JSON::Field(key: "reloadSkills")]
    property reload_skills : Bool?
    # PermissionDenied: tells the model it may retry the denied tool call.
    property retry : Bool?
    # WorktreeCreate: absolute path to the created worktree directory.
    @[JSON::Field(key: "worktreePath")]
    property worktree_path : String?

    def initialize(
      @hook_event_name : String,
      @permission_decision : String? = nil,
      @permission_decision_reason : String? = nil,
      @decision : Hash(String, JSON::Any)? = nil,
      @updated_input : Hash(String, JSON::Any)? = nil,
      @additional_context : String? = nil,
      @updated_tool_output : JSON::Any? = nil,
      @updated_mcp_tool_output : JSON::Any? = nil,
      @action : String? = nil,
      @content : Hash(String, JSON::Any)? = nil,
      @display_content : String? = nil,
      @classifier_context : String? = nil,
      @suppress_original_prompt : Bool? = nil,
      @session_title : String? = nil,
      @initial_user_message : String? = nil,
      @watch_paths : Array(String)? = nil,
      @reload_skills : Bool? = nil,
      @retry : Bool? = nil,
      @worktree_path : String? = nil,
    )
    end
  end

  struct HookResult
    include JSON::Serializable
    property? continue : Bool = true         # Proceed? (default true)
    property? suppress_output : Bool = false # Hide stdout
    property decision : String?              # "block"
    property system_message : String?        # User-facing message
    property reason : String?                # Feedback for Claude
    property hook_specific_output : HookSpecificOutput?

    def initialize(
      @continue : Bool = true,
      @suppress_output : Bool = false,
      @decision : String? = nil,
      @system_message : String? = nil,
      @reason : String? = nil,
      @hook_specific_output : HookSpecificOutput? = nil,
    )
    end

    def self.allow : HookResult
      new
    end

    # Deny tool execution. Intended for PreToolUse hooks.
    def self.deny(reason : String) : HookResult
      new(
        continue: false,
        decision: "block",
        reason: reason,
        hook_specific_output: HookSpecificOutput.new(
          hook_event_name: "PreToolUse",
          permission_decision: "deny",
          permission_decision_reason: reason
        )
      )
    end

    # Allow with modified input. Intended for PreToolUse hooks.
    def self.allow_with_input(updated_input : Hash(String, JSON::Any)) : HookResult
      new(
        hook_specific_output: HookSpecificOutput.new(
          hook_event_name: "PreToolUse",
          permission_decision: "allow",
          updated_input: updated_input
        )
      )
    end

    # Allow with additional context for Claude. Intended for PreToolUse hooks.
    def self.allow_with_context(context : String) : HookResult
      new(
        hook_specific_output: HookSpecificOutput.new(
          hook_event_name: "PreToolUse",
          permission_decision: "allow",
          additional_context: context
        )
      )
    end

    def self.permission_request(decision : Hash(String, JSON::Any)) : HookResult
      new(
        hook_specific_output: HookSpecificOutput.new(
          hook_event_name: "PermissionRequest",
          decision: decision,
        )
      )
    end

    def self.elicitation(action : String, content : Hash(String, JSON::Any)? = nil) : HookResult
      new(
        hook_specific_output: HookSpecificOutput.new(
          hook_event_name: "Elicitation",
          action: action,
          content: content,
        )
      )
    end

    def self.elicitation_result(action : String, content : Hash(String, JSON::Any)? = nil) : HookResult
      new(
        hook_specific_output: HookSpecificOutput.new(
          hook_event_name: "ElicitationResult",
          action: action,
          content: content,
        )
      )
    end
  end
end
