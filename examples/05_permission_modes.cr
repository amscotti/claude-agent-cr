# Example 05: Permission Modes
#
# This example demonstrates the different permission modes available:
# - Default: Normal permission prompts
# - AcceptEdits: Auto-approve file edits
# - Plan: Planning mode, no execution
# - BypassPermissions: Bypass all permission checks

require "../src/claude-agent-cr"

def run_with_mode(mode : ClaudeAgent::PermissionMode, description : String)
  puts "=" * 50
  puts "Mode: #{mode} - #{description}"
  puts "=" * 50

  options = ClaudeAgent::AgentOptions.new(
    permission_mode: mode,
    allowed_tools: ["Read", "Glob"],
    max_turns: 3
  )

  begin
    ClaudeAgent.query("List the Crystal source files in the src directory", options) do |message|
      if message.is_a?(ClaudeAgent::AssistantMessage)
        print message.text
      elsif message.is_a?(ClaudeAgent::PermissionRequest)
        puts "\n[Permission requested for: #{message.tool_name}]"
      end
    end
    puts "\n"
  rescue ex
    puts "Error: #{ex.message}\n"
  end
end

# Demonstrate different modes
run_with_mode(ClaudeAgent::PermissionMode::Default, "Prompts for permissions")
run_with_mode(ClaudeAgent::PermissionMode::BypassPermissions, "No permission prompts")
