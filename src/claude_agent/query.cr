require "./cli_client"

module ClaudeAgent
  # Pre-warm the Claude Code CLI subprocess without sending a prompt.
  # Returns an `AgentClient` that has already paid the startup cost, so the
  # next call to `#query` runs without subprocess boot latency.
  # The caller is responsible for `#stop`-ping the returned client.
  def self.startup(options : AgentOptions? = nil) : AgentClient
    client = AgentClient.new(options)
    client.start
    client
  end

  # Simple query interface - yields messages as they arrive
  def self.query(
    prompt : String,
    options : AgentOptions? = nil,
    &block : Message ->
  ) : ResultMessage
    client = CLIClient.new(options)

    begin
      client.start
      client.send_prompt(prompt)

      result : ResultMessage? = nil

      client.each_message do |message|
        block.call(message)
        if message.is_a?(ResultMessage)
          result = message
          break unless options.try(&.prompt_suggestions?)
        end
      end

      if res = result
        res
      else
        raise Error.new("No result message received")
      end
    ensure
      client.stop
    end
  end

  # Iterator-based query interface
  def self.query(
    prompt : String,
    options : AgentOptions? = nil,
  ) : QueryIterator
    QueryIterator.new(prompt, options)
  end

  class QueryIterator
    include Iterator(Message)

    @client : CLIClient
    @channel : Channel(Message | Iterator::Stop | Exception)
    @started : Bool = false

    def initialize(@prompt : String, @options : AgentOptions?)
      @client = CLIClient.new(@options)
      @channel = Channel(Message | Iterator::Stop | Exception).new
    end

    # Advance the iterator. Raises if the background fiber encountered
    # an error (e.g., CLI not found, subprocess crashed, unsupported
    # option); the previous implementation swallowed those silently and
    # produced an empty iterator with no diagnostic.
    def next : Message | Iterator::Stop
      start_if_needed

      case msg = @channel.receive
      when Message
        msg
      when Exception
        stop
        raise msg
      when Iterator::Stop
        stop
      else
        stop
      end
    end

    # Stop the iterator and underlying CLI process early
    def close
      @client.stop
      @channel.close unless @channel.closed?
    end

    private def start_if_needed
      return if @started
      @started = true

      spawn do
        begin
          @client.start
          @client.send_prompt(@prompt)

          @client.each_message do |message|
            @channel.send(message)
          end
        rescue ex
          # Forward the exception to the consumer instead of swallowing
          # it. Without this, a bad CLI path or a control-protocol
          # failure produced an empty iterator and no way to diagnose.
          @channel.send(ex) unless @channel.closed?
        ensure
          @channel.send(Iterator::Stop.new) unless @channel.closed?
          @client.stop
        end
      end
    end
  end
end
