require "json"

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
    @compiled_matcher : Regex?

    def initialize(
      @matcher : String? = nil,
      @hooks : Array(HookCallback) = [] of HookCallback,
      @timeout : Float64? = nil,
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

  struct HookConfig
    property pre_tool_use : Array(HookMatcher)?
    property post_tool_use : Array(HookMatcher)?
    property post_tool_use_failure : Array(HookMatcher)?
    property permission_request : Array(HookMatcher)?
    property elicitation : Array(HookCallback)?
    property elicitation_result : Array(HookCallback)?
    property user_prompt_submit : Array(HookCallback)?
    property stop : Array(HookCallback)?
    property subagent_start : Array(HookCallback)?
    property subagent_stop : Array(HookCallback)?
    property pre_compact : Array(HookCallback)?
    property session_start : Array(HookCallback)?
    property session_end : Array(HookCallback)?
    property notification : Array(HookCallback)?
    property teammate_idle : Array(HookCallback)?
    property task_completed : Array(HookCallback)?
    property config_change : Array(HookCallback)?

    def initialize(
      @pre_tool_use : Array(HookMatcher)? = nil,
      @post_tool_use : Array(HookMatcher)? = nil,
      @post_tool_use_failure : Array(HookMatcher)? = nil,
      @permission_request : Array(HookMatcher)? = nil,
      @elicitation : Array(HookCallback)? = nil,
      @elicitation_result : Array(HookCallback)? = nil,
      @user_prompt_submit : Array(HookCallback)? = nil,
      @stop : Array(HookCallback)? = nil,
      @subagent_start : Array(HookCallback)? = nil,
      @subagent_stop : Array(HookCallback)? = nil,
      @pre_compact : Array(HookCallback)? = nil,
      @session_start : Array(HookCallback)? = nil,
      @session_end : Array(HookCallback)? = nil,
      @notification : Array(HookCallback)? = nil,
      @teammate_idle : Array(HookCallback)? = nil,
      @task_completed : Array(HookCallback)? = nil,
      @config_change : Array(HookCallback)? = nil,
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
    property source : String? # "startup" | "resume" | "clear" | "compact"
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
    property permission_decision : String? # "allow" | "deny" | "ask"
    property permission_decision_reason : String?
    property decision : Hash(String, JSON::Any)?      # PermissionRequest decision payload
    property updated_input : Hash(String, JSON::Any)? # Modified tool input
    property additional_context : String?             # Additional context for Claude
    property updated_mcp_tool_output : JSON::Any?
    property action : String?
    property content : Hash(String, JSON::Any)?

    def initialize(
      @hook_event_name : String,
      @permission_decision : String? = nil,
      @permission_decision_reason : String? = nil,
      @decision : Hash(String, JSON::Any)? = nil,
      @updated_input : Hash(String, JSON::Any)? = nil,
      @additional_context : String? = nil,
      @updated_mcp_tool_output : JSON::Any? = nil,
      @action : String? = nil,
      @content : Hash(String, JSON::Any)? = nil,
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
