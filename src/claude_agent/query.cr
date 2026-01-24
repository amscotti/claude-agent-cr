require "./cli_client"

module ClaudeAgent
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
          break
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
    @channel : Channel(Message | Iterator::Stop)
    @started : Bool = false

    def initialize(@prompt : String, @options : AgentOptions?)
      @client = CLIClient.new(@options)
      @channel = Channel(Message | Iterator::Stop).new
    end

    def next : Message | Iterator::Stop
      start_if_needed

      case msg = @channel.receive
      when Message
        msg
      when Iterator::Stop
        stop
      else
        stop
      end
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
        rescue
          # Errors are silently handled - iteration will stop
        ensure
          @channel.send(Iterator::Stop.new)
          @client.stop
        end
      end
    end
  end
end
