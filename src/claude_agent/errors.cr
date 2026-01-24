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

  # JSON parsing error
  class JSONDecodeError < Error
    getter raw_data : String

    def initialize(message : String, @raw_data : String)
      super(message)
    end
  end

  # Permission denied
  class PermissionDeniedError < Error
    getter tool_name : String

    def initialize(@tool_name : String, message : String? = nil)
      super(message || "Permission denied for tool: #{tool_name}")
    end
  end

  # Timeout error
  class TimeoutError < Error; end

  # Configuration error
  class ConfigurationError < Error; end
end
