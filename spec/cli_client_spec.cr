require "./spec_helper"

# Test helper to access private methods for testing
class TestableCLIClient < ClaudeAgent::CLIClient
  # Expose private methods for testing
  def test_permission_mode_value(mode : ClaudeAgent::PermissionMode) : String
    permission_mode_value(mode)
  end

  def test_build_agents_json(agents : Hash(String, ClaudeAgent::AgentDefinition)) : String
    build_agents_json(agents)
  end

  def test_build_mcp_servers_json(servers : Hash(String, ClaudeAgent::MCPServerConfig)) : String
    build_mcp_servers_json(servers)
  end

  def test_build_settings_json(opts : ClaudeAgent::AgentOptions) : String?
    build_settings_json(opts)
  end

  def test_build_env : Hash(String, String)?
    build_env
  end

  def test_build_cli_args : Array(String)
    build_cli_args
  end

  def test_effort_value(effort : ClaudeAgent::Effort) : String
    effort_value(effort)
  end

  def test_resolve_max_thinking_tokens(opts : ClaudeAgent::AgentOptions) : Int32?
    resolve_max_thinking_tokens(opts)
  end
end

describe ClaudeAgent::CLIClient do
  describe "#initialize" do
    it "initializes with no options" do
      client = ClaudeAgent::CLIClient.new
      client.session_id.should be_nil
      client.has_sdk_servers?.should be_false
    end

    it "initializes with options" do
      options = ClaudeAgent::AgentOptions.new(model: "claude-sonnet-4-20250514")
      client = ClaudeAgent::CLIClient.new(options)
      client.session_id.should be_nil
    end
  end

  describe "#sdk_server_names and #has_sdk_servers?" do
    it "returns empty when no MCP servers" do
      client = ClaudeAgent::CLIClient.new
      client.sdk_server_names.should be_empty
      client.has_sdk_servers?.should be_false
    end

    it "extracts SDK MCP servers from options" do
      sdk_server = ClaudeAgent::SDKMCPServer.new("test-server")
      servers = {} of String => ClaudeAgent::MCPServerConfig
      servers["test"] = sdk_server
      options = ClaudeAgent::AgentOptions.new(mcp_servers: servers)
      client = ClaudeAgent::CLIClient.new(options)

      client.sdk_server_names.should eq(["test"])
      client.has_sdk_servers?.should be_true
    end

    it "ignores external MCP servers when getting SDK servers" do
      external_server = ClaudeAgent::ExternalMCPServerConfig.stdio("node", ["server.js"])
      sdk_server = ClaudeAgent::SDKMCPServer.new("sdk-server")

      servers = {} of String => ClaudeAgent::MCPServerConfig
      servers["external"] = external_server
      servers["sdk"] = sdk_server

      options = ClaudeAgent::AgentOptions.new(mcp_servers: servers)
      client = ClaudeAgent::CLIClient.new(options)

      client.sdk_server_names.should eq(["sdk"])
      client.has_sdk_servers?.should be_true
    end
  end

  describe "#get_sdk_server" do
    it "returns SDK server by name" do
      sdk_server = ClaudeAgent::SDKMCPServer.new("test-server")
      servers = {} of String => ClaudeAgent::MCPServerConfig
      servers["test"] = sdk_server
      options = ClaudeAgent::AgentOptions.new(mcp_servers: servers)
      client = ClaudeAgent::CLIClient.new(options)

      result = client.get_sdk_server("test")
      result.should_not be_nil
      result.try(&.name).should eq("test-server")
    end

    it "returns nil for unknown server" do
      client = ClaudeAgent::CLIClient.new
      client.get_sdk_server("unknown").should be_nil
    end
  end
end

