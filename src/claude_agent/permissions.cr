require "json"

module ClaudeAgent
  # Where permission updates should be stored
  enum PermissionUpdateDestination
    UserSettings    # Global user settings (~/.claude/settings.json)
    ProjectSettings # Project settings (.claude/settings.json)
    LocalSettings   # Local gitignored settings (.claude/settings.local.json)
    Session         # Current session only (not persisted)
  end

  # Permission rule behavior
  enum PermissionRuleBehavior
    Allow
    Deny
    Ask
  end

  # A permission rule value (tool pattern or directory)
  struct PermissionRuleValue
    include JSON::Serializable
    property pattern : String
    property description : String?

    def initialize(@pattern : String, @description : String? = nil)
    end

    # Create a rule for a specific tool
    def self.tool(name : String, description : String? = nil) : PermissionRuleValue
      new(name, description)
    end

    # Create a rule for a tool with arguments (e.g., "Bash(git:*)")
    def self.tool_with_args(name : String, args : String, description : String? = nil) : PermissionRuleValue
      new("#{name}(#{args})", description)
    end
  end

  # Types of permission updates matching official SDK
  abstract struct PermissionUpdate
    include JSON::Serializable
  end

  # Add rules to existing permission set
  struct AddRulesUpdate < PermissionUpdate
    include JSON::Serializable
    getter type : String = "addRules"
    property rules : Array(PermissionRuleValue)
    property behavior : PermissionRuleBehavior
    property destination : PermissionUpdateDestination

    def initialize(
      @rules : Array(PermissionRuleValue),
      @behavior : PermissionRuleBehavior,
      @destination : PermissionUpdateDestination = PermissionUpdateDestination::Session,
    )
    end
  end

  # Replace all rules in permission set
  struct ReplaceRulesUpdate < PermissionUpdate
    include JSON::Serializable
    getter type : String = "replaceRules"
    property rules : Array(PermissionRuleValue)
    property behavior : PermissionRuleBehavior
    property destination : PermissionUpdateDestination

    def initialize(
      @rules : Array(PermissionRuleValue),
      @behavior : PermissionRuleBehavior,
      @destination : PermissionUpdateDestination = PermissionUpdateDestination::Session,
    )
    end
  end

  # Remove rules from permission set
  struct RemoveRulesUpdate < PermissionUpdate
    include JSON::Serializable
    getter type : String = "removeRules"
    property rules : Array(PermissionRuleValue)
    property behavior : PermissionRuleBehavior
    property destination : PermissionUpdateDestination

    def initialize(
      @rules : Array(PermissionRuleValue),
      @behavior : PermissionRuleBehavior,
      @destination : PermissionUpdateDestination = PermissionUpdateDestination::Session,
    )
    end
  end

  # Change permission mode
  struct SetModeUpdate < PermissionUpdate
    include JSON::Serializable
    getter type : String = "setMode"
    property mode : PermissionMode
    property destination : PermissionUpdateDestination

    def initialize(
      @mode : PermissionMode,
      @destination : PermissionUpdateDestination = PermissionUpdateDestination::Session,
    )
    end
  end

  # Add directories to allowed list
  struct AddDirectoriesUpdate < PermissionUpdate
    include JSON::Serializable
    getter type : String = "addDirectories"
    property directories : Array(String)
    property destination : PermissionUpdateDestination

    def initialize(
      @directories : Array(String),
      @destination : PermissionUpdateDestination = PermissionUpdateDestination::Session,
    )
    end
  end

  # Remove directories from allowed list
  struct RemoveDirectoriesUpdate < PermissionUpdate
    include JSON::Serializable
    getter type : String = "removeDirectories"
    property directories : Array(String)
    property destination : PermissionUpdateDestination

    def initialize(
      @directories : Array(String),
      @destination : PermissionUpdateDestination = PermissionUpdateDestination::Session,
    )
    end
  end

  # Suggested permission updates from the CLI
  struct PermissionSuggestion
    include JSON::Serializable
    property update : PermissionUpdate
    property description : String?

    def initialize(@update : PermissionUpdate, @description : String? = nil)
    end
  end

  # Context passed to permission callback
  struct PermissionContext
    property tool_name : String
    property tool_input : Hash(String, JSON::Any)
    property session_id : String
    property suggestions : Array(PermissionSuggestion)?

    def initialize(
      @tool_name : String,
      @tool_input : Hash(String, JSON::Any),
      @session_id : String,
      @suggestions : Array(PermissionSuggestion)? = nil,
    )
    end
  end

  # Result from permission callback
  struct PermissionResult
    property? allow : Bool
    property reason : String?
    property updated_input : Hash(String, JSON::Any)?
    property updated_permissions : Array(PermissionUpdate)?
    property? interrupt : Bool = false # Stop execution entirely

    def initialize(
      @allow : Bool,
      @reason : String? = nil,
      @updated_input : Hash(String, JSON::Any)? = nil,
      @updated_permissions : Array(PermissionUpdate)? = nil,
      @interrupt : Bool = false,
    )
    end

    # Create an allow result
    def self.allow(
      reason : String? = nil,
      updated_input : Hash(String, JSON::Any)? = nil,
      updated_permissions : Array(PermissionUpdate)? = nil,
    ) : PermissionResult
      new(allow: true, reason: reason, updated_input: updated_input, updated_permissions: updated_permissions)
    end

    # Create a deny result
    def self.deny(reason : String? = nil, interrupt : Bool = false) : PermissionResult
      new(allow: false, reason: reason, interrupt: interrupt)
    end

    # Allow and remember this decision for the session
    def self.allow_and_remember(tool_pattern : String, reason : String? = nil) : PermissionResult
      update = AddRulesUpdate.new(
        rules: [PermissionRuleValue.new(tool_pattern)],
        behavior: PermissionRuleBehavior::Allow,
        destination: PermissionUpdateDestination::Session
      )
      new(allow: true, reason: reason, updated_permissions: [update.as(PermissionUpdate)])
    end

    # Deny and remember this decision for the session
    def self.deny_and_remember(tool_pattern : String, reason : String? = nil) : PermissionResult
      update = AddRulesUpdate.new(
        rules: [PermissionRuleValue.new(tool_pattern)],
        behavior: PermissionRuleBehavior::Deny,
        destination: PermissionUpdateDestination::Session
      )
      new(allow: false, reason: reason, updated_permissions: [update.as(PermissionUpdate)])
    end
  end

  alias PermissionCallback = Proc(PermissionContext, PermissionResult)
end
