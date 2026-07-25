require "json"
require "uuid"
require "file_utils"
require "./spec_helper"

private class FakeCLIClient < ClaudeAgent::CLIClient
  getter sent_messages : Array(Hash(String, JSON::Any))
  getter sent_control_responses : Array(Hash(String, JSON::Any))

  def initialize(
    @control_responses : Hash(String, Hash(String, JSON::Any)) = {} of String => Hash(String, JSON::Any),
    @control_errors : Hash(String, String) = {} of String => String,
  )
    super(nil)
    @sent_messages = [] of Hash(String, JSON::Any)
    @sent_control_responses = [] of Hash(String, JSON::Any)
    @messages = Channel(ClaudeAgent::Message).new(20)
  end

  def start
  end

  def stop
    @messages.close unless @messages.closed?
  end

  def send_prompt(
    prompt : String,
    parent_tool_use_id : String? = nil,
    *,
    uuid : String? = nil,
    should_query : Bool = true,
  )
    payload = {
      "type"               => JSON::Any.new("user"),
      "message"            => JSON::Any.new({"role" => JSON::Any.new("user"), "content" => JSON::Any.new(prompt)}),
      "parent_tool_use_id" => parent_tool_use_id ? JSON::Any.new(parent_tool_use_id) : JSON::Any.new(nil),
    }
    payload["uuid"] = JSON::Any.new(uuid) if uuid
    payload["shouldQuery"] = JSON::Any.new(false) unless should_query
    @sent_messages << payload
  end

  def send_user_message(
    content : String,
    parent_tool_use_id : String? = nil,
    *,
    uuid : String? = nil,
    should_query : Bool = true,
  )
    send_prompt(content, parent_tool_use_id, uuid: uuid, should_query: should_query)
  end

  def send_message(message : Hash)
    payload = JSON.parse(message.to_json).as_h
    @sent_messages << payload
    queue_control_response(payload)
  end

  def send_control_response(response : ClaudeAgent::ControlResponse)
    payload = JSON.parse({
      "type"     => JSON::Any.new(response.type),
      "response" => JSON::Any.new(response.response),
    }.to_json).as_h
    @sent_control_responses << payload
  end

  def send_json(message)
    payload = JSON.parse(message.to_json).as_h
    @sent_messages << payload
  end

  def push_message(message : ClaudeAgent::Message)
    @messages.send(message)
  end

  def close_messages
    @messages.close unless @messages.closed?
  end

  def each_message(&)
    loop do
      message = @messages.receive?
      break unless message
      yield message
    end
  end

  private def queue_control_response(payload : Hash(String, JSON::Any))
    return unless payload["type"]?.try(&.as_s?) == "control_request"

    request_id = payload["request_id"].as_s
    request = payload["request"].as_h
    subtype = request["subtype"].as_s

    response = {} of String => JSON::Any
    response["request_id"] = JSON::Any.new(request_id)

    if error = @control_errors[subtype]?
      response["subtype"] = JSON::Any.new("error")
      response["error"] = JSON::Any.new(error)
    else
      response["subtype"] = JSON::Any.new("success")
      if result = @control_responses[subtype]?
        response["response"] = JSON::Any.new(result)
      end
    end

    message = ClaudeAgent::ControlResponseMessage.from_json({
      "type"     => JSON::Any.new("control_response"),
      "response" => JSON::Any.new(response),
    }.to_json)

    @messages.send(message)
  end
end

class ClaudeAgent::AgentClient
  def test_handle_control_request(request : ClaudeAgent::ControlRequest)
    handle_control_request(request)
  end

  def test_handle_permission_request(request : ClaudeAgent::PermissionRequest)
    handle_permission_request(request)
  end

  def test_hook_common_fields(hook_event_name : String)
    hook_common_fields(hook_event_name)
  end

  def test_registered_hook_callback_count : Int32
    @registered_hook_callbacks.size
  end
end

