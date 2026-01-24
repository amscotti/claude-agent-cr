# Example 15: Subagents
#
# This example demonstrates how to define and use specialized subagents
# that can be spawned by the main agent to handle focused subtasks.

require "../src/claude-agent-cr"

# Define specialized agents for different tasks
agents = {
  "code-reviewer" => ClaudeAgent::AgentDefinition.new(
    description: "Expert code reviewer that analyzes code quality, identifies issues, and suggests improvements",
    prompt: "You are an expert code reviewer. Analyze the provided code for:\n" \
            "- Code quality and readability\n" \
            "- Potential bugs or issues\n" \
            "- Performance considerations\n" \
            "- Best practices adherence\n" \
            "Provide specific, actionable feedback.",
    name: "Code Reviewer",
    tools: ["Read", "Glob", "Grep"],
    model: "sonnet"
  ),
  "documentation-writer" => ClaudeAgent::AgentDefinition.new(
    description: "Technical writer that creates clear, comprehensive documentation",
    prompt: "You are a technical documentation writer. Create clear, well-structured " \
            "documentation that includes:\n" \
            "- Overview and purpose\n" \
            "- Usage examples\n" \
            "- API reference (if applicable)\n" \
            "- Common patterns and best practices",
    name: "Documentation Writer",
    tools: ["Read", "Glob"],
    model: "sonnet"
  ),
  "test-generator" => ClaudeAgent::AgentDefinition.new(
    description: "Creates comprehensive test cases for code",
    prompt: "You are a test engineer. Generate comprehensive test cases that cover:\n" \
            "- Happy path scenarios\n" \
            "- Edge cases\n" \
            "- Error conditions\n" \
            "- Boundary conditions\n" \
            "Use the project's existing test framework and conventions.",
    name: "Test Generator",
    tools: ["Read", "Glob", "Grep"],
    model: "haiku"
  ),
}

options = ClaudeAgent::AgentOptions.new(
  allowed_tools: ["Read", "Glob", "Grep", "Task"], # Task tool is needed for spawning subagents
  permission_mode: ClaudeAgent::PermissionMode::BypassPermissions,
  agents: agents,
  max_turns: 10
)

puts "Configured Subagents:"
puts "-" * 50
agents.each do |name, agent|
  puts "  #{name}: #{agent.description}"
end
puts "-" * 50
puts

begin
  ClaudeAgent::AgentClient.open(options) do |client|
    puts "Main Agent: Requesting code review using the code-reviewer subagent...\n"

    client.query(
      "Use the code-reviewer agent to review the hooks implementation in " \
      "src/claude_agent/hooks.cr and provide feedback on the code quality."
    )

    client.each_response do |message|
      case message
      when ClaudeAgent::AssistantMessage
        prefix = message.from_subagent? ? "[Subagent] " : ""

        # Show tool uses
        message.tool_uses.each do |tool|
          puts "#{prefix}[Tool: #{tool}]"
        end

        # Show text content
        if message.has_text?
          puts "#{prefix}#{message.text}"
        end
      when ClaudeAgent::ResultMessage
        puts "\n" + "=" * 50
        puts "Task completed in #{message.num_turns} turns"
        if cost = message.total_cost_usd
          puts "Total cost: $#{cost.round(6)}"
        end
      end
    end
  end
rescue ex
  puts "Error: #{ex.message}"
end
