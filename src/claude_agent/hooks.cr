require "json"

module ClaudeAgent
  # Hook event types matching official SDKs
  enum HookEvent
    PreToolUse         # Before tool execution (can block/modify)
    PostToolUse        # After successful tool execution
    PostToolUseFailure # After tool execution failure (TypeScript SDK)
    UserPromptSubmit   # When user submits prompt
    Stop               # When agent stops
    SubagentStart      # When subagent initializes (TypeScript SDK)
    SubagentStop       # When subagent completes
    PreCompact         # Before conversation compaction
    SessionStart       # Session initialization
    SessionEnd         # Session termination
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

    def initialize(@matcher : String? = nil, @hooks : Array(HookCallback) = [] of HookCallback)
    end

    def matches?(tool_name : String) : Bool
      if matcher = @matcher
        Regex.new(matcher).matches?(tool_name)
      else
        true
      end
    end
  end

  struct HookConfig
    property pre_tool_use : Array(HookMatcher)?
    property post_tool_use : Array(HookMatcher)?
    property post_tool_use_failure : Array(HookMatcher)? # TypeScript SDK
    property user_prompt_submit : Array(HookCallback)?
    property stop : Array(HookCallback)?
    property subagent_start : Array(HookCallback)? # TypeScript SDK
    property subagent_stop : Array(HookCallback)?
    property pre_compact : Array(HookCallback)?
    property session_start : Array(HookCallback)?
    property session_end : Array(HookCallback)?

    def initialize(
      @pre_tool_use : Array(HookMatcher)? = nil,
      @post_tool_use : Array(HookMatcher)? = nil,
      @post_tool_use_failure : Array(HookMatcher)? = nil,
      @user_prompt_submit : Array(HookCallback)? = nil,
      @stop : Array(HookCallback)? = nil,
      @subagent_start : Array(HookCallback)? = nil,
      @subagent_stop : Array(HookCallback)? = nil,
      @pre_compact : Array(HookCallback)? = nil,
      @session_start : Array(HookCallback)? = nil,
      @session_end : Array(HookCallback)? = nil,
    )
    end
  end

  struct HookInput
    include JSON::Serializable
    property tool_name : String?
    property tool_input : Hash(String, JSON::Any)?
    property tool_result : String? # For PostToolUse
    property user_prompt : String? # For UserPromptSubmit

    def initialize(
      @tool_name : String? = nil,
      @tool_input : Hash(String, JSON::Any)? = nil,
      @tool_result : String? = nil,
      @user_prompt : String? = nil,
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
    property updated_input : Hash(String, JSON::Any)? # Modified tool input (TypeScript SDK)
    property additional_context : String?             # Additional context for Claude (TypeScript SDK)

    def initialize(
      @hook_event_name : String,
      @permission_decision : String? = nil,
      @permission_decision_reason : String? = nil,
      @updated_input : Hash(String, JSON::Any)? = nil,
      @additional_context : String? = nil,
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

    # Allow with modified input
    def self.allow_with_input(updated_input : Hash(String, JSON::Any)) : HookResult
      new(
        hook_specific_output: HookSpecificOutput.new(
          hook_event_name: "PreToolUse",
          permission_decision: "allow",
          updated_input: updated_input
        )
      )
    end

    # Allow with additional context for Claude
    def self.allow_with_context(context : String) : HookResult
      new(
        hook_specific_output: HookSpecificOutput.new(
          hook_event_name: "PreToolUse",
          permission_decision: "allow",
          additional_context: context
        )
      )
    end
  end
end
