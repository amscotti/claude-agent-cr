require "../src/claude-agent-cr"
require "file_utils"

# Example 37: Forward-compatible option surface
#
# This example configures a handful of options that newer Claude Code CLI
# releases understand:
#
#   * `skills`                            - enable SDK-managed skill access
#   * `SystemPromptPreset` + `exclude_dynamic_sections` - cache-friendly prompt
#   * `SystemPromptFile`                  - `--system-prompt-file <path>`
#   * `task_budget`                       - API-side token budget awareness
#   * `title`                             - fixed session title, no auto-gen
#   * `ThinkingConfig.adaptive`           - `--thinking adaptive` flag
#
# Each block prints the CLI args the SDK would generate so you can see the
# wire mapping even without a recent CLI. A final best-effort live run
# exercises one combination end-to-end; older CLIs will fail fast with
# "unknown option", which is caught and reported.

# ---------------------------------------------------------------------------
# Helper that builds an SDK client and pretty-prints the CLI argv it would
# hand to the Claude Code subprocess.
# ---------------------------------------------------------------------------
class ArgsInspector < ClaudeAgent::CLIClient
  def dump(label : String)
    puts "[#{label}] claude #{build_cli_args.join(' ')}"
  end

  # Re-export the private helper so the example can inspect CLI arg vectors
  # without actually spawning the subprocess.
  def build_cli_args : Array(String)
    super
  end
end

# ---------------------------------------------------------------------------
# 1. Skills option
# ---------------------------------------------------------------------------
skills_all = ClaudeAgent::AgentOptions.new(skills: "all")
skills_list = ClaudeAgent::AgentOptions.new(skills: ["git", "playwright"])
skills_suppressed = ClaudeAgent::AgentOptions.new(skills: [] of String)

puts "Skills option:"
ArgsInspector.new(skills_all).dump("skills=all")
ArgsInspector.new(skills_list).dump("skills=[git,playwright]")
ArgsInspector.new(skills_suppressed).dump("skills=[] (suppressed)")
puts

# ---------------------------------------------------------------------------
# 2. SystemPromptPreset with exclude_dynamic_sections
# ---------------------------------------------------------------------------
cacheable = ClaudeAgent::AgentOptions.new(
  system_prompt: ClaudeAgent::SystemPromptPreset.claude_code(
    "Focus on code review tasks.",
    true,
  ),
)
puts "SystemPromptPreset with exclude_dynamic_sections:"
ArgsInspector.new(cacheable).dump("preset+exclude_dynamic_sections")
puts

# ---------------------------------------------------------------------------
# 3. SystemPromptFile
# ---------------------------------------------------------------------------
prompt_path = "/tmp/claude-agent-cr-example-37-prompt.md"
File.write(prompt_path, "You are a concise assistant. Keep answers under 2 sentences.\n")

from_file = ClaudeAgent::AgentOptions.new(
  system_prompt: ClaudeAgent::SystemPromptFile.new(prompt_path),
)
puts "SystemPromptFile:"
ArgsInspector.new(from_file).dump("file-prompt")
puts

# ---------------------------------------------------------------------------
# 4. task_budget + title + adaptive thinking
# ---------------------------------------------------------------------------
budgeted = ClaudeAgent::AgentOptions.new(
  task_budget: ClaudeAgent::TaskBudget.new(120_000),
  title: "code-review session",
  thinking: ClaudeAgent::ThinkingConfig.adaptive,
)
puts "task_budget + title + adaptive thinking:"
ArgsInspector.new(budgeted).dump("budget+title+adaptive")
puts

# ---------------------------------------------------------------------------
# 5. Live sanity check: run a tiny query with the minimal combination that
#    should work on older CLIs too.
# ---------------------------------------------------------------------------
live_options = ClaudeAgent::AgentOptions.new(
  allowed_tools: [] of String,
  max_turns: 1,
  append_system_prompt: "Be brief.",
)

begin
  ClaudeAgent.query("Return the word OK.", live_options) do |message|
    case message
    when ClaudeAgent::AssistantMessage
      puts "[live] #{message.text}" if message.has_text?
    when ClaudeAgent::ResultMessage
      puts "[live] result: #{message.subtype}"
    end
  end
rescue ClaudeAgent::CLINotFoundError
  puts "Claude CLI not installed; skipped live call."
rescue ex
  puts "Live call skipped: #{ex.message}"
end

File.delete(prompt_path) if File.exists?(prompt_path)
