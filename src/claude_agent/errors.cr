module ClaudeAgent
  # Base error class
  class Error < Exception; end

  # CLI not found
  class CLINotFoundError < Error
    getter cli_path : String?

    def initialize(message = "Claude Code CLI not found", @cli_path = nil)
      super(message)
    end
  end

  # Connection error
  class ConnectionError < Error; end

  # Process error
  class ProcessError < Error
    getter exit_code : Int32?
    getter stderr : String?

    def initialize(message : String, @exit_code : Int32? = nil, @stderr : String? = nil)
      super(message)
    end
  end

  # Raised when the CLI exits after reporting a terminal error result.
  #
  # The CLI ends a failed run by emitting a `result` message with
  # `is_error: true` (yielded to consumers as a `ResultMessage`) and then
  # exiting non-zero. This exception replaces the bare "exit code 1"
  # `ProcessError` for that case and carries the result's payload, so
  # callers can branch on *why* the run failed without string matching:
  #
  # ```
  # begin
  #   ClaudeAgent.query(prompt: "...") { |message| ... }
  # rescue ex : ClaudeAgent::ResultError
  #   retry if ex.terminal_reason == "api_error"
  # end
  # ```
  #
  # Subclasses `ProcessError`, so existing `rescue ProcessError` handlers
  # keep working. Mirrors Python's `ResultError` (0.2.140).
  class ResultError < ProcessError
    # Result subtype (`"error_max_turns"`, `"error_during_execution"`,
    # ... — or `"success"` when the agent loop completed but the last
    # turn was an API error).
    getter subtype : String?
    # Error strings reported by the CLI (may be empty).
    getter errors : Array(String)
    # Result text, if any. For API failures this holds the
    # `"API Error: ..."` prose.
    getter result_text : String?
    # HTTP status of the failing API call, if any.
    getter api_error_status : Int64?
    # Why the run ended (`"api_error"`, `"max_turns"`, ...), if reported.
    getter terminal_reason : String?
    # Session the result belongs to, if reported.
    getter session_id : String?
    # Raw `result` message payload as emitted by the CLI.
    getter data : Hash(String, JSON::Any)

    def initialize(
      message : String,
      data : Hash(String, JSON::Any) = {} of String => JSON::Any,
      exit_code : Int32? = nil,
    )
      @data = data
      @subtype = data["subtype"]?.try(&.as_s?)
      @errors = ResultError.normalize_errors(data["errors"]?)
      @result_text = data["result"]?.try(&.as_s?)
      @api_error_status = data["api_error_status"]?.try(&.as_i64?)
      @terminal_reason = data["terminal_reason"]?.try(&.as_s?)
      @session_id = data["session_id"]?.try(&.as_s?)
      super(message, exit_code: exit_code)
    end

    # Build a `ResultError` from a terminal error `ResultMessage`,
    # choosing the most informative text like Python's
    # `_error_result_text`: `errors[]` first, then `result`, then a
    # non-`"success"` subtype, then the HTTP status.
    def self.from_result(message : ResultMessage, exit_code : Int32? = nil) : ResultError
      data = JSON.parse(message.to_json).as_h
      text = error_text_for(message)
      new("Claude Code returned an error result: #{text}", data, exit_code)
    end

    # Pick the most informative text from an error result. Terminal
    # errors the CLI raises itself (`error_max_turns`, ...) carry prose
    # in `errors[]`; a run ending on an API failure arrives as subtype
    # `"success"` with empty `errors[]` and the `"API Error: ..."` prose
    # in `result` — preferring `errors[]`, then `result`, avoids the
    # self-contradictory "...error result: success".
    def self.error_text_for(message : ResultMessage) : String
      errors = normalize_errors(message.errors || [] of JSON::Any)
      return errors.join("; ") unless errors.empty?

      if text = message.result
        stripped = text.strip
        return stripped unless stripped.empty?
      end
      if (subtype = message.subtype) != "success" && !subtype.empty?
        return subtype
      end
      if status = message.api_error_status
        return "API error (HTTP #{status})"
      end
      "unknown error"
    end

    # Normalize the `errors` field of a `result` frame to clean strings:
    # tolerate non-array payloads and drop non-string/blank entries so
    # `errors` and the exception text always agree. Mirrors Python's
    # `_normalize_result_errors` (0.2.140).
    def self.normalize_errors(raw : JSON::Any?) : Array(String)
      return [] of String if raw.nil?

      list = if array = raw.as_a?
               array
             else
               [raw] of JSON::Any
             end
      normalize_errors(list)
    end

    def self.normalize_errors(entries : Array(JSON::Any)) : Array(String)
      entries.compact_map(&.as_s?).map(&.strip).reject(&.empty?)
    end
  end

  # JSON parsing error
  class JSONDecodeError < Error
    getter raw_data : String

    def initialize(message : String, @raw_data : String)
      super(message)
    end
  end

  # Timeout error
  class TimeoutError < Error; end

  # Configuration error
  class ConfigurationError < Error; end

  # Raised when the Claude Code CLI rejects an option flag that the SDK
  # forwarded because the installed CLI version predates that flag.
  # Typically surfaced during `start` after `claude` exits with stderr like
  # `error: unknown option '--title'`. Upgrade the CLI or avoid setting the
  # corresponding `AgentOptions` field.
  class UnsupportedOptionError < Error
    getter option : String
    getter cli_path : String?

    def initialize(
      @option : String,
      message : String? = nil,
      @cli_path : String? = nil,
    )
      super(message || "Claude Code CLI does not recognize option '#{option}'. " \
                       "Upgrade the CLI or avoid setting this option in AgentOptions.")
    end
  end
end
