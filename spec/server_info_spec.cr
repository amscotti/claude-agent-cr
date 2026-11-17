require "./spec_helper"

describe ClaudeAgent::ServerInfo do
  it "builds typed server info from raw JSON data" do
    data = {
      "commands" => JSON::Any.new([
        JSON::Any.new({
          "name"         => JSON::Any.new("review"),
          "description"  => JSON::Any.new("Review code"),
          "argumentHint" => JSON::Any.new("[path]"),
        }),
      ]),
      "agents" => JSON::Any.new([
        JSON::Any.new({
          "name"        => JSON::Any.new("reviewer"),
          "description" => JSON::Any.new("Reviews code"),
          "model"       => JSON::Any.new("haiku"),
        }),
      ]),
      "output_style"            => JSON::Any.new("default"),
      "available_output_styles" => JSON::Any.new([
        JSON::Any.new("default"),
        JSON::Any.new("compact"),
      ]),
      "models" => JSON::Any.new([
        JSON::Any.new({
          "value"                 => JSON::Any.new("default"),
          "displayName"           => JSON::Any.new("Default"),
          "supportsEffort"        => JSON::Any.new(true),
          "supportedEffortLevels" => JSON::Any.new([
            JSON::Any.new("low"),
            JSON::Any.new("high"),
          ]),
        }),
      ]),
      "account" => JSON::Any.new({
        "email"        => JSON::Any.new("user@example.com"),
        "organization" => JSON::Any.new("Example Org"),
      }),
      "pid" => JSON::Any.new(123_i64),
    }

    info = ClaudeAgent::ServerInfo.from_data(data)

    info.commands.first.name.should eq("review")
    info.commands.first.argument_hint.should eq("[path]")
    info.agents.first.model.should eq("haiku")
    info.output_style.should eq("default")
    info.available_output_styles.should eq(["default", "compact"])
    info.models.first.display_name.should eq("Default")
    info.models.first.supports_effort?.should be_true
    info.models.first.supported_effort_levels.should eq(["low", "high"])
    info.account.try(&.email).should eq("user@example.com")
    info.pid.should eq(123)
    info.raw_data["pid"].as_i64.should eq(123)
  end

  it "provides command and model helpers" do
    data = {
      "commands" => JSON::Any.new([
        JSON::Any.new({"name" => JSON::Any.new("review")}),
        JSON::Any.new({"name" => JSON::Any.new("commit")}),
      ]),
      "models" => JSON::Any.new([
        JSON::Any.new({"value" => JSON::Any.new("default")}),
      ]),
    }

    info = ClaudeAgent::ServerInfo.from_data(data)

    info.slash_commands.should eq(["review", "commit"])
    info.command_named?("commit").should_not be_nil
    info.command_named?("missing").should be_nil
    info.agent_named?("reviewer").should be_nil
    info.model_named?("default").should_not be_nil
    info.model_named?("unknown").should be_nil
  end

  it "falls back to slash_commands and string agent names" do
    data = {
      "slash_commands" => JSON::Any.new([
        JSON::Any.new("review"),
        JSON::Any.new("commit"),
      ]),
      "agents" => JSON::Any.new([
        JSON::Any.new("general-purpose"),
        JSON::Any.new("Explore"),
      ]),
      "output_style" => JSON::Any.new("default"),
    }

    info = ClaudeAgent::ServerInfo.from_data(data)

    info.commands.map(&.name).should eq(["review", "commit"])
    info.agents.map(&.name).should eq(["general-purpose", "Explore"])
    info.supported_agent_names.should eq(["general-purpose", "Explore"])
    info.output_style.should eq("default")
  end

  it "finds agents by name" do
    data = {
      "agents" => JSON::Any.new([
        JSON::Any.new({"name" => JSON::Any.new("reviewer"), "description" => JSON::Any.new("Reviews code")}),
      ]),
    }

    info = ClaudeAgent::ServerInfo.from_data(data)

    info.agent_named?("reviewer").should_not be_nil
    info.agent_named?("reviewer").try(&.description).should eq("Reviews code")
    info.agent_named?("missing").should be_nil
  end

  it "parses plugin version into typed ServerPluginInfo via plugin_infos" do
    data = {
      "plugins" => JSON::Any.new([
        JSON::Any.new({
          "name"    => JSON::Any.new("code-review"),
          "version" => JSON::Any.new("1.2.3"),
          "path"    => JSON::Any.new("/plugins/code-review"),
          "source"  => JSON::Any.new("local"),
        }),
        JSON::Any.new({
          "name"   => JSON::Any.new("legacy-plugin"),
          "path"   => JSON::Any.new("/plugins/legacy"),
          "source" => JSON::Any.new("remote"),
        }),
      ]),
    }

    info = ClaudeAgent::ServerInfo.from_data(data)

    # Raw array remains for forward-compat and existing InitMessage callers.
    info.plugins.size.should eq(2)
    info.plugins.first.as_h["name"].as_s.should eq("code-review")
    info.plugins.first.as_h["version"].as_s.should eq("1.2.3")

    infos = info.plugin_infos
    infos.size.should eq(2)
    infos.first.name.should eq("code-review")
    infos.first.version.should eq("1.2.3")
    infos.first.path.should eq("/plugins/code-review")
    infos.first.source.should eq("local")
    infos.last.name.should eq("legacy-plugin")
    infos.last.version.should be_nil

    info.plugin_named?("code-review").try(&.version).should eq("1.2.3")
    info.plugin_named?("missing").should be_nil
  end

  it "parses fast_mode_disabled_reason from snake and camel wire keys" do
    snake = ClaudeAgent::ServerInfo.from_data({
      "fast_mode_state"           => JSON::Any.new("off"),
      "fast_mode_disabled_reason" => JSON::Any.new("model_not_supported"),
    })
    snake.fast_mode_state.should eq("off")
    snake.fast_mode_disabled_reason.should eq("model_not_supported")

    camel = ClaudeAgent::ServerInfo.from_data({
      "fastModeState"          => JSON::Any.new("off"),
      "fastModeDisabledReason" => JSON::Any.new("account_tier"),
    })
    camel.fast_mode_state.should eq("off")
    camel.fast_mode_disabled_reason.should eq("account_tier")

    absent = ClaudeAgent::ServerInfo.from_data({} of String => JSON::Any)
    absent.fast_mode_disabled_reason.should be_nil
  end

  it "parses effort and terminal_slash_commands (TS 0.3.229/0.3.234 parity)" do
    info = ClaudeAgent::ServerInfo.from_data({
      "effort"                => JSON::Any.new("high"),
      "terminalSlashCommands" => JSON::Any.new([JSON::Any.new("/ide"), JSON::Any.new("/terminal")]),
    })
    info.effort.try(&.as_s?).should eq("high")
    info.terminal_slash_commands.should eq(["/ide", "/terminal"])

    snake = ClaudeAgent::ServerInfo.from_data({
      "terminal_slash_commands" => JSON::Any.new([JSON::Any.new("/vim")]),
    })
    snake.terminal_slash_commands.should eq(["/vim"])
    snake.effort.should be_nil

    absent = ClaudeAgent::ServerInfo.from_data({} of String => JSON::Any)
    absent.effort.should be_nil
    absent.terminal_slash_commands.should be_nil
  end

  it "preserves model capability flags including supports_fast_mode" do
    data = {
      "models" => JSON::Any.new([
        JSON::Any.new({
          "value"                 => JSON::Any.new("claude-opus-4-7"),
          "displayName"           => JSON::Any.new("Opus 4.7"),
          "supportsEffort"        => JSON::Any.new(true),
          "supportedEffortLevels" => JSON::Any.new([
            JSON::Any.new("low"),
            JSON::Any.new("high"),
            JSON::Any.new("xhigh"),
          ]),
          "supportsAdaptiveThinking" => JSON::Any.new(true),
          "supportsFastMode"         => JSON::Any.new(true),
        }),
      ]),
    }

    info = ClaudeAgent::ServerInfo.from_data(data)
    model = info.models.first
    model.value.should eq("claude-opus-4-7")
    model.supports_effort?.should be_true
    model.supported_effort_levels.should eq(["low", "high", "xhigh"])
    model.supports_adaptive_thinking?.should be_true
    model.supports_fast_mode?.should be_true
  end

  it "exposes ClaudeAgent::Models string constants without restricting AgentOptions" do
    ClaudeAgent::Models::OPUS_5_5.should eq("claude-opus-5-5")
    ClaudeAgent::Models::SONNET_5_5.should eq("claude-sonnet-5-5")
    ClaudeAgent::Models::HAIKU_5_5.should eq("claude-haiku-5-5")
    ClaudeAgent::Models::FABLE_5_2.should eq("claude-fable-5-2")
    ClaudeAgent::Models::FABLE_5_1.should eq("claude-fable-5-1")
    ClaudeAgent::Models::MYTHOS_5_2.should eq("claude-mythos-5-2")
    ClaudeAgent::Models::MYTHOS_5_1.should eq("claude-mythos-5-1")
    ClaudeAgent::Models::SONNET_5.should eq("claude-sonnet-5")
    ClaudeAgent::Models::OPUS_5.should eq("claude-opus-5")
    ClaudeAgent::Models::FABLE_5.should eq("claude-fable-5")
    ClaudeAgent::Models::MYTHOS_5.should eq("claude-mythos-5")
    ClaudeAgent::Models::FABLE.should eq("fable")
    ClaudeAgent::Models::OPUS_4_8.should eq("claude-opus-4-8")
    ClaudeAgent::Models::OPUS_4_7.should eq("claude-opus-4-7")
    ClaudeAgent::Models::OPUS_4_6.should eq("claude-opus-4-6")
    ClaudeAgent::Models::OPUS_4_5.should eq("claude-opus-4-5")
    ClaudeAgent::Models::SONNET_4_6.should eq("claude-sonnet-4-6")
    ClaudeAgent::Models::SONNET_4_5.should eq("claude-sonnet-4-5")
    ClaudeAgent::Models::SONNET_4_5_20250929.should eq("claude-sonnet-4-5-20250929")
    ClaudeAgent::Models::HAIKU_4_5.should eq("claude-haiku-4-5")

    # Ensure claude-mythos-preview remains strictly omitted.
    {% begin %}
      {{ ClaudeAgent::Models.constants.stringify }}.includes?("PREVIEW").should be_false
    {% end %}

    # Free-form String model field still accepts arbitrary IDs.
    opts = ClaudeAgent::AgentOptions.new(model: ClaudeAgent::Models::OPUS_5_5)
    opts.model.should eq("claude-opus-5-5")
    opts2 = ClaudeAgent::AgentOptions.new(model: "custom-internal-model")
    opts2.model.should eq("custom-internal-model")
  end

  it "parses ServerCommand aliases and builtin flag" do
    data = {
      "commands" => JSON::Any.new([
        JSON::Any.new({
          "name"         => JSON::Any.new("review"),
          "description"  => JSON::Any.new("Review code"),
          "argumentHint" => JSON::Any.new("[path]"),
          "aliases"      => JSON::Any.new([JSON::Any.new("rev"), JSON::Any.new("code-review")]),
          "builtin"      => JSON::Any.new(true),
        }),
        JSON::Any.new({
          "name"    => JSON::Any.new("custom-cmd"),
          "builtin" => JSON::Any.new(false),
        }),
        JSON::Any.new({
          "name" => JSON::Any.new("legacy-cmd"),
        }),
      ]),
    }

    info = ClaudeAgent::ServerInfo.from_data(data)
    info.commands.size.should eq(3)

    first = info.commands[0]
    first.aliases.should eq(["rev", "code-review"])
    first.builtin.should be_true
    first.builtin?.should be_true

    second = info.commands[1]
    second.aliases.should be_nil
    second.builtin.should be_false
    second.builtin?.should be_false

    third = info.commands[2]
    third.aliases.should be_nil
    third.builtin.should be_nil
    third.builtin?.should be_false
  end

  it "parses ServerModelInfo resolved_model and supports_auto_mode from camel and snake keys" do
    data = {
      "models" => JSON::Any.new([
        JSON::Any.new({
          "value"            => JSON::Any.new("default"),
          "resolvedModel"    => JSON::Any.new("claude-opus-5-5"),
          "supportsAutoMode" => JSON::Any.new(true),
        }),
        JSON::Any.new({
          "value"              => JSON::Any.new("haiku"),
          "resolved_model"     => JSON::Any.new("claude-haiku-5-5"),
          "supports_auto_mode" => JSON::Any.new(false),
        }),
        JSON::Any.new({
          "value" => JSON::Any.new("legacy"),
        }),
      ]),
    }

    info = ClaudeAgent::ServerInfo.from_data(data)
    info.models.size.should eq(3)

    info.models[0].resolved_model.should eq("claude-opus-5-5")
    info.models[0].supports_auto_mode?.should be_true
    info.models[0].supports_auto_mode.should be_true

    info.models[1].resolved_model.should eq("claude-haiku-5-5")
    info.models[1].supports_auto_mode?.should be_false
    info.models[1].supports_auto_mode.should be_false

    info.models[2].resolved_model.should be_nil
    info.models[2].supports_auto_mode?.should be_nil
  end

  it "parses capabilities, plugin_errors, mcp_server_infos, api_key_source, betas, uuid, view_mode, startup_timing" do
    data = {
      "uuid"         => JSON::Any.new("init-uuid-1"),
      "apiKeySource" => JSON::Any.new("ANTHROPIC_API_KEY"),
      "betas"        => JSON::Any.new([JSON::Any.new("interleaved-thinking-2025-05-14")]),
      "capabilities" => JSON::Any.new([
        JSON::Any.new("interrupt_receipt_v1"),
        JSON::Any.new("reload_plugins_refuse_if_busy_v1"),
      ]),
      "viewMode"      => JSON::Any.new("focus"),
      "startupTiming" => JSON::Any.new({"total_ms" => JSON::Any.new(42_i64)}),
      "mcp_servers"   => JSON::Any.new([
        JSON::Any.new({
          "name"   => JSON::Any.new("github"),
          "status" => JSON::Any.new("connected"),
          "source" => JSON::Any.new("plugin"),
        }),
        JSON::Any.new({
          "name"   => JSON::Any.new("local-tools"),
          "status" => JSON::Any.new("failed"),
        }),
      ]),
      "plugin_errors" => JSON::Any.new([
        JSON::Any.new({
          "plugin"          => JSON::Any.new("bad@marketplace"),
          "type"            => JSON::Any.new("manifest-validation-error"),
          "message"         => JSON::Any.new("Invalid plugin.json"),
          "path"            => JSON::Any.new("/plugins/bad"),
          "install_command" => JSON::Any.new("claude plugin install bad@marketplace"),
          "managed_lock"    => JSON::Any.new({
            "plugin_enabled" => JSON::Any.new(true),
            "name"           => JSON::Any.new("bad"),
            "marketplace"    => JSON::Any.new("marketplace"),
          }),
        }),
        JSON::Any.new({"plugin" => JSON::Any.new("incomplete-error")}),
      ]),
    }

    info = ClaudeAgent::ServerInfo.from_data(data)

    info.uuid.should eq("init-uuid-1")
    info.api_key_source.should eq("ANTHROPIC_API_KEY")
    info.betas.should eq(["interleaved-thinking-2025-05-14"])
    info.capabilities.should eq(["interrupt_receipt_v1", "reload_plugins_refuse_if_busy_v1"])
    info.view_mode.should eq("focus")
    info.startup_timing.try(&.["total_ms"].as_i64).should eq(42_i64)

    # Raw mcp_servers preserved alongside typed mcp_server_infos.
    info.mcp_servers.size.should eq(2)
    info.mcp_server_infos.size.should eq(2)
    info.mcp_server_infos[0].name.should eq("github")
    info.mcp_server_infos[0].status.should eq("connected")
    info.mcp_server_infos[0].source.should eq("plugin")
    info.mcp_server_infos[1].name.should eq("local-tools")
    info.mcp_server_infos[1].source.should be_nil
    info.mcp_server_named?("github").try(&.status).should eq("connected")
    info.mcp_server_named?("missing").should be_nil

    # Malformed plugin_errors entries without type/message are ignored.
    info.plugin_errors.size.should eq(1)
    err = info.plugin_errors.first
    err.plugin.should eq("bad@marketplace")
    err.type.should eq("manifest-validation-error")
    err.message.should eq("Invalid plugin.json")
    err.path.should eq("/plugins/bad")
    err.install_command.should eq("claude plugin install bad@marketplace")
    err.managed_lock.try(&.["plugin_enabled"].as_bool).should be_true
  end

  it "supports snake_case fallbacks and defaults for new ServerInfo fields and exposes fast-mode sets" do
    snake = ClaudeAgent::ServerInfo.from_data({
      "api_key_source" => JSON::Any.new("none"),
      "view_mode"      => JSON::Any.new("default"),
      "startup_timing" => JSON::Any.new({"init_ms" => JSON::Any.new(10_i64)}),
    })
    snake.api_key_source.should eq("none")
    snake.view_mode.should eq("default")
    snake.startup_timing.try(&.["init_ms"].as_i64).should eq(10_i64)

    empty = ClaudeAgent::ServerInfo.from_data({} of String => JSON::Any)
    empty.capabilities.should be_empty
    empty.plugin_errors.should be_empty
    empty.mcp_server_infos.should be_empty
    empty.betas.should be_empty
    empty.api_key_source.should be_nil
    empty.uuid.should be_nil
    empty.view_mode.should be_nil
    empty.startup_timing.should be_nil

    ClaudeAgent::FAST_MODE_STATES.should eq(Set{"off", "cooldown", "on"})
    ClaudeAgent::FAST_MODE_DISABLED_REASONS.should contain("sdk_opt_in_required")
    ClaudeAgent::FAST_MODE_DISABLED_REASONS.should contain("model_not_allowed")
    ClaudeAgent::FAST_MODE_DISABLED_REASONS.size.should eq(10)
  end
end