describe ClaudeAgent::AgentClient do
  it "raises if dynamic controls are used before start" do
    client = ClaudeAgent::AgentClient.new(nil, FakeCLIClient.new)

    expect_raises(ClaudeAgent::ConnectionError, "Not connected. Call start() first.") do
      client.set_model("claude-sonnet-4-5")
    end
  end

  it "sends a control request for set_permission_mode" do
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    begin
      client.start
      client.set_permission_mode(ClaudeAgent::PermissionMode::AcceptEdits)

      request = fake_cli.sent_messages.last
      request["type"].as_s.should eq("control_request")
      request["request"].as_h["subtype"].as_s.should eq("set_permission_mode")
      request["request"].as_h["mode"].as_s.should eq("acceptEdits")
    ensure
      client.stop
    end
  end

  it "maps manual permission mode alias to default on the wire" do
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    begin
      client.start
      client.set_permission_mode("manual")

      request = fake_cli.sent_messages.last["request"].as_h
      request["subtype"].as_s.should eq("set_permission_mode")
      request["mode"].as_s.should eq("default")
    ensure
      client.stop
    end
  end

  it "rejects unrecognized permission mode strings" do
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    begin
      client.start
      expect_raises(ClaudeAgent::Error, /Unrecognized permission mode/) do
        client.set_permission_mode("not-a-real-mode")
      end
    ensure
      client.stop
    end
  end

  it "sends interrupt as a control request and returns still_queued receipt" do
    fake_cli = FakeCLIClient.new(
      control_responses: {
        "interrupt" => {
          "still_queued" => JSON::Any.new([
            JSON::Any.new("msg-a"),
            JSON::Any.new("msg-b"),
          ]),
        },
      },
    )
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    begin
      client.start
      receipt = client.interrupt

      request = fake_cli.sent_messages.last["request"].as_h
      request["subtype"].as_s.should eq("interrupt")
      request.has_key?("cancel_queued").should be_false
      receipt.still_queued.should eq(["msg-a", "msg-b"])
      receipt.cancelled.should eq([] of String)
    ensure
      client.stop
    end
  end

  it "includes cancel_queued on interrupt when requested" do
    fake_cli = FakeCLIClient.new(
      control_responses: {
        "interrupt" => {
          "still_queued" => JSON::Any.new([] of JSON::Any),
          "cancelled"    => JSON::Any.new([
            JSON::Any.new("msg-x"),
            JSON::Any.new("msg-y"),
          ]),
        },
      },
    )
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    begin
      client.start
      receipt = client.interrupt(cancel_queued: true)

      request = fake_cli.sent_messages.last["request"].as_h
      request["subtype"].as_s.should eq("interrupt")
      request["cancel_queued"].as_bool.should be_true
      receipt.still_queued.should eq([] of String)
      receipt.cancelled.should eq(["msg-x", "msg-y"])
    ensure
      client.stop
    end
  end

  it "parses cancelled_uuids alias on interrupt receipt" do
    fake_cli = FakeCLIClient.new(
      control_responses: {
        "interrupt" => {
          "still_queued"    => JSON::Any.new([] of JSON::Any),
          "cancelled_uuids" => JSON::Any.new([JSON::Any.new("c-1")]),
        },
      },
    )
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    begin
      client.start
      receipt = client.interrupt(cancel_queued: true)
      receipt.cancelled.should eq(["c-1"])
    ensure
      client.stop
    end
  end

  it "sends seed_read_state control requests for each entry" do
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    begin
      client.start
      client.seed_read_state([
        ClaudeAgent::ReadStateEntry.new("/tmp/a.txt", 1_700_000_000_000_i64),
        ClaudeAgent::ReadStateEntry.new("/tmp/b.txt", 1_700_000_000_100_i64),
      ])

      seed_requests = fake_cli.sent_messages.select do |message|
        message["request"]?.try(&.as_h?).try(&.["subtype"]?.try(&.as_s?)) == "seed_read_state"
      end
      seed_requests.size.should eq(2)
      first = seed_requests[0]["request"].as_h
      first["path"].as_s.should eq("/tmp/a.txt")
      first["mtime"].as_i64.should eq(1_700_000_000_000_i64)
      second = seed_requests[1]["request"].as_h
      second["path"].as_s.should eq("/tmp/b.txt")
      second["mtime"].as_i64.should eq(1_700_000_000_100_i64)
    ensure
      client.stop
    end
  end

  it "re-sends initialize on reinitialize" do
    fake_cli = FakeCLIClient.new(
      control_responses: {
        "initialize" => {
          "commands" => JSON::Any.new([
            JSON::Any.new({"name" => JSON::Any.new("review")}),
          ]),
        },
      },
    )
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    begin
      client.start
      initial_count = fake_cli.sent_messages.count do |message|
        message["request"]?.try(&.as_h?).try(&.["subtype"]?.try(&.as_s?)) == "initialize"
      end
      initial_count.should eq(1)

      response = client.reinitialize
      response["commands"].as_a.size.should eq(1)

      init_count = fake_cli.sent_messages.count do |message|
        message["request"]?.try(&.as_h?).try(&.["subtype"]?.try(&.as_s?)) == "initialize"
      end
      init_count.should eq(2)
      client.get_server_info.try(&.commands.first.name).should eq("review")
    ensure
      client.stop
    end
  end

  it "merges per-server request_timeout_ms into set_mcp_servers" do
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    begin
      client.start
      client.set_mcp_servers(
        {
          "filesystem" => JSON::Any.new({
            "type"    => JSON::Any.new("stdio"),
            "command" => JSON::Any.new("npx"),
          }),
          "remote" => JSON::Any.new({
            "type" => JSON::Any.new("http"),
            "url"  => JSON::Any.new("https://example.com/mcp"),
          }),
        },
        request_timeouts: {"filesystem" => 5_000},
      )

      request = fake_cli.sent_messages.last["request"].as_h
      request["subtype"].as_s.should eq("mcp_set_servers")
      servers = request["mcpServers"].as_h
      servers["filesystem"].as_h["request_timeout_ms"].as_i.should eq(5_000)
      servers["remote"].as_h.has_key?("request_timeout_ms").should be_false
    ensure
      client.stop
    end
  end

  it "keeps processing after result while background tasks are in flight" do
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)
    received_types = [] of String
    done = Channel(Nil).new(1)

    begin
      client.start

      spawn do
        client.each_response do |message|
          received_types << message.type
        end
        done.send(nil)
      end

      fake_cli.push_message(ClaudeAgent::TaskStartedMessage.new(
        session_id: "sess-1",
        data: {} of String => JSON::Any,
        uuid: "uuid-start",
        task_id: "task-1",
        description: "background agent",
        task_type: "local_agent",
      ))

      fake_cli.push_message(ClaudeAgent::ResultMessage.from_json({
        "type"            => JSON::Any.new("result"),
        "uuid"            => JSON::Any.new("result-1"),
        "session_id"      => JSON::Any.new("sess-1"),
        "subtype"         => JSON::Any.new("success"),
        "duration_ms"     => JSON::Any.new(100_i64),
        "duration_api_ms" => JSON::Any.new(80_i64),
        "is_error"        => JSON::Any.new(false),
        "num_turns"       => JSON::Any.new(1_i64),
        "stop_reason"     => JSON::Any.new("end_turn"),
      }.to_json))

      # Task still in flight after result — a follow-up system message should
      # still be delivered before the loop exits.
      fake_cli.push_message(ClaudeAgent::TaskNotificationMessage.new(
        session_id: "sess-1",
        data: {} of String => JSON::Any,
        uuid: "uuid-done",
        task_id: "task-1",
        status: "completed",
      ))

      fake_cli.close_messages
      done.receive
      received_types.should eq(["system", "result", "system"])
    ensure
      client.stop
    end
  end

  it "sends a control request for set_model" do
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    begin
      client.start
      client.set_model("claude-opus-4-7")

      request = fake_cli.sent_messages.last
      request["request"].as_h["subtype"].as_s.should eq("set_model")
      request["request"].as_h["model"].as_s.should eq("claude-opus-4-7")
    ensure
      client.stop
    end
  end

  it "returns cancellation status for cancel_async_message" do
    fake_cli = FakeCLIClient.new(
      control_responses: {
        "cancel_async_message" => {
          "cancelled" => JSON::Any.new(true),
        },
      },
    )
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    begin
      client.start
      client.cancel_async_message("msg-123").should be_true

      request = fake_cli.sent_messages.last["request"].as_h
      request["subtype"].as_s.should eq("cancel_async_message")
      request["message_uuid"].as_s.should eq("msg-123")
    ensure
      client.stop
    end
  end

  it "sends UUID with query when provided" do
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    begin
      client.start
      client.query("hello", uuid: "msg-1")

      user_messages = fake_cli.sent_messages.select { |message| message["type"]?.try(&.as_s?) == "user" }

      first = user_messages[0]
      first["message"].as_h["content"].as_s.should eq("hello")
      first["uuid"].as_s.should eq("msg-1")
    ensure
      client.stop
    end
  end

  it "marks user messages with should_query=false when requested" do
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    begin
      client.start
      client.send_user_message("context only", should_query: false)

      user_messages = fake_cli.sent_messages.select { |message| message["type"]?.try(&.as_s?) == "user" }
      user_messages[0]["shouldQuery"]?.try(&.as_bool).should be_false
    ensure
      client.stop
    end
  end

  it "sends UUID with follow-up user messages when provided" do
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    begin
      client.start
      client.send_user_message("follow up", uuid: "msg-2")

      user_messages = fake_cli.sent_messages.select { |message| message["type"]?.try(&.as_s?) == "user" }

      first = user_messages[0]
      first["message"].as_h["content"].as_s.should eq("follow up")
      first["uuid"].as_s.should eq("msg-2")
    ensure
      client.stop
    end
  end

  it "returns settings data from settings" do
    fake_cli = FakeCLIClient.new(
      control_responses: {
        "get_settings" => {
          "applied" => JSON::Any.new({
            "model"  => JSON::Any.new("claude-sonnet-4-5"),
            "effort" => JSON::Any.new("high"),
          }),
          "sources" => JSON::Any.new({
            "user" => JSON::Any.new({} of String => JSON::Any),
          }),
        },
      },
    )
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    begin
      client.start
      settings = client.settings
      settings["applied"].as_h["model"].as_s.should eq("claude-sonnet-4-5")
      settings["applied"].as_h["effort"].as_s.should eq("high")
      settings["sources"].as_h["user"].as_h.should eq({} of String => JSON::Any)
    ensure
      client.stop
    end
  end

  it "returns decline by default for elicitation requests" do
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    request = ClaudeAgent::ControlRequest.from_json({
      "type"       => JSON::Any.new("control_request"),
      "request_id" => JSON::Any.new("elicitation-1"),
      "request"    => JSON::Any.new({
        "subtype"         => JSON::Any.new("elicitation"),
        "mcp_server_name" => JSON::Any.new("auth-server"),
        "message"         => JSON::Any.new("Authenticate"),
        "mode"            => JSON::Any.new("url"),
        "url"             => JSON::Any.new("https://example.com/auth"),
        "elicitation_id"  => JSON::Any.new("oauth-1"),
      }),
    }.to_json)

    client.test_handle_control_request(request)

    response = fake_cli.sent_control_responses.last["response"].as_h["response"].as_h
    response["action"].as_s.should eq("decline")
  end

  it "uses on_elicitation callback for elicitation requests" do
    options = ClaudeAgent::AgentOptions.new(
      on_elicitation: ->(request : ClaudeAgent::ElicitationRequest) {
        request.server_name.should eq("auth-server")
        request.mode.should eq("form")
        ClaudeAgent::ElicitationResponse.accept({
          "code" => JSON::Any.new("123456"),
        })
      },
    )
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(options, fake_cli)

    request = ClaudeAgent::ControlRequest.from_json({
      "type"       => JSON::Any.new("control_request"),
      "request_id" => JSON::Any.new("elicitation-2"),
      "request"    => JSON::Any.new({
        "subtype"          => JSON::Any.new("elicitation"),
        "mcp_server_name"  => JSON::Any.new("auth-server"),
        "message"          => JSON::Any.new("Enter auth code"),
        "mode"             => JSON::Any.new("form"),
        "requested_schema" => JSON::Any.new({
          "type" => JSON::Any.new("object"),
        }),
      }),
    }.to_json)

    client.test_handle_control_request(request)

    response = fake_cli.sent_control_responses.last["response"].as_h["response"].as_h
    response["action"].as_s.should eq("accept")
    response["content"].as_h["code"].as_s.should eq("123456")
  end

  it "returns typed MCP status results" do
    fake_cli = FakeCLIClient.new(
      control_responses: {
        "mcp_status" => {
          "mcpServers" => JSON::Any.new([
            JSON::Any.new({
              "name"       => JSON::Any.new("filesystem"),
              "status"     => JSON::Any.new("connected"),
              "serverInfo" => JSON::Any.new({
                "name"    => JSON::Any.new("filesystem"),
                "version" => JSON::Any.new("1.0.0"),
              }),
              "tools" => JSON::Any.new([
                JSON::Any.new({
                  "name"        => JSON::Any.new("read_file"),
                  "description" => JSON::Any.new("Read a file"),
                }),
              ]),
            }),
          ]),
        },
      },
    )
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    begin
      client.start
      status = client.get_mcp_status

      status.mcp_servers.size.should eq(1)
      status.mcp_servers.first.name.should eq("filesystem")
      status.mcp_servers.first.status.should eq("connected")
      status.mcp_servers.first.server_info.try(&.version).should eq("1.0.0")
      status.mcp_servers.first.tools.try(&.first.name).should eq("read_file")
    ensure
      client.stop
    end
  end

  it "sends MCP reconnect, toggle, and stop_task control requests" do
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    begin
      client.start
      client.reconnect_mcp_server("filesystem")
      client.toggle_mcp_server("filesystem", enabled: false)
      client.stop_task("task-123")

      reconnect = fake_cli.sent_messages[-3]
      reconnect["request"].as_h["subtype"].as_s.should eq("mcp_reconnect")
      reconnect["request"].as_h["serverName"].as_s.should eq("filesystem")

      toggle = fake_cli.sent_messages[-2]
      toggle["request"].as_h["subtype"].as_s.should eq("mcp_toggle")
      toggle["request"].as_h["serverName"].as_s.should eq("filesystem")
      toggle["request"].as_h["enabled"].as_bool.should be_false

      stop_task = fake_cli.sent_messages[-1]
      stop_task["request"].as_h["subtype"].as_s.should eq("stop_task")
      stop_task["request"].as_h["task_id"].as_s.should eq("task-123")
    ensure
      client.stop
    end
  end

  it "sends a rewind_conversation control request" do
    fake_cli = FakeCLIClient.new(
      control_responses: {"rewind_conversation" => {"session_id" => JSON::Any.new("sess-rewound")}},
    )
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    begin
      client.start
      result = client.rewind_conversation("msg-uuid-1", dry_run: true)

      sent = fake_cli.sent_messages[-1]
      req = sent["request"].as_h
      req["subtype"].as_s.should eq("rewind_conversation")
      req["user_message_id"].as_s.should eq("msg-uuid-1")
      req["dry_run"].as_bool.should be_true
      result["session_id"].as_s.should eq("sess-rewound")
    ensure
      client.stop
    end
  end

  it "returns a typed ContextUsageResponse from get_context_usage" do
    fake_cli = FakeCLIClient.new(
      control_responses: {
        "get_context_usage" => {
          "categories" => JSON::Any.new([
            JSON::Any.new({
              "name"   => JSON::Any.new("System"),
              "tokens" => JSON::Any.new(1200_i64),
              "color"  => JSON::Any.new("#ff00ff"),
            }),
          ]),
          "totalTokens"          => JSON::Any.new(1200_i64),
          "maxTokens"            => JSON::Any.new(200_000_i64),
          "rawMaxTokens"         => JSON::Any.new(200_000_i64),
          "percentage"           => JSON::Any.new(0.6),
          "model"                => JSON::Any.new("claude-sonnet-4-5"),
          "isAutoCompactEnabled" => JSON::Any.new(true),
          "memoryFiles"          => JSON::Any.new([] of JSON::Any),
          "mcpTools"             => JSON::Any.new([] of JSON::Any),
          "agents"               => JSON::Any.new([] of JSON::Any),
        },
      },
    )
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    begin
      client.start
      usage = client.get_context_usage

      usage.total_tokens.should eq(1200)
      usage.max_tokens.should eq(200_000)
      usage.model.should eq("claude-sonnet-4-5")
      usage.auto_compact_enabled?.should be_true
      usage.categories.size.should eq(1)
      usage.categories.first.name.should eq("System")
    ensure
      client.stop
    end
  end

  it "sends reload_plugins, prompt_suggestion, and mcp_enable_channel control requests" do
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    begin
      client.start
      client.reload_plugins
      client.prompt_suggestion
      client.enable_mcp_channel("remote")

      subtypes = fake_cli.sent_messages.last(3).map(&.["request"].as_h["subtype"].as_s)
      subtypes.should eq(["reload_plugins", "prompt_suggestion", "mcp_enable_channel"])
      fake_cli.sent_messages.last["request"].as_h["serverName"].as_s.should eq("remote")
    ensure
      client.stop
    end
  end

  it "sends apply_flag_settings control request" do
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    begin
      client.start
      client.apply_flag_settings({
        "verbose" => JSON::Any.new(true),
        "model"   => JSON::Any.new("claude-sonnet-4-5"),
      })

      request = fake_cli.sent_messages.last["request"].as_h
      request["subtype"].as_s.should eq("apply_flag_settings")
      request["settings"].as_h["verbose"].as_bool.should be_true
      request["settings"].as_h["model"].as_s.should eq("claude-sonnet-4-5")
    ensure
      client.stop
    end
  end

  it "sends enable_remote_control control request" do
    fake_cli = FakeCLIClient.new(
      control_responses: {
        "remote_control" => {
          "status" => JSON::Any.new("enabled"),
        },
      },
    )
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    begin
      client.start
      response = client.enable_remote_control(true)

      request = fake_cli.sent_messages.last["request"].as_h
      request["subtype"].as_s.should eq("remote_control")
      request["enabled"].as_bool.should be_true
      response["status"].as_s.should eq("enabled")
    ensure
      client.stop
    end
  end

  it "sends set_proactive control request" do
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    begin
      client.start
      client.set_proactive(true)

      request = fake_cli.sent_messages.last["request"].as_h
      request["subtype"].as_s.should eq("set_proactive")
      request["enabled"].as_bool.should be_true
    ensure
      client.stop
    end
  end

  it "sends generate_session_title and returns the title" do
    fake_cli = FakeCLIClient.new(
      control_responses: {
        "generate_session_title" => {
          "title" => JSON::Any.new("Refactoring the auth module"),
        },
      },
    )
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    begin
      client.start
      title = client.generate_session_title("We refactored auth", persist: true)

      title.should eq("Refactoring the auth module")

      request = fake_cli.sent_messages.last["request"].as_h
      request["subtype"].as_s.should eq("generate_session_title")
      request["description"].as_s.should eq("We refactored auth")
      request["persist"].as_bool.should be_true
    ensure
      client.stop
    end
  end

  it "returns nil title when CLI does not include one" do
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    begin
      client.start
      title = client.generate_session_title("short session")
      title.should be_nil
    ensure
      client.stop
    end
  end

  it "stores and returns initialization server info" do
    fake_cli = FakeCLIClient.new(
      control_responses: {
        "initialize" => {
          "commands" => JSON::Any.new([
            JSON::Any.new({
              "name"        => JSON::Any.new("review"),
              "description" => JSON::Any.new("Review code"),
            }),
          ]),
          "agents" => JSON::Any.new([
            JSON::Any.new({
              "name"        => JSON::Any.new("reviewer"),
              "description" => JSON::Any.new("Reviews code"),
            }),
          ]),
          "output_style"            => JSON::Any.new("default"),
          "available_output_styles" => JSON::Any.new([
            JSON::Any.new("default"),
            JSON::Any.new("compact"),
          ]),
          "models" => JSON::Any.new([
            JSON::Any.new({
              "value"       => JSON::Any.new("default"),
              "displayName" => JSON::Any.new("Default"),
            }),
          ]),
          "account" => JSON::Any.new({
            "email" => JSON::Any.new("user@example.com"),
          }),
        },
      },
    )
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    begin
      client.start
      info = client.get_server_info

      info.should_not be_nil
      actual_info = info.as(ClaudeAgent::ServerInfo)
      actual_info.output_style.should eq("default")
      actual_info.commands.size.should eq(1)
      actual_info.commands.first.description.should eq("Review code")
      actual_info.available_output_styles[1].should eq("compact")
      actual_info.agents.first.name.should eq("reviewer")
      actual_info.models.first.display_name.should eq("Default")
      actual_info.account.try(&.email).should eq("user@example.com")
    ensure
      client.stop
    end
  end

  it "sends initialize even without hooks or SDK MCP servers" do
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    begin
      client.start

      initialize_request = fake_cli.sent_messages.first
      initialize_request["type"].as_s.should eq("control_request")
      initialize_request["request"].as_h["subtype"].as_s.should eq("initialize")
    ensure
      client.stop
    end
  end

  it "raises for get_server_info before start" do
    client = ClaudeAgent::AgentClient.new(nil, FakeCLIClient.new)

    expect_raises(ClaudeAgent::ConnectionError, "Not connected. Call start() first.") do
      client.get_server_info
    end
  end

  it "raises for supported_agents before start" do
    client = ClaudeAgent::AgentClient.new(nil, FakeCLIClient.new)

    expect_raises(ClaudeAgent::ConnectionError, "Not connected. Call start() first.") do
      client.supported_agents
    end
  end

  it "returns supported agents and commands from server info" do
    fake_cli = FakeCLIClient.new(
      control_responses: {
        "initialize" => {
          "commands" => JSON::Any.new([
            JSON::Any.new({"name" => JSON::Any.new("review")}),
            JSON::Any.new({"name" => JSON::Any.new("commit")}),
          ]),
          "agents" => JSON::Any.new([
            JSON::Any.new({"name" => JSON::Any.new("reviewer"), "description" => JSON::Any.new("Reviews code")}),
            JSON::Any.new({"name" => JSON::Any.new("planner")}),
          ]),
        },
      },
    )
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    begin
      client.start

      client.supported_agents.map(&.name).should eq(["reviewer", "planner"])
      client.supported_commands.map(&.name).should eq(["review", "commit"])
    ensure
      client.stop
    end
  end

  it "normalizes local hook permission_mode values to CLI format" do
    options = ClaudeAgent::AgentOptions.new(permission_mode: ClaudeAgent::PermissionMode::AcceptEdits)
    client = ClaudeAgent::AgentClient.new(options, FakeCLIClient.new)

    fields = client.test_hook_common_fields("PreToolUse")
    fields[:permission_mode].should eq("acceptEdits")
  end

  it "raises when the CLI reports a control error" do
    fake_cli = FakeCLIClient.new(control_errors: {"set_model" => "model switch failed"})
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    begin
      client.start

      expect_raises(ClaudeAgent::Error, "model switch failed") do
        client.set_model("claude-sonnet-4-5")
      end
    ensure
      client.stop
    end
  end

  it "registers hooks in initialize control request" do
    pre_tool_use = ->(_input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
      ClaudeAgent::HookResult.allow
    }
    notification = ->(_input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
      ClaudeAgent::HookResult.allow
    }

    options = ClaudeAgent::AgentOptions.new(
      hooks: ClaudeAgent::HookConfig.new(
        pre_tool_use: [ClaudeAgent::HookMatcher.new(matcher: "Bash", hooks: [pre_tool_use])],
        notification: [notification],
      ),
    )
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(options, fake_cli)

    begin
      client.start

      request = fake_cli.sent_messages.first
      request["request"].as_h["subtype"].as_s.should eq("initialize")

      hooks = request["request"].as_h["hooks"].as_h
      hooks["PreToolUse"].as_a.size.should eq(1)
      hooks["Notification"].as_a.size.should eq(1)

      pre_tool = hooks["PreToolUse"].as_a.first.as_h
      pre_tool["matcher"].as_s.should eq("Bash")
      pre_tool["hookCallbackIds"].as_a.size.should eq(1)

      notification_payload = hooks["Notification"].as_a.first.as_h
      notification_payload["hookCallbackIds"].as_a.size.should eq(1)
    ensure
      client.stop
    end
  end

  it "includes matcher timeout and agents in initialize control request" do
    pre_tool_use = ->(_input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
      ClaudeAgent::HookResult.allow
    }

    options = ClaudeAgent::AgentOptions.new(
      agents: {
        "reviewer" => ClaudeAgent::AgentDefinition.new(
          name: "reviewer",
          description: "Reviews code",
          prompt: "Review the code carefully",
          tools: ["Read"],
          model: "claude-sonnet-4-5",
        ),
      },
      hooks: ClaudeAgent::HookConfig.new(
        pre_tool_use: [ClaudeAgent::HookMatcher.new(matcher: "Bash", hooks: [pre_tool_use], timeout: 15.0)],
      ),
    )
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(options, fake_cli)

    begin
      client.start

      request = fake_cli.sent_messages.first["request"].as_h
      pre_tool = request["hooks"].as_h["PreToolUse"].as_a.first.as_h
      pre_tool["timeout"].as_f.should eq(15.0)

      agents = request["agents"].as_h
      agents["reviewer"].as_h["description"].as_s.should eq("Reviews code")
      agents["reviewer"].as_h["model"].as_s.should eq("claude-sonnet-4-5")
    ensure
      client.stop
    end
  end

  it "registers elicitation hooks in initialize control request" do
    callback = ->(_input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
      ClaudeAgent::HookResult.elicitation("decline")
    }

    options = ClaudeAgent::AgentOptions.new(
      hooks: ClaudeAgent::HookConfig.new(
        elicitation: [callback],
        elicitation_result: [callback],
      ),
    )
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(options, fake_cli)

    begin
      client.start

      request = fake_cli.sent_messages.first["request"].as_h
      hooks = request["hooks"].as_h
      hooks["Elicitation"].as_a.first.as_h["hookCallbackIds"].as_a.size.should eq(1)
      hooks["ElicitationResult"].as_a.first.as_h["hookCallbackIds"].as_a.size.should eq(1)
    ensure
      client.stop
    end
  end

  it "registers MessageDisplay and DirectoryAdded hooks in initialize" do
    callback = ->(_input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
      ClaudeAgent::HookResult.new
    }

    options = ClaudeAgent::AgentOptions.new(
      hooks: ClaudeAgent::HookConfig.new(
        message_display: [callback],
        directory_added: [callback],
      ),
    )
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(options, fake_cli)

    begin
      client.start

      request = fake_cli.sent_messages.first["request"].as_h
      hooks = request["hooks"].as_h
      hooks["MessageDisplay"].as_a.first.as_h["hookCallbackIds"].as_a.size.should eq(1)
      hooks["DirectoryAdded"].as_a.first.as_h["hookCallbackIds"].as_a.size.should eq(1)
    ensure
      client.stop
    end
  end

  it "returns hook callback action and content for elicitation hooks" do
    callback = ->(input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
      input.mcp_server_name.should eq("auth-server")
      input.elicitation_mode.should eq("form")
      ClaudeAgent::HookResult.elicitation("accept", {"token" => JSON::Any.new("abc")})
    }

    options = ClaudeAgent::AgentOptions.new(
      hooks: ClaudeAgent::HookConfig.new(
        elicitation: [callback],
      ),
    )
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(options, fake_cli)

    begin
      client.start
      initialize_request = fake_cli.sent_messages.first
      callback_id = initialize_request["request"].as_h["hooks"].as_h["Elicitation"].as_a.first.as_h["hookCallbackIds"].as_a.first.as_s

      request = ClaudeAgent::ControlRequest.from_json({
        "type"       => JSON::Any.new("control_request"),
        "request_id" => JSON::Any.new("hook-elicitation-1"),
        "request"    => JSON::Any.new({
          "subtype"     => JSON::Any.new("hook_callback"),
          "callback_id" => JSON::Any.new(callback_id),
          "input"       => JSON::Any.new({
            "hook_event_name" => JSON::Any.new("Elicitation"),
            "session_id"      => JSON::Any.new("sess-1"),
            "mcp_server_name" => JSON::Any.new("auth-server"),
            "message"         => JSON::Any.new("Authenticate"),
            "mode"            => JSON::Any.new("form"),
          }),
        }),
      }.to_json)

      client.test_handle_control_request(request)

      response = fake_cli.sent_control_responses.last["response"].as_h["response"].as_h
      hook_output = response["hookSpecificOutput"].as_h
      hook_output["hookEventName"].as_s.should eq("Elicitation")
      hook_output["action"].as_s.should eq("accept")
      hook_output["content"].as_h["token"].as_s.should eq("abc")
    ensure
      client.stop
    end
  end

  it "includes promptSuggestions and agentProgressSummaries in initialize request" do
    options = ClaudeAgent::AgentOptions.new(
      prompt_suggestions: true,
      agent_progress_summaries: true,
    )
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(options, fake_cli)

    begin
      client.start

      request = fake_cli.sent_messages.first["request"].as_h
      request["promptSuggestions"].as_bool.should be_true
      request["agentProgressSummaries"].as_bool.should be_true
    ensure
      client.stop
    end
  end

  it "forwards forwardSubagentText via initialize (not managedSettings or plugins)" do
    inner = {} of String => JSON::Any
    inner["allow"] = JSON::Any.new([JSON::Any.new("Bash")] of JSON::Any)
    managed = {"permissions" => JSON::Any.new(inner)} of String => JSON::Any
    options = ClaudeAgent::AgentOptions.new(
      forward_subagent_text: true,
      managed_settings: managed,
      plugins: [ClaudeAgent::PluginConfig.new("/p", skip_mcp_discovery: true)],
    )
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(options, fake_cli)

    begin
      client.start

      request = fake_cli.sent_messages.first["request"].as_h
      request["forwardSubagentText"].as_bool.should be_true

      # managed_settings and plugins travel on argv (--managed-settings /
      # --plugin-dir-no-mcp), never in the initialize request.
      request.has_key?("managedSettings").should be_false
      request.has_key?("plugins").should be_false
    ensure
      client.stop
    end
  end

  it "returns empty arrays when supported_commands and supported_agents are unavailable" do
    fake_cli = FakeCLIClient.new(control_responses: {"initialize" => {} of String => JSON::Any})
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    begin
      client.start
      client.supported_commands.should eq([] of ClaudeAgent::ServerCommand)
      client.supported_agents.should eq([] of ClaudeAgent::ServerAgentInfo)
    ensure
      client.stop
    end
  end

  it "delivers prompt suggestions after result when enabled" do
    options = ClaudeAgent::AgentOptions.new(prompt_suggestions: true)
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(options, fake_cli)
    received_types = [] of String
    done = Channel(Nil).new(1)

    begin
      client.start

      spawn do
        client.each_response do |message|
          received_types << message.type
        end
        done.send(nil)
      end

      fake_cli.push_message(ClaudeAgent::ResultMessage.from_json({
        "type"            => JSON::Any.new("result"),
        "uuid"            => JSON::Any.new("result-1"),
        "session_id"      => JSON::Any.new("sess-1"),
        "subtype"         => JSON::Any.new("success"),
        "duration_ms"     => JSON::Any.new(100_i64),
        "duration_api_ms" => JSON::Any.new(80_i64),
        "is_error"        => JSON::Any.new(false),
        "num_turns"       => JSON::Any.new(1_i64),
        "stop_reason"     => JSON::Any.new("end_turn"),
      }.to_json))

      fake_cli.push_message(ClaudeAgent::PromptSuggestionMessage.from_json({
        "type"       => JSON::Any.new("prompt_suggestion"),
        "uuid"       => JSON::Any.new("suggest-1"),
        "session_id" => JSON::Any.new("sess-1"),
        "suggestion" => JSON::Any.new("Ask for a summary next"),
      }.to_json))

      done.receive
      received_types.should eq(["result", "prompt_suggestion"])
    ensure
      client.stop
    end
  end

  it "returns updatedInput and updatedPermissions for permission callbacks" do
    update = ClaudeAgent::AddRulesUpdate.new(
      rules: [ClaudeAgent::PermissionRuleValue.tool("Bash(ls:*)")],
      behavior: ClaudeAgent::PermissionRuleBehavior::Allow,
      destination: ClaudeAgent::PermissionUpdateDestination::Session,
    )
    options = ClaudeAgent::AgentOptions.new(
      can_use_tool: ->(_context : ClaudeAgent::PermissionContext) {
        ClaudeAgent::PermissionResult.allow(
          updated_input: {
            "command" => JSON::Any.new("pwd"),
          },
          updated_permissions: [update.as(ClaudeAgent::PermissionUpdate)],
        )
      },
    )
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(options, fake_cli)

    request = ClaudeAgent::ControlRequest.from_json({
      "type"       => JSON::Any.new("control_request"),
      "request_id" => JSON::Any.new("perm-1"),
      "request"    => JSON::Any.new({
        "subtype"   => JSON::Any.new("can_use_tool"),
        "tool_name" => JSON::Any.new("Bash"),
        "input"     => JSON::Any.new({
          "command" => JSON::Any.new("ls -la"),
        }),
        "permission_suggestions" => JSON::Any.new([] of JSON::Any),
      }),
    }.to_json)

    client.test_handle_control_request(request)

    response = fake_cli.sent_control_responses.last["response"].as_h["response"].as_h
    response["behavior"].as_s.should eq("allow")
    response["updatedInput"].as_h["command"].as_s.should eq("pwd")
    response["updatedPermissions"].as_a.size.should eq(1)
    update_payload = response["updatedPermissions"].as_a.first.as_h
    update_payload["type"].as_s.should eq("addRules")
    update_payload["behavior"].as_s.should eq("allow")
    update_payload["destination"].as_s.should eq("session")
  end

  it "wires request_id into PermissionContext and suppresses automatic control_response" do
    seen_request_id = nil.as(String?)
    options = ClaudeAgent::AgentOptions.new(
      can_use_tool: ->(context : ClaudeAgent::PermissionContext) {
        seen_request_id = context.request_id
        ClaudeAgent::PermissionResult.suppress
      },
    )
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(options, fake_cli)

    request = ClaudeAgent::ControlRequest.from_json({
      "type"       => JSON::Any.new("control_request"),
      "request_id" => JSON::Any.new("perm-oob-9"),
      "request"    => JSON::Any.new({
        "subtype"   => JSON::Any.new("can_use_tool"),
        "tool_name" => JSON::Any.new("Bash"),
        "input"     => JSON::Any.new({
          "command" => JSON::Any.new("echo hi"),
        }),
      }),
    }.to_json)

    before = fake_cli.sent_control_responses.size
    client.test_handle_control_request(request)

    seen_request_id.should eq("perm-oob-9")
    fake_cli.sent_control_responses.size.should eq(before)
  end

  it "respond_to_permission sends OOB allow control_response using stashed input" do
    options = ClaudeAgent::AgentOptions.new(
      can_use_tool: ->(_context : ClaudeAgent::PermissionContext) {
        ClaudeAgent::PermissionResult.suppress
      },
    )
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(options, fake_cli)

    begin
      client.start

      request = ClaudeAgent::ControlRequest.from_json({
        "type"       => JSON::Any.new("control_request"),
        "request_id" => JSON::Any.new("perm-oob-42"),
        "request"    => JSON::Any.new({
          "subtype"   => JSON::Any.new("can_use_tool"),
          "tool_name" => JSON::Any.new("Bash"),
          "input"     => JSON::Any.new({
            "command" => JSON::Any.new("ls -la"),
          }),
        }),
      }.to_json)

      client.test_handle_control_request(request)
      before = fake_cli.sent_control_responses.size

      client.respond_to_permission(
        "perm-oob-42",
        ClaudeAgent::PermissionResult.allow,
      )

      fake_cli.sent_control_responses.size.should eq(before + 1)
      outer = fake_cli.sent_control_responses.last["response"].as_h
      outer["subtype"].as_s.should eq("success")
      outer["request_id"].as_s.should eq("perm-oob-42")
      payload = outer["response"].as_h
      payload["behavior"].as_s.should eq("allow")
      payload["updatedInput"].as_h["command"].as_s.should eq("ls -la")
    ensure
      client.stop
    end
  end

  it "respond_to_permission sends OOB deny with message and interrupt" do
    options = ClaudeAgent::AgentOptions.new(
      can_use_tool: ->(_context : ClaudeAgent::PermissionContext) {
        ClaudeAgent::PermissionResult.suppress
      },
    )
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(options, fake_cli)

    begin
      client.start

      request = ClaudeAgent::ControlRequest.from_json({
        "type"       => JSON::Any.new("control_request"),
        "request_id" => JSON::Any.new("perm-oob-deny"),
        "request"    => JSON::Any.new({
          "subtype"   => JSON::Any.new("can_use_tool"),
          "tool_name" => JSON::Any.new("Bash"),
          "input"     => JSON::Any.new({
            "command" => JSON::Any.new("rm -rf /"),
          }),
        }),
      }.to_json)

      client.test_handle_control_request(request)
      client.respond_to_permission(
        "perm-oob-deny",
        ClaudeAgent::PermissionResult.deny(reason: "nope", interrupt: true),
      )

      payload = fake_cli.sent_control_responses.last["response"].as_h["response"].as_h
      payload["behavior"].as_s.should eq("deny")
      payload["message"].as_s.should eq("nope")
      payload["interrupt"].as_bool.should be_true
    ensure
      client.stop
    end
  end

  it "legacy PermissionRequest suppress is a no-op (does not grant or deny)" do
    options = ClaudeAgent::AgentOptions.new(
      can_use_tool: ->(_context : ClaudeAgent::PermissionContext) {
        ClaudeAgent::PermissionResult.suppress
      },
    )
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(options, fake_cli)

    request = ClaudeAgent::PermissionRequest.from_json({
      "type"        => JSON::Any.new("permission_request"),
      "tool_use_id" => JSON::Any.new("tool-legacy-1"),
      "tool_name"   => JSON::Any.new("Bash"),
      "tool_input"  => JSON::Any.new({
        "command" => JSON::Any.new("echo hi"),
      }),
    }.to_json)

    before_messages = fake_cli.sent_messages.size
    before_control = fake_cli.sent_control_responses.size
    client.test_handle_permission_request(request)

    fake_cli.sent_messages.size.should eq(before_messages)
    fake_cli.sent_control_responses.size.should eq(before_control)
  end

  it "reinitialize rebuilds hook callback registry under lock" do
    pre_tool_use = ->(_input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
      ClaudeAgent::HookResult.new
    }
    options = ClaudeAgent::AgentOptions.new(
      hooks: ClaudeAgent::HookConfig.new(
        pre_tool_use: [ClaudeAgent::HookMatcher.new(matcher: "Bash", hooks: [pre_tool_use])],
      ),
    )
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(options, fake_cli)

    begin
      client.start
      client.test_registered_hook_callback_count.should eq(1)

      client.reinitialize
      client.test_registered_hook_callback_count.should eq(1)

      # Hook callback after reinitialize still resolves via the rebuilt registry.
      initialize_request = fake_cli.sent_messages.reverse.find do |message|
        message["request"]?.try(&.as_h?).try(&.["subtype"]?.try(&.as_s?)) == "initialize"
      end
      initialize_request.should_not be_nil
      callback_id = initialize_request.try do |msg|
        msg["request"].as_h["hooks"].as_h["PreToolUse"].as_a.first.as_h["hookCallbackIds"].as_a.first.as_s
      end
      callback_id.should_not be_nil
      callback_id = callback_id.as(String)

      request = ClaudeAgent::ControlRequest.from_json({
        "type"       => JSON::Any.new("control_request"),
        "request_id" => JSON::Any.new("hook-after-reinit"),
        "request"    => JSON::Any.new({
          "subtype"     => JSON::Any.new("hook_callback"),
          "callback_id" => JSON::Any.new(callback_id),
          "tool_use_id" => JSON::Any.new("tool-1"),
          "input"       => JSON::Any.new({
            "hook_event_name" => JSON::Any.new("PreToolUse"),
            "session_id"      => JSON::Any.new("sess-1"),
            "tool_name"       => JSON::Any.new("Bash"),
          }),
        }),
      }.to_json)

      client.test_handle_control_request(request)
      response = fake_cli.sent_control_responses.last["response"].as_h
      response["subtype"].as_s.should eq("success")
      response["request_id"].as_s.should eq("hook-after-reinit")
    ensure
      client.stop
    end
  end

  it "returns deny message and interrupt for denied permission callbacks" do
    options = ClaudeAgent::AgentOptions.new(
      can_use_tool: ->(_context : ClaudeAgent::PermissionContext) {
        ClaudeAgent::PermissionResult.deny(reason: "blocked", interrupt: true)
      },
    )
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(options, fake_cli)

    request = ClaudeAgent::ControlRequest.from_json({
      "type"       => JSON::Any.new("control_request"),
      "request_id" => JSON::Any.new("perm-2"),
      "request"    => JSON::Any.new({
        "subtype"   => JSON::Any.new("can_use_tool"),
        "tool_name" => JSON::Any.new("Bash"),
        "input"     => JSON::Any.new({
          "command" => JSON::Any.new("rm -rf /"),
        }),
      }),
    }.to_json)

    client.test_handle_control_request(request)

    response = fake_cli.sent_control_responses.last["response"].as_h["response"].as_h
    response["behavior"].as_s.should eq("deny")
    response["message"].as_s.should eq("blocked")
    response["interrupt"].as_bool.should be_true
  end

  it "returns hook callback results with CLI field names" do
    pre_tool_use = ->(_input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
      ClaudeAgent::HookResult.new(
        continue: true,
        suppress_output: false,
        decision: "block",
        system_message: "System warning",
        reason: "Denied",
        hook_specific_output: ClaudeAgent::HookSpecificOutput.new(
          hook_event_name: "PreToolUse",
          permission_decision: "deny",
          permission_decision_reason: "Nope",
          updated_input: {"command" => JSON::Any.new("pwd")},
          additional_context: "Extra context",
        ),
      )
    }

    options = ClaudeAgent::AgentOptions.new(
      hooks: ClaudeAgent::HookConfig.new(
        pre_tool_use: [ClaudeAgent::HookMatcher.new(matcher: "Bash", hooks: [pre_tool_use])],
      ),
    )
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(options, fake_cli)

    begin
      client.start
      initialize_request = fake_cli.sent_messages.first
      callback_id = initialize_request["request"].as_h["hooks"].as_h["PreToolUse"].as_a.first.as_h["hookCallbackIds"].as_a.first.as_s

      request = ClaudeAgent::ControlRequest.from_json({
        "type"       => JSON::Any.new("control_request"),
        "request_id" => JSON::Any.new("hook-1"),
        "request"    => JSON::Any.new({
          "subtype"     => JSON::Any.new("hook_callback"),
          "callback_id" => JSON::Any.new(callback_id),
          "tool_use_id" => JSON::Any.new("tool-1"),
          "input"       => JSON::Any.new({
            "hook_event_name" => JSON::Any.new("PreToolUse"),
            "session_id"      => JSON::Any.new("sess-1"),
            "cwd"             => JSON::Any.new("/tmp"),
            "tool_name"       => JSON::Any.new("Bash"),
            "tool_use_id"     => JSON::Any.new("tool-1"),
            "tool_input"      => JSON::Any.new({"command" => JSON::Any.new("ls")}),
          }),
        }),
      }.to_json)

      client.test_handle_control_request(request)

      response = fake_cli.sent_control_responses.last["response"].as_h["response"].as_h
      response["continue"].as_bool.should be_true
      response["suppressOutput"].as_bool.should be_false
      response["decision"].as_s.should eq("block")
      response["systemMessage"].as_s.should eq("System warning")
      response["reason"].as_s.should eq("Denied")

      hook_output = response["hookSpecificOutput"].as_h
      hook_output["hookEventName"].as_s.should eq("PreToolUse")
      hook_output["permissionDecision"].as_s.should eq("deny")
      hook_output["permissionDecisionReason"].as_s.should eq("Nope")
      hook_output["updatedInput"].as_h["command"].as_s.should eq("pwd")
      hook_output["additionalContext"].as_s.should eq("Extra context")
    ensure
      client.stop
    end
  end

  it "replies with a control_response error for unknown control_request subtypes (never hangs the CLI)" do
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(nil, fake_cli)

    begin
      client.start

      request = ClaudeAgent::ControlRequest.from_json({
        "type"       => JSON::Any.new("control_request"),
        "request_id" => JSON::Any.new("req-unknown-1"),
        "request"    => JSON::Any.new({
          "subtype" => JSON::Any.new("brand_new_subtype"),
        }),
      }.to_json)

      client.test_handle_control_request(request)

      response = fake_cli.sent_control_responses.last["response"].as_h
      response["subtype"].as_s.should eq("error")
      response["request_id"].as_s.should eq("req-unknown-1")
      response["error"].as_s.should contain("brand_new_subtype")
    ensure
      client.stop
    end
  end

  it "forwards title via the initialize control request (never as a CLI flag)" do
    options = ClaudeAgent::AgentOptions.new(title: "my custom title")
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(options, fake_cli)

    begin
      client.start
      initialize_request = fake_cli.sent_messages.first["request"].as_h
      initialize_request["title"].as_s.should eq("my custom title")
    ensure
      client.stop
    end
  end

  it "omits title from the initialize request when it is whitespace-only" do
    options = ClaudeAgent::AgentOptions.new(title: "   ")
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(options, fake_cli)

    begin
      client.start
      initialize_request = fake_cli.sent_messages.first["request"].as_h
      initialize_request.has_key?("title").should be_false
    ensure
      client.stop
    end
  end

  it "forwards excludeDynamicSections via the initialize control request" do
    preset = ClaudeAgent::SystemPromptPreset.claude_code("Append", true)
    options = ClaudeAgent::AgentOptions.new(system_prompt: preset)
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(options, fake_cli)

    begin
      client.start
      initialize_request = fake_cli.sent_messages.first["request"].as_h
      initialize_request["excludeDynamicSections"]?.try(&.as_bool).should be_true
    ensure
      client.stop
    end
  end

  it "does not forward excludeDynamicSections when the preset flag is false" do
    preset = ClaudeAgent::SystemPromptPreset.claude_code("Append")
    options = ClaudeAgent::AgentOptions.new(system_prompt: preset)
    fake_cli = FakeCLIClient.new
    client = ClaudeAgent::AgentClient.new(options, fake_cli)

    begin
      client.start
      initialize_request = fake_cli.sent_messages.first["request"].as_h
      initialize_request.has_key?("excludeDynamicSections").should be_false
    ensure
      client.stop
    end
  end
