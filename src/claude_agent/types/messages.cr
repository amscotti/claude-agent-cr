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
      "user"               => ->(json : String, data : MessageData) { UserMessage.parse_envelope(json, data).as(Message) },
      "result"             => ->(json : String, _data : MessageData) { ResultMessage.from_json(json).as(Message) },
      "permission_request" => ->(json : String, _data : MessageData) { PermissionRequest.from_json(json).as(Message) },
      "prompt_suggestion"  => ->(json : String, _data : MessageData) { PromptSuggestionMessage.from_json(json).as(Message) },
      "user_question"      => ->(json : String, _data : MessageData) { UserQuestion.from_json(json).as(Message) },
      "stream_event"       => ->(json : String, _data : MessageData) { StreamEvent.from_json(json).as(Message) },
      "tool_progress"      => ->(json : String, _data : MessageData) { ToolProgressMessage.from_json(json).as(Message) },
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
      when "task_updated"
        parse_task_updated(message, session_id)
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
      when "command_lifecycle"
        parse_command_lifecycle(message, session_id)
      when "background_tasks_changed"
        parse_background_tasks_changed(message, session_id)
      when "model_fallback"
        parse_model_fallback(message, session_id)
      when "worker_shutting_down"
        parse_worker_shutting_down(message, session_id)
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

    # Background tasks can finish *only* via a `system/task_updated` event
    # (e.g. a task stopped via `TaskStop` reports `status: "killed"` here).
    # Without this parser, consumers tracking active task IDs would hang
    # waiting for a `task_notification` that never arrives. Mirrors the
    # Python SDK's `TaskUpdatedMessage` (0.2.101).
    private def self.parse_task_updated(data : MessageData, session_id : String) : Message
      task_id = data["task_id"]?.try(&.as_s)
      return GenericSystemMessage.new("task_updated", session_id, data) unless task_id

      patch = data["patch"]?.try(&.as_h?) || {} of String => JSON::Any
      # Terminal-ness derives from `patch.status` only (matching the
      # Python SDK): a patch carrying just end_time/result/error is left
      # non-terminal; the full patch stays available on `#patch`.
      status = patch["status"]?.try(&.as_s?)

      TaskUpdatedMessage.new(
        session_id,
        data,
        task_id,
        patch,
        status,
        data["uuid"]?.try(&.as_s?),
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

    # Reports a uuid-stamped command/message's lifecycle state
    # (queued/started/completed/cancelled/discarded). Matches the TS SDK's
    # command_lifecycle frames (0.3.206+).
    private def self.parse_command_lifecycle(data : MessageData, session_id : String) : Message
      uuid = data["uuid"]?.try(&.as_s)
      state = data["state"]?.try(&.as_s)
      return GenericSystemMessage.new("command_lifecycle", session_id, data) unless uuid && state

      CommandLifecycleMessage.new(
        session_id,
        data,
        uuid,
        state,
        data["message_uuid"]?.try(&.as_s?) || data["messageUuid"]?.try(&.as_s?),
      )
    end

    # Full-set membership of live background tasks (REPLACE semantics).
    # Matches the TS SDK's `SDKBackgroundTasksChangedMessage` (0.3.203+).
    private def self.parse_background_tasks_changed(data : MessageData, session_id : String) : Message
      tasks_raw = data["tasks"]?.try(&.as_a?)
      return GenericSystemMessage.new("background_tasks_changed", session_id, data) unless tasks_raw

      tasks = tasks_raw.compact_map do |entry|
        hash = entry.as_h?
        next unless hash
        task_id = hash["task_id"]?.try(&.as_s?) || hash["taskId"]?.try(&.as_s?)
        next unless task_id
        BackgroundTaskEntry.new(
          task_id: task_id,
          task_type: hash["task_type"]?.try(&.as_s?) || hash["taskType"]?.try(&.as_s?),
          description: hash["description"]?.try(&.as_s?),
        )
      end

      BackgroundTasksChangedMessage.new(
        session_id,
        data,
        tasks,
        data["uuid"]?.try(&.as_s?),
      )
    end

    # Model fallback trigger (distinct from model_refusal_fallback).
    # Triggers: model_not_found, permission_denied, overloaded,
    # server_error, last_resort. Matches TS SDK 0.3.174+.
    private def self.parse_model_fallback(data : MessageData, session_id : String) : Message
      trigger = data["trigger"]?.try(&.as_s)
      return GenericSystemMessage.new("model_fallback", session_id, data) unless trigger

      ModelFallbackMessage.new(
        session_id,
        data,
        trigger,
        data["original_model"]?.try(&.as_s?) || data["originalModel"]?.try(&.as_s?),
        data["fallback_model"]?.try(&.as_s?) || data["fallbackModel"]?.try(&.as_s?),
        data["uuid"]?.try(&.as_s?),
      )
    end

    # Remote Control worker graceful exit notice. Matches the TS SDK's
    # `SDKWorkerShuttingDownMessage` (0.3.178+).
    private def self.parse_worker_shutting_down(data : MessageData, session_id : String) : Message
      reason = data["reason"]?.try(&.as_s)
      return GenericSystemMessage.new("worker_shutting_down", session_id, data) unless reason

      WorkerShuttingDownMessage.new(
        session_id,
        data,
        reason,
        data["uuid"]?.try(&.as_s?),
      )
    end
  end

  # Display-friendly metadata for one `tool_use` block on an assistant
  # message, sourced from MCP server directory metadata. The CLI emits
  # `tool_use_meta` as an *array* of these entries (snake_case keys),
  # each referencing its block via `id`. Optional fields are absent for
  # tools without directory entries.
  struct ToolUseMeta
    include JSON::Serializable

    # The `tool_use` block id this metadata belongs to.
    getter id : String
    # Human-readable label for the tool call (e.g. "Search GitHub").
    getter display_name : String
    # Display name of the MCP server providing the tool, if any.
    getter server_display_name : String?
    # Absolute URL of an icon the SDK consumer can render for the call.
    getter icon_url : String?

    def initialize(
      @id : String,
      @display_name : String,
      @server_display_name : String? = nil,
      @icon_url : String? = nil,
    )
    end
  end

  # Structured refusal detail paired with `stop_reason: "refusal"`.
  # Mirrors the API's `BetaRefusalStopDetails`. All fields are nullable
  # on the wire; `category` is an open string ("cyber", "bio", ...) —
  # new categories ship ahead of schema updates.
  struct StopDetails
    include JSON::Serializable

    # Policy category that triggered the refusal, when known.
    getter category : String?
    # Human-readable explanation. Unstable prose — display only.
    getter explanation : String?
    # Opaque token refunding the cache-miss cost when retrying the
    # refused request on a fallback model.
    getter fallback_credit_token : String?

    def initialize(
      @category : String? = nil,
      @explanation : String? = nil,
      @fallback_credit_token : String? = nil,
    )
    end
  end

  # What triggered a message/result. Wire shape is a discriminated
  # object: `{"kind": "human"}`, `{"kind": "task-notification"}`,
  # `{"kind": "peer", "from": ..., "name": ...}`, etc. Only `kind` is
  # always present; the other fields are variant-specific.
  struct MessageOrigin
    include JSON::Serializable

    # Origin kind: "human", "channel", "peer", "task-notification",
    # "coordinator", "observer", "auto-continuation", ... (open set).
    getter kind : String
    # For "channel": the originating server name.
    getter server : String?
    # For "peer"/"observer": the sending session/agent identifier.
    getter from : String?
    # For "peer": optional display name of the sender.
    getter name : String?
    # For "peer"/"observer": task id of the in-process background
    # subagent that sent the message.
    @[JSON::Field(key: "senderTaskId")]
    getter sender_task_id : String?
    # For "task-notification": e.g. "scheduled-trigger" when the delivery
    # is the fired prompt of a user-configured scheduled task. Matches
    # the TS SDK's `SDKMessageOrigin` subkind (0.3.214+).
    getter subkind : String?
    # For "peer": decoded message body with the peer envelope stripped.
    # Present only when the turn is a harness-formed envelope; render
    # this instead of re-parsing the message text. Matches TS 0.3.205+.
    getter body : String?

    def initialize(
      @kind : String,
      @server : String? = nil,
      @from : String? = nil,
      @name : String? = nil,
      @sender_task_id : String? = nil,
      @subkind : String? = nil,
      @body : String? = nil,
    )
    end

    # True when this result was triggered by a human-authored prompt.
    def human? : Bool
      kind == "human"
    end

    # True when this result is a background-task followup.
    def task_notification? : Bool
      kind == "task-notification"
    end

    # True when this is a scheduled-task fired prompt delivery.
    def scheduled_trigger? : Bool
      subkind == "scheduled-trigger"
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
    # Structured detail paired with `stop_reason: "refusal"` so consumers
    # can detect why generation stopped without text-matching the error
    # content. Wire shape matches the API's `BetaRefusalStopDetails`
    # (category/explanation/fallback_credit_token). Nil for non-refusal
    # stops and on older CLIs. Matches the TS SDK's `stop_details` (0.3.162).
    getter stop_details : StopDetails?
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

    # Optional display-metadata sidecar for this message's `tool_use`
    # blocks. The CLI (v2.1.179+) emits an array of entries (each
    # referencing its block via `id`) with human-readable labels and an
    # `icon_url` sourced from MCP server directory metadata, so SDK
    # consumers can render friendly tool-call chips instead of raw wire
    # names. Absent on older CLIs and when no tool has directory
    # metadata. Sits on the envelope (sibling to `message`). Matches the
    # TS SDK's `tool_use_meta` (0.3.179 / 0.3.181).
    getter tool_use_meta : Array(ToolUseMeta)?

    # ISO-8601 timestamp of when this content finished on the originating
    # process. One API assistant turn may produce several assistant
    # messages sharing a message.id, each with its own timestamp. Older
    # emitters omit it; consumers should fall back to receive time.
    # Matches the TS SDK's `SDKAssistantMessage.timestamp` (0.3.211+).
    getter timestamp : String?

    # True when this assistant message was truncated by an interrupt/abort
    # before the stream completed (`stop_reason` was never received and
    # content may end mid-word). Absent on normally completed messages.
    # Matches the TS SDK's `aborted` (0.3.214+).
    getter aborted : Bool?

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

    # Structured refusal detail paired with `stop_reason: "refusal"`.
    def stop_details : StopDetails?
      message.stop_details
    end

    # True when the assistant turn ended because the model refused. Lets
    # consumers branch on refusals without text-matching the content.
    def refusal? : Bool
      message.stop_reason == "refusal"
    end

    # True when the message was truncated mid-stream by interrupt/abort.
    def aborted? : Bool
      aborted == true
    end

    # Look up display metadata for a specific `tool_use` block id.
    # Nil when the CLI did not emit the sidecar or the id has no entry.
    def tool_use_meta_for(tool_use_id : String) : ToolUseMeta?
      tool_use_meta.try(&.find { |meta| meta.id == tool_use_id })
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

  # Sidecar classifying a non-executed tool_result (denied, interrupted,
  # cancelled, etc.) so consumers can avoid string-matching result prose.
  # The CLI emits an *array* of these entries (keyed by tool use `id`),
  # same shape as `tool_use_meta`. Matches the TS SDK's `tool_result_meta`
  # (0.3.216+).
  struct ToolResultMeta
    include JSON::Serializable

    # Tool-use block id this meta entry refers to.
    getter id : String?
    # Why the tool did not execute, e.g. "denied", "interrupted",
    # "cancelled", "deferred". Open string for forward compatibility.
    getter non_execution_kind : String?
    # Optional user-facing feedback accompanying the non-execution
    # (e.g. the deny message shown to the model).
    getter user_feedback : String?

    def initialize(
      @id : String? = nil,
      @non_execution_kind : String? = nil,
      @user_feedback : String? = nil,
    )
    end

    def self.from_any(value : JSON::Any) : ToolResultMeta?
      data = value.as_h?
      return unless data

      new(
        id: data["id"]?.try(&.as_s?),
        non_execution_kind: data["non_execution_kind"]?.try(&.as_s?) ||
                            data["nonExecutionKind"]?.try(&.as_s?),
        user_feedback: data["user_feedback"]?.try(&.as_s?) ||
                       data["userFeedback"]?.try(&.as_s?),
      )
    end

    def self.from_any_array(value : JSON::Any?) : Array(ToolResultMeta)?
      return unless value

      if arr = value.as_a?
        result = arr.compact_map { |entry| from_any(entry) }
        return result.empty? ? nil : result
      end

      # Older sketches used a single object instead of an array.
      if single = from_any(value)
        return [single]
      end

      nil
    end
  end

  # Optional file attachment on a live user message (or user-message
  # replay). Wire shapes vary; only common fields are typed. Extra keys
  # remain available via `raw`. Matches TS SDK `file_attachments` (0.3.181+).
  struct FileAttachment
    include JSON::Serializable

    getter path : String?
    getter name : String?
    @[JSON::Field(key: "media_type")]
    getter media_type : String?
    @[JSON::Field(ignore: true)]
    getter raw : Hash(String, JSON::Any)?

    def initialize(
      @path : String? = nil,
      @name : String? = nil,
      @media_type : String? = nil,
      @raw : Hash(String, JSON::Any)? = nil,
    )
    end

    def self.from_any(value : JSON::Any) : FileAttachment?
      data = value.as_h?
      return unless data

      new(
        path: data["path"]?.try(&.as_s?),
        name: data["name"]?.try(&.as_s?) || data["filename"]?.try(&.as_s?),
        media_type: data["media_type"]?.try(&.as_s?) ||
                    data["mediaType"]?.try(&.as_s?) ||
                    data["mime_type"]?.try(&.as_s?) ||
                    data["mimeType"]?.try(&.as_s?),
        raw: data,
      )
    end

    def self.from_any_array(value : JSON::Any?) : Array(FileAttachment)?
      arr = value.try(&.as_a?)
      return unless arr

      result = arr.compact_map { |entry| from_any(entry) }
      result.empty? ? nil : result
    end
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
    # Sidecar array for non-executed tool calls (one entry per tool_use id).
    # Absent when tools ran normally or on older CLIs. CLI v2.1.220 emits an
    # array (same pattern as `tool_use_meta`). Matches TS SDK 0.3.216+.
    @[JSON::Field(ignore: true)]
    getter tool_result_meta : Array(ToolResultMeta)?
    # True when this envelope is metadata/synthetic (not a real user
    # prompt). Wire keys: `isMeta`, `is_meta`, or `isSynthetic` (mapped
    # into `is_meta` on parse — TS SDK 0.3.198+).
    getter is_meta : Bool?
    # Optional explicit synthetic flag when the wire uses `isSynthetic`
    # without also setting `isMeta`. Prefer `meta?` for classification.
    getter is_synthetic : Bool?
    # Optional file attachments on live / replayed user messages.
    # Matches TS SDK `file_attachments` (0.3.181+).
    getter file_attachments : Array(FileAttachment)?

    def initialize(
      @uuid : String? = nil,
      @session_id : String = "",
      @message : Hash(String, JSON::Any) = {} of String => JSON::Any,
      @parent_tool_use_id : String? = nil,
      @tool_use_result : JSON::Any? = nil,
      @tool_result_meta : Array(ToolResultMeta)? = nil,
      @is_meta : Bool? = nil,
      @is_synthetic : Bool? = nil,
      @file_attachments : Array(FileAttachment)? = nil,
    )
      @type = "user"
    end

    # True when this user envelope is meta/synthetic (not a real prompt).
    def meta? : Bool
      is_meta == true || is_synthetic == true
    end

    # Look up non-execution meta for a specific tool_use id.
    def tool_result_meta_for(tool_use_id : String) : ToolResultMeta?
      tool_result_meta.try(&.find { |meta| meta.id == tool_use_id })
    end

    # Parse a user envelope, normalizing dual wire keys and mapping
    # `isSynthetic` → `is_meta` when `isMeta`/`is_meta` are absent.
    def self.parse_envelope(json : String, data : MessageData) : UserMessage
      base = from_json(json)

      is_synthetic = data["isSynthetic"]?.try(&.as_bool?)
      is_synthetic = data["is_synthetic"]?.try(&.as_bool?) if is_synthetic.nil?
      is_synthetic = base.is_synthetic if is_synthetic.nil?

      is_meta = data["isMeta"]?.try(&.as_bool?)
      is_meta = data["is_meta"]?.try(&.as_bool?) if is_meta.nil?
      is_meta = base.is_meta if is_meta.nil?
      # TS SDK maps isSynthetic → isMeta on ingestion (0.3.198).
      is_meta = is_synthetic if is_meta.nil? && !is_synthetic.nil?

      # Prefer manual parse so mediaType / filename dual keys are handled.
      attachments = FileAttachment.from_any_array(data["file_attachments"]?)
      attachments = base.file_attachments if attachments.nil?

      # CLI emits an array of meta entries (and historically may emit a
      # single object). Never go through JSON::Serializable for this field.
      meta = ToolResultMeta.from_any_array(data["tool_result_meta"]?)
      meta = ToolResultMeta.from_any_array(data["toolResultMeta"]?) if meta.nil?

      new(
        uuid: base.uuid,
        session_id: base.session_id,
        message: base.message,
        parent_tool_use_id: base.parent_tool_use_id,
        tool_use_result: base.tool_use_result,
        tool_result_meta: meta,
        is_meta: is_meta,
        is_synthetic: is_synthetic,
        file_attachments: attachments,
      )
    end
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
      return unless data

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

  # Task statuses that mean the task has finished and should be cleared
  # from any "active task" tracking. This set spans both lifecycle
  # vocabularies: `task_notification` reports `stopped` (the CLI's mapped
  # form of a killed task) while `task_updated` reports the raw `killed`.
  # Consumers should treat the `status` of a `TaskNotificationMessage` and
  # a `TaskUpdatedMessage` the same way. Matches the Python SDK's
  # `TERMINAL_TASK_STATUSES` frozenset (0.2.101).
  TERMINAL_TASK_STATUSES = Set{"completed", "failed", "stopped", "killed"}

  # Emitted when a background task's state changes. The CLI emits
  # `system`/`task_updated` events as a task moves through its lifecycle.
  # `patch` carries the changed fields (e.g. `status`, `end_time`); when
  # `patch.status` is terminal (see `TERMINAL_TASK_STATUSES`) the task has
  # finished.
  #
  # Lifecycle note: a background task's terminal state can arrive *only*
  # as a `TaskUpdatedMessage` with no accompanying `TaskNotificationMessage`
  # — for example a task stopped via `TaskStop` reports `status="killed"`
  # here. Consumers that track active task IDs should therefore clear them
  # on a terminal status from *either* message type.
  struct TaskUpdatedMessage < SystemMessage
    getter task_id : String
    getter patch : MessageData
    getter status : String?
    getter uuid : String?

    def initialize(
      session_id : String,
      data : MessageData,
      @task_id : String,
      @patch : MessageData,
      @status : String? = nil,
      @uuid : String? = nil,
    )
      super("task_updated", session_id, data)
    end

    # True when this update reports a terminal status. Safe to call even
    # when `status` is nil (returns false). Consumers tracking active tasks
    # should clear the task from their bookkeeping when this is true.
    def terminal? : Bool
      status = @status
      return false unless status
      TERMINAL_TASK_STATUSES.includes?(status)
    end
  end

  # Per-model weekly rate-limit window entry (camelCase or snake_case).
  # Appears on rate-limit / usage payloads as `model_scoped`.
  struct ModelScopedRateLimit
    getter display_name : String?
    getter utilization : Float64?
    getter resets_at : String?

    def initialize(
      @display_name : String? = nil,
      @utilization : Float64? = nil,
      @resets_at : String? = nil,
    )
    end

    def self.from_any(value : JSON::Any) : ModelScopedRateLimit?
      data = value.as_h?
      return unless data

      new(
        display_name: data["display_name"]?.try(&.as_s?) || data["displayName"]?.try(&.as_s?),
        utilization: data["utilization"]?.try { |v| v.as_f? || v.as_i64?.try(&.to_f64) },
        resets_at: data["resets_at"]?.try(&.as_s?) || data["resetsAt"]?.try(&.as_s?),
      )
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
    # Credits-required rate-limit error code (e.g. "credits_required").
    # Wire key is camelCase `errorCode`. Matches TS SDK 0.3.181+.
    getter error_code : String?
    # Whether the user can purchase credits to continue. Wire key
    # `canUserPurchaseCredits`.
    getter can_user_purchase_credits : Bool?
    # Whether a chargeable saved payment method is on file. Wire key
    # `hasChargeableSavedPaymentMethod`.
    getter has_chargeable_saved_payment_method : Bool?
    # Per-model weekly limit windows with utilization and reset times.
    getter model_scoped : Array(ModelScopedRateLimit)?
    getter raw : MessageData

    def initialize(
      @status : String,
      @resets_at : Int64? = nil,
      @rate_limit_type : String? = nil,
      @utilization : Float64? = nil,
      @overage_status : String? = nil,
      @overage_resets_at : Int64? = nil,
      @overage_disabled_reason : String? = nil,
      @error_code : String? = nil,
      @can_user_purchase_credits : Bool? = nil,
      @has_chargeable_saved_payment_method : Bool? = nil,
      @model_scoped : Array(ModelScopedRateLimit)? = nil,
      @raw : MessageData = {} of String => JSON::Any,
    )
    end

    def self.from_data(data : MessageData) : RateLimitInfo?
      status = data["status"]?.try(&.as_s?)
      return unless status

      model_scoped = data["model_scoped"]?.try(&.as_a?).try do |arr|
        arr.compact_map { |entry| ModelScopedRateLimit.from_any(entry) }
      end
      model_scoped ||= data["modelScoped"]?.try(&.as_a?).try do |arr|
        arr.compact_map { |entry| ModelScopedRateLimit.from_any(entry) }
      end

      can_purchase = data["canUserPurchaseCredits"]?.try(&.as_bool?)
      can_purchase = data["can_user_purchase_credits"]?.try(&.as_bool?) if can_purchase.nil?

      has_payment = data["hasChargeableSavedPaymentMethod"]?.try(&.as_bool?)
      has_payment = data["has_chargeable_saved_payment_method"]?.try(&.as_bool?) if has_payment.nil?

      new(
        status: status,
        resets_at: data["resetsAt"]?.try(&.as_i64?),
        rate_limit_type: data["rateLimitType"]?.try(&.as_s?),
        utilization: data["utilization"]?.try { |value| value.as_f? || value.as_i64?.try(&.to_f64) },
        overage_status: data["overageStatus"]?.try(&.as_s?),
        overage_resets_at: data["overageResetsAt"]?.try(&.as_i64?),
        overage_disabled_reason: data["overageDisabledReason"]?.try(&.as_s?),
        error_code: data["errorCode"]?.try(&.as_s?) || data["error_code"]?.try(&.as_s?),
        can_user_purchase_credits: can_purchase,
        has_chargeable_saved_payment_method: has_payment,
        model_scoped: model_scoped,
        raw: data,
      )
    end
  end

  # Recognized `rateLimitType` values emitted by the CLI. The Crystal SDK
  # keeps `rate_limit_type` as an open `String?` for forward compatibility,
  # but this set documents the values the CLI is known to emit — useful for
  # `case` dispatch or UI labeling. See
  # https://docs.claude.com/en/docs/claude-code/rate-limits.
  RATE_LIMIT_TYPES = Set{
    "five_hour",
    "seven_day",
    "seven_day_opus",
    "seven_day_sonnet",
    # Per-model weekly overage/pay-as-you-go window (TS SDK 0.3.191).
    "seven_day_overage_included",
    "overage",
  }

  # Rate-limit / usage-limit message prefix buckets for classifying free-text
  # rate-limit notices without hand-mirrored lists. Alpha parity with the TS
  # SDK's `@alpha` exports (0.3.211+). Match with `String#starts_with?`.
  USAGE_LIMIT_ERROR_PREFIXES = [
    "You've hit your",
    "You've reached your",
    "You're out of usage credits",
    "Your org is out of usage · add funds to continue",
    "Your org is out of usage · contact your admin",
    "Your seat type doesn't include usage credits",
    "Your seat type doesn't include usage",
    "Your usage allocation has been disabled by your admin",
    "Your group's usage limit is set to $0",
    "Fable 5 requires usage credits",
    "You're out of extra usage",
    "Your seat type doesn't include extra usage",
  ]

  USAGE_WARNING_PREFIXES = [
    "You've used",
    "You're close to",
  ]

  USAGE_TRANSITION_PREFIXES = [
    "You're now using usage credits",
    "You're now using your usage allocation",
    "Now using your usage allocation",
    "Now using usage credits",
    "You're now using extra usage",
    "Now using extra usage",
  ]

  ORG_POLICY_LIMIT_PREFIXES = [
    "This service is disabled for your org",
  ]

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

  # Recognized `command_lifecycle` states for a uuid-stamped message.
  COMMAND_LIFECYCLE_STATES = Set{
    "queued",
    "started",
    "completed",
    "cancelled",
    "discarded",
  }

  # Uuid-stamped command/message lifecycle frame. Reports terminal state
  # transitions so hosts can track progress of individual commands in
  # stream-json sessions. Matches TS SDK 0.3.206+.
  struct CommandLifecycleMessage < SystemMessage
    getter uuid : String
    # Lifecycle state: queued / started / completed / cancelled / discarded.
    getter state : String
    # The uuid of the tracked command/message when distinct from `uuid`.
    getter message_uuid : String?

    def initialize(
      session_id : String,
      data : MessageData,
      @uuid : String,
      @state : String,
      @message_uuid : String? = nil,
    )
      super("command_lifecycle", session_id, data)
    end

    def terminal? : Bool
      state == "completed" || state == "cancelled" || state == "discarded"
    end
  end

  # One live background task as reported by `background_tasks_changed`.
  struct BackgroundTaskEntry
    getter task_id : String
    getter task_type : String?
    getter description : String?

    def initialize(
      @task_id : String,
      @task_type : String? = nil,
      @description : String? = nil,
    )
    end
  end

  # Full set of live background tasks after a membership change.
  # REPLACE semantics: swap your active set for `tasks`. Matches the TS
  # SDK's `SDKBackgroundTasksChangedMessage` (0.3.203+).
  struct BackgroundTasksChangedMessage < SystemMessage
    getter tasks : Array(BackgroundTaskEntry)
    getter uuid : String?

    def initialize(
      session_id : String,
      data : MessageData,
      @tasks : Array(BackgroundTaskEntry),
      @uuid : String? = nil,
    )
      super("background_tasks_changed", session_id, data)
    end
  end

  # Recognized `model_fallback` trigger values.
  MODEL_FALLBACK_TRIGGERS = Set{
    "model_not_found",
    "permission_denied",
    "overloaded",
    "server_error",
    "last_resort",
  }

  # Emitted when the CLI falls back to another model. Distinct from
  # `model_refusal_fallback` (refusal category). Matches TS SDK 0.3.174+.
  struct ModelFallbackMessage < SystemMessage
    # Why fallback was triggered. See `MODEL_FALLBACK_TRIGGERS`.
    getter trigger : String
    getter original_model : String?
    getter fallback_model : String?
    getter uuid : String?

    def initialize(
      session_id : String,
      data : MessageData,
      @trigger : String,
      @original_model : String? = nil,
      @fallback_model : String? = nil,
      @uuid : String? = nil,
    )
      super("model_fallback", session_id, data)
    end
  end

  # Remote Control worker graceful-exit notice so remote clients can
  # show why the session ended. Matches TS SDK 0.3.178+.
  struct WorkerShuttingDownMessage < SystemMessage
    # Short snake_case reason from the host CLI (not user input), e.g.
    # "host_exit", "remote_control_disabled".
    getter reason : String
    getter uuid : String?

    def initialize(
      session_id : String,
      data : MessageData,
      @reason : String,
      @uuid : String? = nil,
    )
      super("worker_shutting_down", session_id, data)
    end
  end

  # Subagent rate-limit retry info nested on `tool_progress` messages.
  struct SubagentRetryInfo
    include JSON::Serializable

    getter agent_id : String?
    getter attempt : Int64?
    getter max_retries : Int64?
    getter retry_delay_ms : Int64?
    getter error_status : Int64?
    getter error_category : String?

    def initialize(
      @agent_id : String? = nil,
      @attempt : Int64? = nil,
      @max_retries : Int64? = nil,
      @retry_delay_ms : Int64? = nil,
      @error_status : Int64? = nil,
      @error_category : String? = nil,
    )
    end
  end

  # Long-running tool progress (top-level `type: "tool_progress"`).
  # Matches the TS SDK's `SDKToolProgressMessage` (with 0.3.214+ fields).
  struct ToolProgressMessage < Message
    include JSON::Serializable

    getter type : String = "tool_progress"
    getter uuid : String
    getter session_id : String
    getter tool_use_id : String
    getter tool_name : String
    getter parent_tool_use_id : String?
    getter elapsed_time_seconds : Float64?
    getter task_id : String?
    getter heartbeat : Bool?
    # Subagent type when progress is from a nested agent waiting out a
    # rate-limit retry. Matches TS SDK 0.3.214+.
    getter subagent_type : String?
    getter subagent_retry : SubagentRetryInfo?
    # When true, a workflow_agent progress step was blocked by the
    # auto-mode safety classifier. Absent on non-workflow progress and
    # older CLIs. Matches TS SDK 0.3.199+ (`workflow_agent` blocked).
    getter blocked : Bool?
  end

  struct DeferredToolUse
    include JSON::Serializable
    getter id : String
    getter name : String
    getter input : Hash(String, JSON::Any)
  end

  # Per-model token usage and cost breakdown. Keys match the CLI's
  # camelCase `modelUsage` payload (and the TS/Python SDKs' `ModelUsage`).
  struct ModelUsage
    include JSON::Serializable

    @[JSON::Field(key: "inputTokens")]
    getter input_tokens : Int64 = 0
    @[JSON::Field(key: "outputTokens")]
    getter output_tokens : Int64 = 0
    @[JSON::Field(key: "cacheReadInputTokens")]
    getter cache_read_input_tokens : Int64 = 0
    @[JSON::Field(key: "cacheCreationInputTokens")]
    getter cache_creation_input_tokens : Int64 = 0
    @[JSON::Field(key: "webSearchRequests")]
    getter web_search_requests : Int64 = 0
    @[JSON::Field(key: "costUSD")]
    getter cost_usd : Float64 = 0.0
    @[JSON::Field(key: "contextWindow")]
    getter context_window : Int64 = 0
    @[JSON::Field(key: "maxOutputTokens")]
    getter max_output_tokens : Int64 = 0
    # Canonical model id used for the pricing lookup (e.g.
    # "claude-opus-4-7"). May differ from the raw model string this entry
    # is keyed by (provider-specific ids, aliases).
    @[JSON::Field(key: "canonicalModel")]
    getter canonical_model : String?
    # API provider that served this model ("firstParty", "bedrock",
    # "vertex", "foundry", "anthropicAws", "anthropicGoogleCloud",
    # "mantle", "gateway").
    getter provider : String?

    def initialize(
      @input_tokens : Int64 = 0,
      @output_tokens : Int64 = 0,
      @cache_read_input_tokens : Int64 = 0,
      @cache_creation_input_tokens : Int64 = 0,
      @web_search_requests : Int64 = 0,
      @cost_usd : Float64 = 0.0,
      @context_window : Int64 = 0,
      @max_output_tokens : Int64 = 0,
      @canonical_model : String? = nil,
      @provider : String? = nil,
    )
    end
  end

  # Permission denial recorded on a result message. Matches the TS SDK's
  # `SDKPermissionDenial` (tool_name / tool_use_id / tool_input).
  struct PermissionDenial
    include JSON::Serializable

    getter tool_name : String
    getter tool_use_id : String
    getter tool_input : Hash(String, JSON::Any)?
    # Optional reason when the CLI attaches one (open string).
    getter reason : String?
    # Discriminator from PermissionDecisionReason when present on the
    # denial payload (e.g. "safetyCheck", "asyncAgent").
    getter decision_reason_type : String?

    def initialize(
      @tool_name : String,
      @tool_use_id : String,
      @tool_input : Hash(String, JSON::Any)? = nil,
      @reason : String? = nil,
      @decision_reason_type : String? = nil,
    )
    end
  end

  # Known permission-decision reason types used by the CLI for
  # permission-denied advisories and (when present) denial payloads.
  # Open set — new values ship ahead of schema updates.
  PERMISSION_DENIAL_REASONS = Set{
    "safetyCheck",
    "asyncAgent",
    "classifier",
    "mode",
    "rule",
    "hook",
    "permissionPromptTool",
    "sandboxOverride",
    "workingDir",
    "subcommandResults",
    "other",
  }

  # Known values of `ResultMessage#terminal_reason`. Open set for
  # forward compatibility; this documents the CLI vocabulary.
  # Matches the TS SDK's `TerminalReason` (0.3.204+ expansions included).
  TERMINAL_REASONS = Set{
    "completed",
    "max_turns",
    "aborted_streaming",
    "aborted_tools",
    "tool_deferred",
    "tool_deferred_unavailable",
    "turn_setup_failed",
    "api_error",
    "malformed_tool_use_exhausted",
    "budget_exhausted",
    "structured_output_retry_exhausted",
    "max_budget_usd",
    "blocking_limit",
    "rapid_refill_breaker",
    "prompt_too_long",
    "image_error",
    "model_error",
    "stop_hook_prevented",
    "hook_stopped",
    "background_requested",
    "max_session_duration_ms",
    "error",
    "resume",
  }

  # Final result message
  struct ResultMessage < Message
    include JSON::Serializable

    getter type : String = "result"
    getter uuid : String
    getter session_id : String
    getter subtype : String
    # What triggered this result, forwarded from the originating message's
    # `origin` field. Wire shape is a `{"kind": ...}` object (e.g.
    # `{"kind": "human"}`, `{"kind": "task-notification"}`) — use
    # `origin.try(&.kind)` or the `human?`/`task_notification?` predicates
    # to distinguish user-prompted results from background-task followups.
    # Absent on older CLIs. Matches the TS SDK's `origin` (0.2.126).
    getter origin : MessageOrigin?
    getter result : String?
    getter cost_usd : Float64?
    getter duration_ms : Int64?
    getter duration_api_ms : Int64?
    getter is_error : Bool?
    getter num_turns : Int32?
    getter stop_reason : String?
    # Reason the query loop terminated. Known values include (see also
    # `TERMINAL_REASONS`):
    # - "completed" — normal successful end
    # - "max_turns" — hit max_turns limit
    # - "aborted_streaming" / "aborted_tools" — cancelled via interrupt()
    # - "tool_deferred" / "tool_deferred_unavailable" — deferred tool path
    # - "turn_setup_failed" — turn-input builder threw before the turn
    # - "api_error" — exhausted API retries
    # - "malformed_tool_use_exhausted" — repeated bad tool_use payloads
    # - "budget_exhausted" / "structured_output_retry_exhausted"
    # - "max_budget_usd", "blocking_limit", "max_session_duration_ms"
    # Open string for forward compatibility; nil on older CLIs.
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
    # Per-model usage breakdown keyed by model ID. Wire key `modelUsage`
    # (camelCase). Typed as `ModelUsage` (TS/Python parity).
    @[JSON::Field(key: "modelUsage")]
    getter model_usage : Hash(String, ModelUsage)?
    # List of permission denials that occurred during the run.
    getter permission_denials : Array(PermissionDenial)?
    # Fast-mode state at the time the run completed ("on", "off", ...).
    getter fast_mode_state : String?
    # Why fast mode is off (e.g. "free", "preference", "network_error",
    # "sdk_opt_in_required"). Absent when fast mode is on or CLI is older.
    # Matches TS SDK 0.3.219+.
    getter fast_mode_disabled_reason : String?
    # UUID of the user message that started this turn, for cross-host
    # request-latency correlation. Matches TS SDK 0.3.216+.
    getter user_message_uuid : String?
    # Wall-clock ms when the request was sent (host clock). Used with
    # `user_message_uuid` for latency correlation. Matches TS 0.3.216+.
    getter request_sent_wall_ms : Int64?
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
