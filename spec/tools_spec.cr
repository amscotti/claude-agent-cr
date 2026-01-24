require "./spec_helper"

describe ClaudeAgent::SDKTool do
  it "can be defined and called" do
    tool = ClaudeAgent.tool(
      name: "test_tool",
      description: "A test tool",
      schema: ClaudeAgent::Schema.object(
        {"arg" => ClaudeAgent::Schema.string},
        ["arg"]
      )
    ) do |args|
      ClaudeAgent::ToolResult.text("You said: #{args["arg"]}")
    end

    tool.name.should eq("test_tool")

    result = tool.call({"arg" => JSON::Any.new("hello")})
    result.content.size.should eq(1)
    result.content[0].text.should eq("You said: hello")
  end
end

describe ClaudeAgent::SDKMCPServer do
  it "can manage tools" do
    server = ClaudeAgent::SDKMCPServer.new("test-server")

    tool = ClaudeAgent.tool("t1", "d1", ClaudeAgent::Schema.string) { |_| ClaudeAgent::ToolResult.text("ok") }
    server.add_tool(tool)

    server.tools.size.should eq(1)

    list = server.handle_list_tools
    list.size.should eq(1)
    list[0]["name"].as_s.should eq("t1")
  end
end