describe TestableCLIClient do
  describe "#permission_mode_value" do
    it "converts Default to 'default'" do
      client = TestableCLIClient.new
      client.test_permission_mode_value(ClaudeAgent::PermissionMode::Default).should eq("default")
    end

    it "converts AcceptEdits to 'acceptEdits'" do
      client = TestableCLIClient.new
      client.test_permission_mode_value(ClaudeAgent::PermissionMode::AcceptEdits).should eq("acceptEdits")
    end

    it "converts Plan to 'plan'" do
      client = TestableCLIClient.new
      client.test_permission_mode_value(ClaudeAgent::PermissionMode::Plan).should eq("plan")
    end

    it "converts BypassPermissions to 'bypassPermissions'" do
      client = TestableCLIClient.new
      client.test_permission_mode_value(ClaudeAgent::PermissionMode::BypassPermissions).should eq("bypassPermissions")
    end
  end

  describe "#effort_value" do
    it "converts effort levels to CLI strings" do
      client = TestableCLIClient.new
      client.test_effort_value(ClaudeAgent::Effort::Low).should eq("low")
      client.test_effort_value(ClaudeAgent::Effort::Medium).should eq("medium")
      client.test_effort_value(ClaudeAgent::Effort::High).should eq("high")
      client.test_effort_value(ClaudeAgent::Effort::Max).should eq("max")
    end
  end

  describe "#resolve_max_thinking_tokens" do
    it "uses max_thinking_tokens when no thinking config is set" do
      opts = ClaudeAgent::AgentOptions.new(max_thinking_tokens: 4096)
      client = TestableCLIClient.new
      client.test_resolve_max_thinking_tokens(opts).should eq(4096)
    end

    it "uses adaptive thinking default when no explicit budget is set" do
      opts = ClaudeAgent::AgentOptions.new(thinking: ClaudeAgent::ThinkingConfig.adaptive)
      client = TestableCLIClient.new
      client.test_resolve_max_thinking_tokens(opts).should eq(32_000)
    end

    it "preserves explicit max_thinking_tokens for adaptive thinking" do
      opts = ClaudeAgent::AgentOptions.new(
        max_thinking_tokens: 16_000,
        thinking: ClaudeAgent::ThinkingConfig.adaptive,
      )
      client = TestableCLIClient.new
      client.test_resolve_max_thinking_tokens(opts).should eq(16_000)
    end

    it "uses enabled thinking budget tokens" do
      opts = ClaudeAgent::AgentOptions.new(thinking: ClaudeAgent::ThinkingConfig.enabled(12_000))
      client = TestableCLIClient.new
      client.test_resolve_max_thinking_tokens(opts).should eq(12_000)
    end

    it "uses zero tokens when thinking is disabled" do
      opts = ClaudeAgent::AgentOptions.new(thinking: ClaudeAgent::ThinkingConfig.disabled)
      client = TestableCLIClient.new
      client.test_resolve_max_thinking_tokens(opts).should eq(0)
    end
  end

  describe "#build_cli_args" do
    it "adds max-thinking-tokens and effort flags" do
      options = ClaudeAgent::AgentOptions.new(
        thinking: ClaudeAgent::ThinkingConfig.enabled(8192),
        effort: ClaudeAgent::Effort::High,
      )
      client = TestableCLIClient.new(options)

      args = client.test_build_cli_args
      args.should contain("--max-thinking-tokens")
      args.should contain("8192")
      args.should contain("--effort")
      args.should contain("high")
    end
  end

  describe "#build_cli_args with max_turns" do
    it "adds --max-turns flag" do
      options = ClaudeAgent::AgentOptions.new(max_turns: 5)
      client = TestableCLIClient.new(options)

      args = client.test_build_cli_args
      args.should contain("--max-turns")
      args.should contain("5")
    end

    it "adds --enable-file-checkpointing and --permission-prompt-tool-name flags" do
      options = ClaudeAgent::AgentOptions.new(
        enable_file_checkpointing: true,
        permission_prompt_tool_name: "AskUser",
      )
      client = TestableCLIClient.new(options)

      args = client.test_build_cli_args
      args.should contain("--enable-file-checkpointing")
      args.should contain("--permission-prompt-tool-name")
      args.should contain("AskUser")
    end
  end

  describe "#build_env" do
    it "sets fine-grained tool streaming env var when partial messages are enabled" do
      options = ClaudeAgent::AgentOptions.new(include_partial_messages: true)
      client = TestableCLIClient.new(options)

      env = client.test_build_env
      env.should_not be_nil
      env.try(&.["CLAUDE_CODE_ENABLE_FINE_GRAINED_TOOL_STREAMING"]?).try(&.should eq("1"))
    end

    it "does not set fine-grained tool streaming env var by default" do
      client = TestableCLIClient.new(ClaudeAgent::AgentOptions.new)

      env = client.test_build_env
      env.should_not be_nil
      env.try(&.["CLAUDE_CODE_ENABLE_FINE_GRAINED_TOOL_STREAMING"]?).should be_nil
    end
  end

  describe "#build_agents_json" do
    it "builds JSON for agent definitions" do
      agents = {
        "researcher" => ClaudeAgent::AgentDefinition.new(
          description: "Research agent",
          prompt: "You are a researcher",
          tools: ["Read", "Grep"],
          model: "claude-sonnet-4-20250514"
        ),
      }

      client = TestableCLIClient.new
      json = client.test_build_agents_json(agents)
      parsed = JSON.parse(json)

      parsed["researcher"]["description"].as_s.should eq("Research agent")
      parsed["researcher"]["prompt"].as_s.should eq("You are a researcher")
      parsed["researcher"]["tools"].as_a.map(&.as_s).should eq(["Read", "Grep"])
      parsed["researcher"]["model"].as_s.should eq("claude-sonnet-4-20250514")
    end

    it "builds JSON for minimal agent definition" do
      agents = {
        "simple" => ClaudeAgent::AgentDefinition.new(
          description: "Simple agent",
          prompt: "You are simple"
        ),
      }

      client = TestableCLIClient.new
      json = client.test_build_agents_json(agents)
      parsed = JSON.parse(json)

      parsed["simple"]["description"].as_s.should eq("Simple agent")
      parsed["simple"]["prompt"].as_s.should eq("You are simple")
      parsed["simple"]["tools"]?.should be_nil
      parsed["simple"]["model"]?.should be_nil
    end
  end

  describe "#build_mcp_servers_json" do
    it "builds JSON for stdio MCP server" do
      servers = {
        "filesystem" => ClaudeAgent::ExternalMCPServerConfig.stdio(
          "node",
          ["filesystem-server.js"],
          {"HOME" => "/home/user"}
        ),
      }

      client = TestableCLIClient.new
      json = client.test_build_mcp_servers_json(servers.transform_values(&.as(ClaudeAgent::MCPServerConfig)))
      parsed = JSON.parse(json)

      parsed["mcpServers"]["filesystem"]["command"].as_s.should eq("node")
      parsed["mcpServers"]["filesystem"]["args"].as_a.map(&.as_s).should eq(["filesystem-server.js"])
      parsed["mcpServers"]["filesystem"]["env"]["HOME"].as_s.should eq("/home/user")
    end

    it "builds JSON for HTTP MCP server" do
      servers = {
        "remote" => ClaudeAgent::ExternalMCPServerConfig.http(
          "https://api.example.com/mcp",
          {"Authorization" => "Bearer token123"}
        ),
      }

      client = TestableCLIClient.new
      json = client.test_build_mcp_servers_json(servers.transform_values(&.as(ClaudeAgent::MCPServerConfig)))
      parsed = JSON.parse(json)

      parsed["mcpServers"]["remote"]["type"].as_s.should eq("http")
      parsed["mcpServers"]["remote"]["url"].as_s.should eq("https://api.example.com/mcp")
      parsed["mcpServers"]["remote"]["headers"]["Authorization"].as_s.should eq("Bearer token123")
    end

    it "builds JSON for SSE MCP server" do
      servers = {
        "streaming" => ClaudeAgent::ExternalMCPServerConfig.sse("https://sse.example.com/events"),
      }

      client = TestableCLIClient.new
      json = client.test_build_mcp_servers_json(servers.transform_values(&.as(ClaudeAgent::MCPServerConfig)))
      parsed = JSON.parse(json)

      parsed["mcpServers"]["streaming"]["type"].as_s.should eq("sse")
      parsed["mcpServers"]["streaming"]["url"].as_s.should eq("https://sse.example.com/events")
    end

    it "excludes SDK MCP servers from JSON" do
      sdk_server = ClaudeAgent::SDKMCPServer.new("sdk-tools")
      external_server = ClaudeAgent::ExternalMCPServerConfig.stdio("node", ["server.js"])

      servers = {
        "sdk"      => sdk_server.as(ClaudeAgent::MCPServerConfig),
        "external" => external_server.as(ClaudeAgent::MCPServerConfig),
      }

      client = TestableCLIClient.new
      json = client.test_build_mcp_servers_json(servers)
      parsed = JSON.parse(json)

      # SDK server should not be in the JSON
      parsed["mcpServers"]["sdk"]?.should be_nil
      parsed["mcpServers"]["external"].should_not be_nil
    end

    it "returns empty string when only SDK servers" do
      sdk_server = ClaudeAgent::SDKMCPServer.new("sdk-tools")
      servers = {"sdk" => sdk_server.as(ClaudeAgent::MCPServerConfig)}

      client = TestableCLIClient.new
      json = client.test_build_mcp_servers_json(servers)
      json.should eq("")
    end
  end

  describe "#build_settings_json" do
    it "returns nil when no sandbox settings" do
      options = ClaudeAgent::AgentOptions.new
      client = TestableCLIClient.new
      client.test_build_settings_json(options).should be_nil
    end

    it "builds JSON for basic sandbox settings" do
      sandbox = ClaudeAgent::SandboxSettings.new(
        enabled: true,
        auto_allow_bash_if_sandboxed: true
      )
      options = ClaudeAgent::AgentOptions.new(sandbox: sandbox)

      client = TestableCLIClient.new
      json = client.test_build_settings_json(options)
      json.should_not be_nil

      if json
        parsed = JSON.parse(json)
        parsed["sandbox"]["enabled"].as_bool.should be_true
        parsed["sandbox"]["autoAllowBashIfSandboxed"].as_bool.should be_true
      end
    end

    it "builds JSON for sandbox with excluded commands" do
      sandbox = ClaudeAgent::SandboxSettings.new(
        enabled: true,
        excluded_commands: ["rm", "dd", "mkfs"]
      )
      options = ClaudeAgent::AgentOptions.new(sandbox: sandbox)

      client = TestableCLIClient.new
      json = client.test_build_settings_json(options)

      if json
        parsed = JSON.parse(json)
        parsed["sandbox"]["excludedCommands"].as_a.map(&.as_s).should eq(["rm", "dd", "mkfs"])
      end
    end

    it "builds JSON for sandbox with network settings" do
      network = ClaudeAgent::SandboxNetworkSettings.new(
        allow_local_binding: true,
        allow_unix_sockets: ["/tmp/socket1", "/tmp/socket2"],
        http_proxy_port: 8080,
        socks_proxy_port: 1080
      )
      sandbox = ClaudeAgent::SandboxSettings.new(
        enabled: true,
        network: network
      )
      options = ClaudeAgent::AgentOptions.new(sandbox: sandbox)

      client = TestableCLIClient.new
      json = client.test_build_settings_json(options)

      if json
        parsed = JSON.parse(json)
        net = parsed["sandbox"]["network"]
        net["allowLocalBinding"].as_bool.should be_true
        net["allowUnixSockets"].as_a.map(&.as_s).should eq(["/tmp/socket1", "/tmp/socket2"])
        net["httpProxyPort"].as_i.should eq(8080)
        net["socksProxyPort"].as_i.should eq(1080)
      end
    end

    it "builds JSON for sandbox with ignore violations" do
      ignore = ClaudeAgent::SandboxIgnoreViolations.new(
        file: ["/tmp/*", "/var/log/*"],
        network: ["*.example.com"]
      )
      sandbox = ClaudeAgent::SandboxSettings.new(
        enabled: true,
        ignore_violations: ignore
      )
      options = ClaudeAgent::AgentOptions.new(sandbox: sandbox)

      client = TestableCLIClient.new
      json = client.test_build_settings_json(options)

      if json
        parsed = JSON.parse(json)
        violations = parsed["sandbox"]["ignoreViolations"]
        violations["file"].as_a.map(&.as_s).should eq(["/tmp/*", "/var/log/*"])
        violations["network"].as_a.map(&.as_s).should eq(["*.example.com"])
      end
    end
  end
