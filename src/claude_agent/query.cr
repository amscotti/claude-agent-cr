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

  # Simple query interface - yields messages as they arrive.
  #
  # When *options* needs the bidirectional control protocol (a
  # `can_use_tool` callback or in-process SDK MCP servers), the query
  # runs through `AgentClient` so permission requests and tool calls are
  # answered; otherwise it uses the lightweight one-shot `CLIClient`
  # path. Mirrors Python 0.2.140 (`can_use_tool` works with `query()`).
  #
  # The error `ResultMessage` (when the CLI reports `is_error: true`)
  # is still yielded to the block first; afterwards a `ResultError`
  # carrying the structured failure is raised (mirrors Python 0.2.140).
  # Rescue `ProcessError` to handle failures without distinguishing.
  def self.query(
    prompt : String,
    options : AgentOptions? = nil,
    &block : Message ->
  ) : ResultMessage
    if options.try(&.needs_control_protocol?)
      return query_via_agent(prompt, options, &block)
    end

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

      finish_query(result)
    ensure
      client.stop
    end
  end

  # One-shot query over `AgentClient`, for options that need the control
  # protocol. Yields every message (including the terminal result) to
  # the block, then returns the result or raises `ResultError`.
  private def self.query_via_agent(
    prompt : String,
    options : AgentOptions?,
    &block : Message ->
  ) : ResultMessage
    result : ResultMessage? = nil

    AgentClient.open(options) do |client|
      client.query(prompt)
      client.each_response do |message|
        block.call(message)
        result = message if message.is_a?(ResultMessage)
      end
    end

    finish_query(result)
  end

  # Settle a one-shot query: return the terminal result, raising
  # `ResultError` when the CLI reported `is_error: true` (the error
  # result itself was already yielded to the consumer first).
  def self.finish_query(result : ResultMessage?) : ResultMessage
    unless res = result
      raise Error.new("No result message received")
    end
    raise ResultError.from_result(res) if res.is_error == true
    res
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
    @agent_client : AgentClient?
    @channel : Channel(Message | Iterator::Stop | Exception)
    @started : Bool = false

    def initialize(@prompt : String, @options : AgentOptions?)
      @client = CLIClient.new(@options)
      @agent_client = nil
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
      @agent_client.try(&.stop)
      @channel.close unless @channel.closed?
    end

    private def start_if_needed
      return if @started
      @started = true

      if @options.try(&.needs_control_protocol?)
        start_agent_mode
      else
        start_cli_mode
      end
    end

    private def start_cli_mode
      spawn do
        @client.start
        @client.send_prompt(@prompt)

        @client.each_message do |message|
          forward(message)
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

    # Iterator mode over `AgentClient`, for options that need the control
    # protocol (`can_use_tool`, in-process SDK MCP servers). The reader
    # fiber bridges block-based `each_response` onto the pull channel.
    private def start_agent_mode
      agent = AgentClient.new(@options)
      @agent_client = agent

      spawn do
        agent.start
        agent.query(@prompt)

        agent.each_response do |message|
          forward(message)
        end
      rescue ex
        @channel.send(ex) unless @channel.closed?
      ensure
        @channel.send(Iterator::Stop.new) unless @channel.closed?
        agent.stop
      end
    end

    # Forward one message onto the pull channel. Mirrors the block form
    # (and Python's `query()`): an error result is delivered first, then
    # a `ResultError` so the failure cannot pass silently.
    private def forward(message : Message) : Nil
      @channel.send(message)
      if message.is_a?(ResultMessage) && message.is_error == true
        @channel.send(ResultError.from_result(message)) unless @channel.closed?
      end
    end
  end
end
