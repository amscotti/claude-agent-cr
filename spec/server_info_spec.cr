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
    ClaudeAgent::Models::HAIKU_4_5.should eq("claude-haiku-4-5")

    # Free-form String model field still accepts arbitrary IDs.
    opts = ClaudeAgent::AgentOptions.new(model: ClaudeAgent::Models::OPUS_4_7)
    opts.model.should eq("claude-opus-4-7")
    opts2 = ClaudeAgent::AgentOptions.new(model: "custom-internal-model")
    opts2.model.should eq("custom-internal-model")
  end
end
