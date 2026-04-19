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
