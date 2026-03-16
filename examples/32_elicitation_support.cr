require "../src/claude-agent-cr"

# This example demonstrates the MCP elicitation API surface.
# It requires an MCP server that requests user input (for example, a URL auth or
# form-based authentication flow). Set ELICITATION_MCP_URL to a compatible MCP
# endpoint to try it live.

elicitation_url = ENV["ELICITATION_MCP_URL"]?

unless elicitation_url
  puts "Set ELICITATION_MCP_URL to a compatible MCP endpoint to run this example."
  puts "This example demonstrates the configuration for:"
  puts "  - on_elicitation callback"
  puts "  - Elicitation/ElicitationResult hooks"
  puts "  - ElicitationCompleteMessage handling"
  exit 0
end

elicitation_hook = ->(input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
  puts "[Elicitation hook] server=#{input.mcp_server_name} mode=#{input.elicitation_mode}"
  ClaudeAgent::HookResult.elicitation("decline")
}

elicitation_result_hook = ->(input : ClaudeAgent::HookInput, _id : String, _ctx : ClaudeAgent::HookContext) {
  puts "[Elicitation result hook] action=#{input.elicitation_action}"
  ClaudeAgent::HookResult.elicitation_result(input.elicitation_action || "decline")
}

mcp_servers = {} of String => ClaudeAgent::MCPServerConfig
mcp_servers["elicitation"] = ClaudeAgent::ExternalMCPServerConfig.http(elicitation_url)

options = ClaudeAgent::AgentOptions.new(
  mcp_servers: mcp_servers,
  hooks: ClaudeAgent::HookConfig.new(
    elicitation: [elicitation_hook],
    elicitation_result: [elicitation_result_hook],
  ),
  on_elicitation: ->(request : ClaudeAgent::ElicitationRequest) {
    puts "[on_elicitation] server=#{request.server_name} mode=#{request.mode}"
    if request.mode == "url"
      ClaudeAgent::ElicitationResponse.decline
    else
      ClaudeAgent::ElicitationResponse.accept({} of String => JSON::Any)
    end
  },
  max_turns: 3,
)

ClaudeAgent::AgentClient.open(options) do |client|
  puts "Requesting a tool flow that may trigger MCP elicitation..."
  puts

  client.query("Use any available MCP tool that requires authentication or user input, then summarize what happened.")

  client.each_response do |message|
    case message
    when ClaudeAgent::AssistantMessage
      print message.text if message.has_text?
    when ClaudeAgent::ElicitationCompleteMessage
      puts
      puts "[elicitation complete] #{message.mcp_server_name} id=#{message.elicitation_id}"
    when ClaudeAgent::PromptSuggestionMessage
      puts
      puts "[prompt suggestion] #{message.suggestion}"
    when ClaudeAgent::ResultMessage
      puts
      puts
      puts "Done: #{message.subtype}"
    end
  end
end