end

describe ClaudeAgent::ExternalMCPServerConfig do
  describe ".stdio" do
    it "creates stdio server config" do
      config = ClaudeAgent::ExternalMCPServerConfig.stdio("python", ["-m", "server"])
      config.command.should eq("python")
      config.args.should eq(["-m", "server"])
      config.type.should be_nil # stdio is default, no explicit type needed
    end

    it "creates stdio server with environment" do
      config = ClaudeAgent::ExternalMCPServerConfig.stdio(
        "node",
        ["server.js"],
        {"NODE_ENV" => "production"}
      )
      config.env.should eq({"NODE_ENV" => "production"})
    end
  end

  describe ".http" do
    it "creates HTTP server config" do
      config = ClaudeAgent::ExternalMCPServerConfig.http("https://api.example.com")
      config.type.should eq("http")
      config.url.should eq("https://api.example.com")
    end

    it "creates HTTP server with headers" do
      config = ClaudeAgent::ExternalMCPServerConfig.http(
        "https://api.example.com",
        {"X-API-Key" => "secret"}
      )
      config.headers.should eq({"X-API-Key" => "secret"})
    end
  end

  describe ".sse" do
    it "creates SSE server config" do
      config = ClaudeAgent::ExternalMCPServerConfig.sse("https://events.example.com")
      config.type.should eq("sse")
      config.url.should eq("https://events.example.com")
    end
  end
end

describe ClaudeAgent::ToolsPreset do
  describe ".claude_code" do
    it "creates claude_code preset" do
      preset = ClaudeAgent::ToolsPreset.claude_code
      preset.type.should eq("preset")
      preset.preset.should eq("claude_code")
    end
  end

  describe ".default" do
    it "creates default preset" do
      preset = ClaudeAgent::ToolsPreset.default
      preset.type.should eq("preset")
      preset.preset.should eq("default")
    end
  end
end

describe ClaudeAgent::SystemPromptPreset do
  describe ".claude_code" do
    it "creates claude_code preset without append" do
      preset = ClaudeAgent::SystemPromptPreset.claude_code
      preset.type.should eq("preset")
      preset.preset.should eq("claude_code")
      preset.append.should be_nil
    end

    it "creates claude_code preset with append" do
      preset = ClaudeAgent::SystemPromptPreset.claude_code("Additional instructions")
      preset.preset.should eq("claude_code")
      preset.append.should eq("Additional instructions")
    end
  end
end
