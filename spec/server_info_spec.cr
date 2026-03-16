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
end