end

describe "AgentClient session store mirroring" do
  it "peels transcript_mirror frames into the SessionStore and flushes on result" do
    store = ClaudeAgent::InMemorySessionStore.new
    project_key = "mirror_proj"
    session_id = UUID.random.to_s
    config_home = File.join(Dir.tempdir, "cfg-#{UUID.random}")
    Dir.mkdir_p(File.join(config_home, "projects", project_key))
    session_file = File.join(config_home, "projects", project_key, "#{session_id}.jsonl")

    options = ClaudeAgent::AgentOptions.new(
      session_store: store,
      session_store_flush: "batched",
      env: {"CLAUDE_CONFIG_DIR" => config_home},
    )

    fake_cli = FakeCLIClient.new(
      control_responses: {"initialize" => {} of String => JSON::Any},
    )
    client = ClaudeAgent::AgentClient.new(options, fake_cli)

    begin
      client.start

      entry_uuid = UUID.random.to_s
      mirror = ClaudeAgent::UnknownMessage.new("transcript_mirror", {
        "type"     => JSON::Any.new("transcript_mirror"),
        "filePath" => JSON::Any.new(session_file),
        "entries"  => JSON::Any.new([
          JSON::Any.new({
            "type"      => JSON::Any.new("user"),
            "uuid"      => JSON::Any.new(entry_uuid),
            "sessionId" => JSON::Any.new(session_id),
            "message"   => JSON::Any.new({
              "role"    => JSON::Any.new("user"),
              "content" => JSON::Any.new("mirrored"),
            }),
          } of String => JSON::Any),
        ]),
      } of String => JSON::Any)

      result = ClaudeAgent::ResultMessage.from_json({
        "type"       => JSON::Any.new("result"),
        "uuid"       => JSON::Any.new(UUID.random.to_s),
        "session_id" => JSON::Any.new(session_id),
        "subtype"    => JSON::Any.new("success"),
      }.to_json)

      fake_cli.push_message(mirror)
      fake_cli.push_message(result)
      fake_cli.close_messages

      got_result = false
      client.each_response do |message|
        case message
        when ClaudeAgent::ResultMessage
          got_result = true
        when ClaudeAgent::UnknownMessage
          message.type.should_not eq("transcript_mirror")
        end
      end
      got_result.should be_true

      key = ClaudeAgent::SessionKey.new(project_key, session_id)
      loaded = store.load(key)
      loaded.should_not be_nil
      loaded.try(&.map(&.uuid)).should eq([entry_uuid])
    ensure
      client.stop
      FileUtils.rm_rf(config_home) if Dir.exists?(config_home)
    end
  end

  it "surfaces mirror_error when the store path cannot be resolved" do
    store = ClaudeAgent::InMemorySessionStore.new
    options = ClaudeAgent::AgentOptions.new(session_store: store)
    fake_cli = FakeCLIClient.new(
      control_responses: {"initialize" => {} of String => JSON::Any},
    )
    client = ClaudeAgent::AgentClient.new(options, fake_cli)

    begin
      client.start

      mirror = ClaudeAgent::UnknownMessage.new("transcript_mirror", {
        "type"     => JSON::Any.new("transcript_mirror"),
        "filePath" => JSON::Any.new("/totally/outside/projects/sess.jsonl"),
        "entries"  => JSON::Any.new([
          JSON::Any.new({
            "type" => JSON::Any.new("user"),
            "uuid" => JSON::Any.new(UUID.random.to_s),
          } of String => JSON::Any),
        ]),
      } of String => JSON::Any)

      result = ClaudeAgent::ResultMessage.from_json({
        "type"       => JSON::Any.new("result"),
        "uuid"       => JSON::Any.new(UUID.random.to_s),
        "session_id" => JSON::Any.new("sess"),
        "subtype"    => JSON::Any.new("success"),
      }.to_json)

      fake_cli.push_message(mirror)
      fake_cli.push_message(result)
      fake_cli.close_messages

      saw_mirror_error = false
      client.each_response do |message|
        saw_mirror_error = true if message.is_a?(ClaudeAgent::MirrorErrorMessage)
      end
      saw_mirror_error.should be_true
    ensure
      client.stop
    end
  end
end
