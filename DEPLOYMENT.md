# Claude Agent SDK Deployment Guide

This guide explains how to deploy autonomous AI agents built with the Claude Agent SDK for Crystal in production environments. It covers environment configuration, authentication, and deployment setups for **Stdio**, **HTTP**, and **SSE** transports.

---

## 1. Production Environment Configuration

When deploying Claude-powered agents to server environments (e.g., Docker, AWS, Heroku, or Kubernetes), configure the following environment settings for stability and isolation.

### Config and Session Directory Isolation
By default, the Claude Code CLI stores user settings, local command history, and session transcripts in `~/.claude`. In production, set `CLAUDE_CONFIG_DIR` to isolate transcripts and avoid permission errors in read-only or containerized filesystems:

```bash
# Store all Claude CLI state in a dedicated, writable project subdirectory
export CLAUDE_CONFIG_DIR="/opt/agent/config"
```

### Claude CLI Executable Resolution
If the bundled `claude` CLI cannot be resolved automatically, specify the exact absolute path using the `cli_path` option or `CLAUDE_BIN` environment variable:

```bash
export CLAUDE_BIN="/usr/local/bin/claude"
```

### Non-Interactive Shell Optimization
Ensure standard input redirection is configured. If your deployment environment wraps the execution in a Docker container, declare non-interactive mode:

```bash
export DEBIAN_FRONTEND="noninteractive"
```

---

## 2. Authentication Strategies

The Claude CLI requires authentication to communicate with the Anthropic API. Use one of the following methods in production:

### Scoped Anthropic API Token (Recommended)
Expose the `ANTHROPIC_API_KEY` to the process. The Claude CLI will automatically read it and bypass interactive logins:

```bash
export ANTHROPIC_API_KEY="sk-ant-api03-xxxxxxxx"
```

### Workload Identity Federation / OIDC
In cloud environments like Google Cloud, AWS, or GitHub Actions, you can configure Workload Identity Federation to authenticate without long-lived API secrets by obtaining short-lived exchange tokens.

---

## 3. Deployment Transports

The SDK supports integrating tools and agents across three major transport paradigms.

### Transport 1: Stdio Transport (Local Processes / Daemons)
The Stdio transport runs the agent or its MCP tools as a local process. Communication occurs via standard input (`stdin`) and standard output (`stdout`).

#### Best For:
- Secure, single-tenant desktop integration.
- Background worker processes, system daemons, or CLI cron jobs.
- Local MCP tools managed directly by a parent container.

#### Production Daemon Example:
```crystal
# src/stdio_daemon.cr
require "json"
require "claude-agent-cr"

# A robust daemon that executes background tasks on stdio
module StdioDaemon
  extend self

  def run
    puts "Starting background Stdio Agent Daemon..."
    
    # Configure options for Stdio execution
    options = ClaudeAgent::AgentOptions.new(
      permission_mode: ClaudeAgent::PermissionMode::AcceptEdits, # Auto-accept edits in production
      max_turns: 10,
      probe_cli_capabilities: true
    )

    begin
      ClaudeAgent::AgentClient.open(options) do |client|
        # Listen for task prompts on stdin
        while line = STDIN.gets
          next if line.strip.empty?
          
          puts "Processing prompt: #{line.strip}"
          client.query(line.strip)
          
          client.each_response do |message|
            case message
            when ClaudeAgent::AssistantMessage
              # Write outputs back to stdout
              STDOUT.puts({ "type" => "thought", "content" => message.text }.to_json)
              STDOUT.flush
            when ClaudeAgent::ResultMessage
              STDOUT.puts({ "type" => "result", "status" => message.subtype }.to_json)
              STDOUT.flush
            end
          end
        end
      end
    rescue ex : ClaudeAgent::CLINotFoundError
      STDERR.puts "Error: Claude CLI not installed or authenticated."
      exit 1
    rescue ex
      STDERR.puts "Fatal daemon error: #{ex.message}"
      exit 1
    end
  end
end

StdioDaemon.run
```

---

### Transport 2: HTTP Transport (REST Webhooks / Serverless)
The HTTP transport allows external platforms to trigger agent operations via secure request-response endpoints (webhooks).

#### Best For:
- Event-driven automation (e.g., GitHub webhooks, Slack commands).
- Serverless environments (AWS Lambda, Google Cloud Run).
- Integration with third-party web services.

#### Production Webhook Example (using Kemal):
Ensure `kemal` is added to your dependencies.

