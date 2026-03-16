require "./cli_client"
require "./types/messages"

module ClaudeAgent
  # V2-style streaming session that provides send/receive patterns
  # for bidirectional communication with the agent.
  #
  # Example:
  #   session = StreamingSession.new(options)
  #   session.start
  #
  #   # Send messages
  #   session.send("Hello, Claude!")
  #
  #   # Receive responses as they arrive
  #   session.each_message do |msg|
  #     puts msg if msg.is_a?(AssistantMessage)
  #   end
  #
  #   session.close
  #
  class StreamingSession
    @cli_client : CLIClient
    private record PendingUserMessage, content : String, uuid : String?

    @input_channel : Channel(PendingUserMessage)
    @output_channel : Channel(Message)
    @done_channel : Channel(Nil)
    @running : Bool = false
    @session_id : String?

    def initialize(@options : AgentOptions? = nil)
      @cli_client = CLIClient.new(@options)
      @input_channel = Channel(PendingUserMessage).new(10)
      @output_channel = Channel(Message).new(100)
      @done_channel = Channel(Nil).new(2)
    end

    def session_id : String?
      @session_id || @cli_client.session_id
    end

    def start
      return if @running

      @cli_client.start
      @running = true
      start_input_processor
      start_output_processor
    end

    def close
      return unless @running

      @running = false
      @input_channel.close
      @cli_client.stop
      @output_channel.close unless @output_channel.closed?

      # Wait for processor fibers to finish (with timeout)
      2.times do
        select
        when @done_channel.receive?
        when timeout(2.seconds)
        end
      end
    end

    # Send a message to the agent
    def send(content : String, *, uuid : String? = nil)
      raise Error.new("Session not started") unless @running
      @input_channel.send(PendingUserMessage.new(content, uuid))
    end

    # Receive the next message (blocking)
    def receive : Message?
      @output_channel.receive?
    end

    # Receive with timeout
    def receive(timeout : Time::Span) : Message?
      select
      when msg = @output_channel.receive?
        msg
      when timeout(timeout)
        nil
      end
    end

    # Iterate over all messages until session ends
    def each_message(&block : Message ->)
      while @running
        msg = @output_channel.receive?
        break unless msg

        block.call(msg)

        # Session ends on ResultMessage
        break if msg.is_a?(ResultMessage)
      end
    end

    # Check if session is active
    def running? : Bool
      @running
    end

    # Get output as an iterator (for use with each/map/etc)
    def messages : Iterator(Message)
      MessageIterator.new(@output_channel)
    end

    # Context manager pattern
    def self.open(options : AgentOptions? = nil, &)
      session = new(options)
      begin
        session.start
        yield session
      ensure
        session.close
      end
    end

    private def start_input_processor
      spawn do
        is_first = true
        while @running
          pending = @input_channel.receive?
          break unless pending

          if is_first
            @cli_client.send_prompt(pending.content, uuid: pending.uuid)
            is_first = false
          else
            @cli_client.send_user_message(pending.content, uuid: pending.uuid)
          end
        end
      rescue Channel::ClosedError
        # Expected when closing
      ensure
        @done_channel.send(nil) unless @done_channel.closed?
      end
    end

    private def start_output_processor
      spawn do
        @cli_client.each_message do |message|
          break unless @running

          # Capture session_id
          case message
          when SystemMessage
            @session_id = message.session_id
          when AssistantMessage
            @session_id ||= message.session_id
          end

          @output_channel.send(message) unless @output_channel.closed?
        end
      rescue Channel::ClosedError
        # Expected when closing
      ensure
        @output_channel.close unless @output_channel.closed?
        @done_channel.send(nil) unless @done_channel.closed?
      end
    end
  end

  # Iterator wrapper for messages
  private class MessageIterator
    include Iterator(Message)

    def initialize(@channel : Channel(Message))
    end

    def next : Message | Stop
      msg = @channel.receive?
      msg || stop
    end
  end
end
