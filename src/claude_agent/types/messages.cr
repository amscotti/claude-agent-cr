require "json"
require "./content_blocks"
require "./control_messages"
require "./server_info"

module ClaudeAgent
  alias MessageData = Hash(String, JSON::Any)

  # Base message type
  abstract struct Message
    PARSERS = {
      "assistant" => ->(json : String, _data : MessageData) { AssistantMessage.from_json(json).as(Message) },
      # mirror_error intentionally handled in parse_special_message so we can
      # derive defaults when fields are missing.
      "user"               => ->(json : String, _data : MessageData) { UserMessage.from_json(json).as(Message) },
      "result"             => ->(json : String, _data : MessageData) { ResultMessage.from_json(json).as(Message) },
      "permission_request" => ->(json : String, _data : MessageData) { PermissionRequest.from_json(json).as(Message) },
      "prompt_suggestion"  => ->(json : String, _data : MessageData) { PromptSuggestionMessage.from_json(json).as(Message) },
      "user_question"      => ->(json : String, _data : MessageData) { UserQuestion.from_json(json).as(Message) },
      "stream_event"       => ->(json : String, _data : MessageData) { StreamEvent.from_json(json).as(Message) },
      "control_request"    => ->(json : String, _data : MessageData) { ControlRequest.from_json(json).as(Message) },
      "control_response"   => ->(json : String, _data : MessageData) { ControlResponseMessage.from_json(json).as(Message) },
    }

    def self.parse(json : String) : Message
      message = parse_message_data(json)
      type = parse_message_type(message)

      if parser = PARSERS[type]?
        return parser.call(json, message)
      end

      parse_special_message(type, json, message)
    end

    private def self.parse_message_data(json : String) : MessageData
      data = JSON.parse(json)
      message = data.as_h?
      raise Error.new("Invalid message payload") unless message

      message
    end

    private def self.parse_message_type(message : MessageData) : String
      type = message["type"]?.try(&.as_s)
      raise Error.new("Message missing 'type' field") unless type

      type
    end

    private def self.parse_special_message(type : String, json : String, message : MessageData) : Message
      case type
      when "system"
        parse_system_message(json, JSON::Any.new(message))
      when "rate_limit_event"
        parse_rate_limit_event(message)
      when "mirror_error"
        parse_mirror_error(message)
      else
        UnknownMessage.new(type, message)
      end
    end

    private def self.parse_mirror_error(data : MessageData) : Message
      uuid = data["uuid"]?.try(&.as_s?)
      session_id = data["session_id"]?.try(&.as_s?)
      error = data["error"]?.try(&.as_s?)
      return UnknownMessage.new("mirror_error", data) unless session_id && error

      MirrorErrorMessage.new(uuid, session_id, error, data)
    end

    private def self.parse_system_message(json : String, data : JSON::Any) : Message
      message = data.as_h?
      raise Error.new("Invalid system message payload") unless message

      subtype = message["subtype"]?.try(&.as_s)
      session_id = message["session_id"]?.try(&.as_s)
      raise Error.new("System message missing 'subtype' field") unless subtype
      raise Error.new("System message missing 'session_id' field") unless session_id

      parsed = parse_known_system_message?(subtype, message, session_id)
      parsed || GenericSystemMessage.new(subtype, session_id, message)
    end

    # ameba:disable Metrics/CyclomaticComplexity
    private def self.parse_known_system_message?(subtype : String, message : MessageData, session_id : String) : Message?
      case subtype
      when "init"
        InitMessage.new(session_id, message, ServerInfo.from_data(message))
      when "compact_boundary"
        parse_compact_boundary(message, session_id)
      when "task_started"
        parse_task_started(message, session_id)
      when "task_progress"
        parse_task_progress(message, session_id)
      when "task_notification"
        parse_task_notification(message, session_id)
      when "elicitation_complete"
        parse_elicitation_complete(message, session_id)
      when "api_retry"
        parse_api_retry(message, session_id)
      when "memory_recall"
        parse_memory_recall(message, session_id)
      when "status"
        parse_status_message(message, session_id)
      when "hook_started", "hook_response"
        parse_hook_event(message, session_id)
      else
        nil
      end
    end

    private def self.parse_api_retry(data : MessageData, session_id : String) : Message
      ApiRetryMessage.new(
        session_id,
        data,
        data["attempt"]?.try(&.as_i64?),
        data["max_retries"]?.try(&.as_i64?),
        data["delay_ms"]?.try(&.as_i64?),
        data["status"]?.try(&.as_i64?),
        data["error"]?.try(&.as_s?),
      )
    end

    private def self.parse_memory_recall(data : MessageData, session_id : String) : Message
      paths = {} of String => String
      data["memory_paths"]?.try(&.as_h?).try do |hash|
        hash.each do |key, value|
          if path = value.as_s?
            paths[key] = path
          end
        end
      end
      MemoryRecallMessage.new(session_id, data, paths)
    end

    private def self.parse_status_message(data : MessageData, session_id : String) : Message
      status = data["status"]?.try(&.as_s?) || "unknown"
      StatusMessage.new(session_id, data, status)
    end

    private def self.parse_compact_boundary(data : MessageData, session_id : String) : Message
      uuid = data["uuid"]?.try(&.as_s)
      metadata_data = data["compact_metadata"]?.try(&.as_h?)
      return GenericSystemMessage.new("compact_boundary", session_id, data) unless uuid && metadata_data

      CompactBoundaryMessage.new(
        session_id,
        data,
        uuid,
        CompactBoundaryMessage::CompactMetadata.from_json(metadata_data.to_json),
      )
    end

    private def self.parse_task_started(data : MessageData, session_id : String) : Message
      uuid = data["uuid"]?.try(&.as_s)
      task_id = data["task_id"]?.try(&.as_s)
      description = data["description"]?.try(&.as_s)
      return GenericSystemMessage.new("task_started", session_id, data) unless uuid && task_id && description

      TaskStartedMessage.new(
        session_id,
        data,
        uuid,
        task_id,
        description,
        data["tool_use_id"]?.try(&.as_s?),
        data["task_type"]?.try(&.as_s?),
      )
    end

    private def self.parse_task_progress(data : MessageData, session_id : String) : Message
      uuid = data["uuid"]?.try(&.as_s)
      task_id = data["task_id"]?.try(&.as_s)
      description = data["description"]?.try(&.as_s)
      usage = TaskUsage.from_any(data["usage"]?)
      return GenericSystemMessage.new("task_progress", session_id, data) unless uuid && task_id && description && usage

      TaskProgressMessage.new(
        session_id,
        data,
        uuid,
        task_id,
        description,
        usage,
        data["tool_use_id"]?.try(&.as_s?),
        data["last_tool_name"]?.try(&.as_s?),
        data["summary"]?.try(&.as_s?),
      )
    end

    private def self.parse_task_notification(data : MessageData, session_id : String) : Message
      uuid = data["uuid"]?.try(&.as_s)
      task_id = data["task_id"]?.try(&.as_s)
      status = data["status"]?.try(&.as_s)
      return GenericSystemMessage.new("task_notification", session_id, data) unless uuid && task_id && status

      TaskNotificationMessage.new(
        session_id,
        data,
        uuid,
        task_id,
        status,
        data["output_file"]?.try(&.as_s?),
        data["summary"]?.try(&.as_s?),
        TaskUsage.from_any(data["usage"]?),
        data["tool_use_id"]?.try(&.as_s?),
      )
    end

    private def self.parse_rate_limit_event(data : MessageData) : Message
      uuid = data["uuid"]?.try(&.as_s)
      session_id = data["session_id"]?.try(&.as_s)
      info_data = data["rate_limit_info"]?.try(&.as_h?)
      return UnknownMessage.new("rate_limit_event", data) unless uuid && session_id && info_data

      info = RateLimitInfo.from_data(info_data)
      return UnknownMessage.new("rate_limit_event", data) unless info

      RateLimitEvent.new(uuid, session_id, info, data)
    end

    private def self.parse_elicitation_complete(data : MessageData, session_id : String) : Message
      uuid = data["uuid"]?.try(&.as_s)
      server_name = data["mcp_server_name"]?.try(&.as_s)
      elicitation_id = data["elicitation_id"]?.try(&.as_s)
      return GenericSystemMessage.new("elicitation_complete", session_id, data) unless uuid && server_name && elicitation_id

      ElicitationCompleteMessage.new(session_id, data, uuid, server_name, elicitation_id)
    end

    private def self.parse_hook_event(data : MessageData, session_id : String) : Message
      uuid = data["uuid"]?.try(&.as_s?)
      subtype = data["subtype"]?.try(&.as_s) || "unknown"
      hook_event_name = (
        data["hook_event"]?.try(&.as_s?) ||
        data["hook_name"]?.try(&.as_s?) ||
        data["hook_event_name"]?.try(&.as_s?) ||
        ""
      )
      HookEventMessage.new(session_id, data, uuid, subtype, hook_event_name)
    end
  end

  struct AssistantMessageBody
    include JSON::Serializable
    @[JSON::Field(converter: ClaudeAgent::ContentBlockArrayConverter)]
    getter content : Array(ContentBlock)

    getter model : String?
    # Stable message identifier assigned by the API (not the SDK envelope UUID).
    getter id : String?
    # Per-turn usage payload from the Messages API (input_tokens,
    # output_tokens, cache_creation_input_tokens, cache_read_input_tokens,
    # server_tool_use, service_tier, ...). Kept as a raw hash because the
    # Anthropic API adds fields over time.
    getter usage : Hash(String, JSON::Any)?
    # "stop_reason" set by the API on completion (e.g. "end_turn",
    # "tool_use", "stop_sequence", "max_tokens").
    getter stop_reason : String?
    # When `stop_reason == "stop_sequence"`, the exact sequence matched.
    getter stop_sequence : String?
    # Container identifier for code-execution tool runs, if any.
    getter container : JSON::Any?
    # Context management directives emitted alongside the assistant turn.
    getter context_management : JSON::Any?
  end

  struct AssistantMessageError
    include JSON::Serializable
    getter type : String
    getter message : String

    def initialize(@type : String, @message : String)
    end
  end

  # Converter to handle error field that can be either a string or an object
  module ErrorConverter
    def self.from_json(pull : JSON::PullParser) : AssistantMessageError?
      case pull.kind
      when .null?
        pull.read_null
        nil
      when .string?
        # Error is a simple string like "unknown"
        error_str = pull.read_string
        AssistantMessageError.new(type: "error", message: error_str)
      when .begin_object?
        # Error is a full object with type and message
        AssistantMessageError.new(pull)
      else
        pull.raise "Expected null, string, or object for error field"
      end
    end

    def self.to_json(value : AssistantMessageError?, builder : JSON::Builder)
      if v = value
        v.to_json(builder)
      else
        builder.null
      end
    end
  end

  # Message from the assistant
  struct AssistantMessage < Message
    include JSON::Serializable

    getter type : String = "assistant"
    getter uuid : String
    getter session_id : String

    getter message : AssistantMessageBody
    @[JSON::Field(converter: ClaudeAgent::ErrorConverter)]
    getter error : AssistantMessageError?

    getter parent_tool_use_id : String?

    def content
      message.content
    end

    def model
      message.model
    end

    # API-assigned id on the inner message (distinct from `uuid` which
    # is the SDK envelope id).
    def message_id : String?
      message.id
    end

    def usage : Hash(String, JSON::Any)?
      message.usage
    end

    def stop_reason : String?
      message.stop_reason
    end

    def stop_sequence : String?
      message.stop_sequence
    end

    def text : String
      content.compact_map { |block| block.is_a?(TextBlock) ? block.text : nil }.join
    end

    # Returns tool names used in this message
    def tool_uses : Array(String)
      content.compact_map { |block| block.is_a?(ToolUseBlock) ? block.name : nil }
    end

    # Returns true if this message contains any text content
    def has_text? : Bool
      content.any? { |block| block.is_a?(TextBlock) && !block.text.empty? }
    end

    # Returns true if this message is from a subagent
    def from_subagent? : Bool
      !parent_tool_use_id.nil?
    end
  end

  struct PermissionRequest < Message
    include JSON::Serializable
    getter type : String = "permission_request"
    getter tool_use_id : String
    getter tool_name : String
    getter tool_input : Hash(String, JSON::Any)
  end

  struct UserQuestion < Message
    include JSON::Serializable
    getter type : String = "user_question"
    getter uuid : String
    getter message : String
  end

  struct PromptSuggestionMessage < Message
    include JSON::Serializable

    getter type : String = "prompt_suggestion"
    getter uuid : String
    getter session_id : String
    getter suggestion : String
  end

  # Message from the user
  struct UserMessage < Message
    include JSON::Serializable

    getter type : String = "user"
    getter uuid : String?
    getter session_id : String
    getter message : Hash(String, JSON::Any)
    getter parent_tool_use_id : String?
    getter tool_use_result : JSON::Any?
  end

  # Base type for system messages emitted by the CLI
  abstract struct SystemMessage < Message
    getter type : String = "system"
    getter subtype : String
    getter session_id : String
    getter data : MessageData

    def initialize(@subtype : String, @session_id : String, @data : MessageData)
    end

    def []?(key : String) : JSON::Any?
      data[key]?
    end

    def [](key : String) : JSON::Any
      data[key]
    end
  end

  struct GenericSystemMessage < SystemMessage
    def initialize(subtype : String, session_id : String, data : MessageData)
      super(subtype, session_id, data)
    end
  end

  struct InitMessage < SystemMessage
    getter server_info : ServerInfo

    def initialize(session_id : String, data : MessageData, @server_info : ServerInfo)
      super("init", session_id, data)
    end

    def commands : Array(ServerCommand)
      server_info.commands
    end

    def slash_commands : Array(String)
      values = data["slash_commands"]?.try(&.as_a?)
      return values.compact_map(&.as_s?) if values

      server_info.slash_commands
    end

    def output_style : String?
      server_info.output_style
    end

    def available_output_styles : Array(String)
      server_info.available_output_styles
    end

    def agents : Array(ServerAgentInfo)
      server_info.agents
    end

    def models : Array(ServerModelInfo)
      server_info.models
    end

    def account : ServerAccountInfo?
      server_info.account
    end

    # Map of memory namespace (e.g., "auto", "project", "user") to the
    # on-disk path for memory files loaded in the session. The Claude Code
    # CLI emits this as an object keyed by namespace, for example
    # `{"auto":"/Users/alice/.claude/projects/<project>/memory/"}`.
    def memory_paths : Hash(String, String)
      data["memory_paths"]?.try(&.as_h?).try do |hash|
        result = {} of String => String
        hash.each do |key, value|
          if path = value.as_s?
            result[key] = path
          end
        end
        return result
      end

      {} of String => String
    end

    # Convenience forwarders so callers never have to reach into
    # `server_info.raw_data` for fields the CLI emits on init.
    def tools : Array(String)
      server_info.tools
    end

    def skills : Array(String)
      server_info.skills
    end

    def mcp_servers : Array(JSON::Any)
      server_info.mcp_servers
    end

    def plugins : Array(JSON::Any)
      server_info.plugins
    end

    def cwd : String?
      server_info.cwd
    end

    def model : String?
      server_info.model
    end

    def permission_mode : String?
      server_info.permission_mode
    end

    def fast_mode_state : String?
      server_info.fast_mode_state
    end

    def claude_code_version : String?
      server_info.claude_code_version
    end
  end

  struct TaskUsage
    getter total_tokens : Int64?
    getter tool_uses : Int64?
    getter duration_ms : Int64?

    def initialize(
      @total_tokens : Int64? = nil,
      @tool_uses : Int64? = nil,
      @duration_ms : Int64? = nil,
    )
    end

    def self.from_any(value : JSON::Any?) : TaskUsage?
      data = value.try(&.as_h?)
      return nil unless data

      new(
        total_tokens: data["total_tokens"]?.try(&.as_i64?),
        tool_uses: data["tool_uses"]?.try(&.as_i64?),
        duration_ms: data["duration_ms"]?.try(&.as_i64?),
      )
    end
  end

  struct TaskStartedMessage < SystemMessage
    getter uuid : String
    getter task_id : String
    getter description : String
    getter tool_use_id : String?
    getter task_type : String?

    def initialize(
      session_id : String,
      data : MessageData,
      @uuid : String,
      @task_id : String,
      @description : String,
      @tool_use_id : String? = nil,
      @task_type : String? = nil,
    )
      super("task_started", session_id, data)
    end
  end

  struct TaskProgressMessage < SystemMessage
    getter uuid : String
    getter task_id : String
    getter description : String
    getter usage : TaskUsage
    getter tool_use_id : String?
    getter last_tool_name : String?
    getter summary : String?

    def initialize(
      session_id : String,
      data : MessageData,
      @uuid : String,
      @task_id : String,
      @description : String,
      @usage : TaskUsage,
      @tool_use_id : String? = nil,
      @last_tool_name : String? = nil,
      @summary : String? = nil,
    )
      super("task_progress", session_id, data)
    end
  end

  struct TaskNotificationMessage < SystemMessage
    getter uuid : String
    getter task_id : String
    getter status : String
    getter output_file : String?
    getter summary : String?
    getter usage : TaskUsage?
    getter tool_use_id : String?

    def initialize(
      session_id : String,
      data : MessageData,
      @uuid : String,
      @task_id : String,
      @status : String,
      @output_file : String? = nil,
      @summary : String? = nil,
      @usage : TaskUsage? = nil,
      @tool_use_id : String? = nil,
    )
      super("task_notification", session_id, data)
    end
  end

  struct RateLimitInfo
    getter status : String
    getter resets_at : Int64?
    getter rate_limit_type : String?
    getter utilization : Float64?
    getter overage_status : String?
    getter overage_resets_at : Int64?
    getter overage_disabled_reason : String?
    getter raw : MessageData

    def initialize(
      @status : String,
      @resets_at : Int64? = nil,
      @rate_limit_type : String? = nil,
      @utilization : Float64? = nil,
      @overage_status : String? = nil,
      @overage_resets_at : Int64? = nil,
      @overage_disabled_reason : String? = nil,
      @raw : MessageData = {} of String => JSON::Any,
    )
    end

    def self.from_data(data : MessageData) : RateLimitInfo?
      status = data["status"]?.try(&.as_s?)
      return nil unless status

      new(
        status: status,
        resets_at: data["resetsAt"]?.try(&.as_i64?),
        rate_limit_type: data["rateLimitType"]?.try(&.as_s?),
        utilization: data["utilization"]?.try { |value| value.as_f? || value.as_i64?.try(&.to_f64) },
        overage_status: data["overageStatus"]?.try(&.as_s?),
        overage_resets_at: data["overageResetsAt"]?.try(&.as_i64?),
        overage_disabled_reason: data["overageDisabledReason"]?.try(&.as_s?),
        raw: data,
      )
    end
  end

  struct RateLimitEvent < Message
    getter type : String = "rate_limit_event"
    getter uuid : String
    getter session_id : String
    getter rate_limit_info : RateLimitInfo
    getter data : MessageData

    def initialize(
      @uuid : String,
      @session_id : String,
      @rate_limit_info : RateLimitInfo,
      @data : MessageData,
    )
    end
  end

  # Emitted on retryable API errors; exposes attempt counters and delay.
  struct ApiRetryMessage < SystemMessage
    getter attempt : Int64?
    getter max_retries : Int64?
    getter delay_ms : Int64?
    getter status : Int64?
    getter error : String?

    def initialize(
      session_id : String,
      data : MessageData,
      @attempt : Int64? = nil,
      @max_retries : Int64? = nil,
      @delay_ms : Int64? = nil,
      @status : Int64? = nil,
      @error : String? = nil,
    )
      super("api_retry", session_id, data)
    end
  end

  # Emitted when the CLI loads additional memory entries into the session.
  # `memory_paths` maps namespace (e.g. "auto", "project", "user") to the
  # on-disk directory holding that namespace's memory files.
  struct MemoryRecallMessage < SystemMessage
    getter memory_paths : Hash(String, String)

    def initialize(
      session_id : String,
      data : MessageData,
      @memory_paths : Hash(String, String),
    )
      super("memory_recall", session_id, data)
    end
  end

  # Streaming status signal (e.g. "requesting" emitted before each API call
  # when `include_partial_messages` is enabled).
  struct StatusMessage < SystemMessage
    getter status : String

    def initialize(
      session_id : String,
      data : MessageData,
      @status : String,
    )
      super("status", session_id, data)
    end
  end

  # Emitted when an external session-store adapter fails to mirror an append.
  struct MirrorErrorMessage < Message
    getter type : String = "mirror_error"
    getter uuid : String?
    getter session_id : String
    getter error : String
    getter data : MessageData

    def initialize(
      @uuid : String?,
      @session_id : String,
      @error : String,
      @data : MessageData,
    )
    end
  end

  struct ElicitationCompleteMessage < SystemMessage
    getter uuid : String
    getter mcp_server_name : String
    getter elicitation_id : String

    def initialize(
      session_id : String,
      data : MessageData,
      @uuid : String,
      @mcp_server_name : String,
      @elicitation_id : String,
    )
      super("elicitation_complete", session_id, data)
    end
  end

  # Compact boundary message - emitted when CLI compacts the session
  struct CompactBoundaryMessage < SystemMessage
    getter uuid : String

    # Metadata about the compaction event
    struct CompactMetadata
      include JSON::Serializable
      getter trigger : String # "manual" or "auto"
      getter pre_tokens : Int64
    end

    getter compact_metadata : CompactMetadata

    def initialize(
      session_id : String,
      data : MessageData,
      @uuid : String,
      @compact_metadata : CompactMetadata,
    )
      super("compact_boundary", session_id, data)
    end
  end

  # Hook event message - emitted when CLI hooks trigger (if include_hook_events is true)
  struct HookEventMessage < SystemMessage
    getter uuid : String?
    getter hook_event_name : String

    def initialize(
      session_id : String,
      data : MessageData,
      @uuid : String?,
      subtype : String,
      @hook_event_name : String,
    )
      super(subtype, session_id, data)
    end
  end

  struct DeferredToolUse
    include JSON::Serializable
    getter id : String
    getter name : String
    getter input : Hash(String, JSON::Any)
  end

  # Final result message
  struct ResultMessage < Message
    include JSON::Serializable

    getter type : String = "result"
    getter uuid : String
    getter session_id : String
    getter subtype : String
    getter result : String?
    getter cost_usd : Float64?
    getter duration_ms : Int64?
    getter duration_api_ms : Int64?
    getter is_error : Bool?
    getter num_turns : Int32?
    getter stop_reason : String?
    # Reason the query loop terminated. Example values:
    # "completed", "aborted_tools", "max_turns", "blocking_limit",
    # "max_budget_usd", "max_session_duration_ms", "error", "resume".
    getter terminal_reason : String?
    # Non-fatal errors accumulated during the run (present on some result
    # subtypes, may be omitted entirely).
    getter errors : Array(JSON::Any)?
    getter total_cost_usd : Float64?
    getter structured_output : JSON::Any?
    getter usage : Hash(String, JSON::Any)?
    # HTTP status of the final API error, if the run ended with a network
    # failure. Nil for successful runs.
    getter api_error_status : Int64?
    # Per-model usage breakdown keyed by model ID
    # (e.g., `{"claude-sonnet-4-6": {"input_tokens": ..., ...}}`).
    @[JSON::Field(key: "modelUsage")]
    getter model_usage : Hash(String, JSON::Any)?
    # List of permission denials that occurred during the run.
    getter permission_denials : Array(JSON::Any)?
    # Fast-mode state at the time the run completed ("on", "off", ...).
    getter fast_mode_state : String?
    @[JSON::Field(key: "deferred_tool_use")]
    getter deferred_tool_use : DeferredToolUse?

    # --- Structured Output Helpers ---

    # Check if the result was successful
    def success? : Bool
      subtype == "success"
    end

    # Check if structured output is present and not null
    def has_structured_output? : Bool
      so = structured_output
      return false if so.nil?
      !so.raw.nil?
    end

    # Get structured output as a Hash (returns nil if not an object)
    def structured_output_hash : Hash(String, JSON::Any)?
      structured_output.try(&.as_h?)
    end

    # Get structured output as an Array (returns nil if not an array)
    def structured_output_array : Array(JSON::Any)?
      structured_output.try(&.as_a?)
    end

    # Get a value from structured output by key
    def get_output(key : String) : JSON::Any?
      structured_output_hash.try(&.[key]?)
    end

    # Get a string value from structured output
    def get_output_string(key : String) : String?
      get_output(key).try(&.as_s?)
    end

    # Get an integer value from structured output
    def get_output_int(key : String) : Int64?
      get_output(key).try(&.as_i64?)
    end

    # Get a float value from structured output
    def get_output_float(key : String) : Float64?
      get_output(key).try(&.as_f?)
    end

    # Get a boolean value from structured output
    def get_output_bool(key : String) : Bool?
      get_output(key).try(&.as_bool?)
    end

    # Get an array value from structured output
    def get_output_array(key : String) : Array(JSON::Any)?
      get_output(key).try(&.as_a?)
    end

    # Get a nested object from structured output
    def get_output_hash(key : String) : Hash(String, JSON::Any)?
      get_output(key).try(&.as_h?)
    end

    # Iterate over structured output if it's an object
    def each_output(&)
      structured_output_hash.try(&.each { |key, value| yield key, value })
    end
  end

  # Streaming event for partial content (when include_partial_messages is true)
  struct StreamEvent < Message
    include JSON::Serializable

    getter type : String = "stream_event"
    getter uuid : String
    getter session_id : String
    getter event : Hash(String, JSON::Any)
    getter parent_tool_use_id : String?
  end

  # Control request from CLI to SDK (for SDK MCP server integration)
  # This message type is used by the CLI to route tool calls back to SDK MCP servers
  struct ControlRequest < Message
    include JSON::Serializable

    getter type : String = "control_request"
    @[JSON::Field(key: "request_id")]
    getter request_id : String
    @[JSON::Field(converter: ClaudeAgent::ControlRequestInnerConverter)]
    getter request : ControlRequestInner
  end

  # Control response from CLI (acknowledgment of our control requests)
  # These are responses to requests we sent, not requests for us to handle
  struct ControlResponseMessage < Message
    include JSON::Serializable

    getter type : String = "control_response"
    getter response : Hash(String, JSON::Any)
  end

  struct UnknownMessage < Message
    getter type : String
    getter data : MessageData

    def initialize(@type : String, @data : MessageData)
    end

    def []?(key : String) : JSON::Any?
      data[key]?
    end

    def [](key : String) : JSON::Any
      data[key]
    end
  end
end