```crystal
# src/http_webhook.cr
require "kemal"
require "json"
require "claude-agent-cr"

module HttpWebhook
  # Secure request schema
  struct WebhookRequest
    include JSON::Serializable
    getter prompt : String
    getter secure_token : String
  end

  def self.start
    # Read secrets from production environment
    expected_token = ENV["WEBHOOK_SECURE_TOKEN"]?
    raise "WEBHOOK_SECURE_TOKEN is not configured" unless expected_token

    post "/api/agent/run" do |env|
      env.response.content_type = "application/json"
      
      begin
        body = WebhookRequest.from_json(env.request.body.not_nil!)
        
        # Verify incoming security token
        if body.secure_token != expected_token
          env.response.status_code = 401
          next { "error" => "Unauthorized token" }.to_json
        end

        # Configure agent with production options
        options = ClaudeAgent::AgentOptions.new(
          permission_mode: ClaudeAgent::PermissionMode::DontAsk, # Deny everything not pre-approved
          allowed_tools: ["Read", "Edit"],                      # Pre-approve read/write
          max_turns: 5
        )

        results = [] of String
        
        # Run one-shot query synchronously
        ClaudeAgent.query(body.prompt, options) do |message|
          if message.is_a?(ClaudeAgent::AssistantMessage)
            results << message.text
          end
        end

        { "status" => "success", "response" => results.join("\n") }.to_json

      rescue ex : JSON::ParseException
        env.response.status_code = 400
        { "error" => "Invalid JSON payload" }.to_json
      rescue ex
        env.response.status_code = 500
        { "error" => "Agent execution failed: #{ex.message}" }.to_json
      end
    end

    # Run Kemal on server port
    Kemal.run(ENV["PORT"]?.try(&.to_i) || 8080)
  end
end

HttpWebhook.start
```

---

### Transport 3: SSE Transport (Server-Sent Events)
Server-Sent Events (SSE) provide a lightweight, HTTP-compliant protocol for pushing real-time streaming updates from the agent client directly to web frontends.

#### Best For:
- Interactive AI chat interfaces in web browsers.
- Real-time telemetry dashboards streaming thoughts, tool usages, and status signals.
- Keeping HTTP requests open for low-latency streaming without WebSocket overhead.

#### Production SSE Server Example:
```crystal
# src/sse_server.cr
require "http/server"
require "json"
require "claude-agent-cr"

module SseServer
  extend self

  def run
    port = ENV["PORT"]?.try(&.to_i) || 8080
    puts "SSE Server listening on http://127.0.0.1:#{port}"

    server = HTTP::Server.new do |context|
      request = context.request
      response = context.response

      # Simple routing for SSE endpoint
      if request.path == "/stream" && request.method == "GET"
        # Configure response headers for SSE streaming
        response.headers["Content-Type"] = "text/event-stream"
        response.headers["Cache-Control"] = "no-cache"
        response.headers["Connection"] = "keep-alive"
        response.headers["Access-Control-Allow-Origin"] = "*"
        response.flush

        prompt = request.query_params["prompt"]? || "Hello!"

        options = ClaudeAgent::AgentOptions.new(
          permission_mode: ClaudeAgent::PermissionMode::AcceptEdits,
          include_partial_messages: true, # Stream token-by-token
          max_turns: 3
        )

        begin
          # Run streaming agent and push chunks down the SSE pipeline
          ClaudeAgent.query(prompt, options) do |message|
            case message
            when ClaudeAgent::AssistantMessage
              payload = { "type" => "chunk", "text" => message.text }.to_json
              response.puts "data: #{payload}\n\n"
              response.flush
            when ClaudeAgent::ResultMessage
              payload = { "type" => "done", "status" => message.subtype }.to_json
              response.puts "data: #{payload}\n\n"
              response.flush
            end
          end
        rescue ex
          payload = { "type" => "error", "message" => ex.message }.to_json
          response.puts "data: #{payload}\n\n"
          response.flush
        ensure
          # Close the SSE connection safely
          context.response.close
        end
      else
        context.response.status_code = 404
        context.response.print "Endpoint not found"
      end
    end

    server.listen("0.0.0.0", port)
  end
end

SseServer.run
```

---

## 4. Production Deployment Checklist

Before launching your agent-based service into production, ensure the following checklist is completed:

- [ ] **Auth Token Expiry**: Verify your cloud IAM policy or `ANTHROPIC_API_KEY` rotation credentials.
- [ ] **Config Directory Writable**: Confirm `CLAUDE_CONFIG_DIR` points to a writable, persistent, or persistent-volume path.
- [ ] **Memory/Autocompact Tuning**: Keep an eye on project context sizes via `get_context_usage` inside your telemetry stack to detect any runaway memory leaks.
- [ ] **Concurrency Isolation**: If serving multiple tenants, configure independent `CLAUDE_CONFIG_DIR` structures or separate directories for each active session key to prevent cross-tenant transcript leaks.
