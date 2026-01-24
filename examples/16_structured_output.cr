# Example 16: Structured Output
#
# This example demonstrates how to request structured JSON output
# from the agent using the output_format option with the Schema helper.

require "../src/claude-agent-cr"

# Define a JSON schema using the Schema helper (recommended)
output_schema = ClaudeAgent::Schema.object({
  "summary" => ClaudeAgent::Schema.string("Brief summary of the code"),
  "issues"  => ClaudeAgent::Schema.array(
    ClaudeAgent::Schema.object({
      "severity"    => ClaudeAgent::Schema.enum(["low", "medium", "high", "critical"]),
      "description" => ClaudeAgent::Schema.string("Description of the issue"),
      "line"        => ClaudeAgent::Schema.integer("Line number where issue occurs"),
    }, required: ["severity", "description"])
  ),
  "suggestions" => ClaudeAgent::Schema.array(
    ClaudeAgent::Schema.string("Improvement suggestion")
  ),
  "quality_score" => ClaudeAgent::Schema.integer(
    "Code quality score from 1-10",
    minimum: 1,
    maximum: 10
  ),
}, required: ["summary", "issues", "suggestions", "quality_score"])

# Alternative: You can also use a plain hash (auto-converted internally)
# output_schema = {
#   "type" => "object",
#   "properties" => {
#     "summary" => {"type" => "string", "description" => "Brief summary"},
#     "quality_score" => {"type" => "integer", "minimum" => 1, "maximum" => 10},
#   },
#   "required" => ["summary", "quality_score"],
# }

options = ClaudeAgent::AgentOptions.new(
  allowed_tools: ["Read"],
  permission_mode: ClaudeAgent::PermissionMode::BypassPermissions,
  allow_dangerously_skip_permissions: true,
  # Use the factory method with optional name and description
  output_format: ClaudeAgent::OutputFormat.json_schema(
    output_schema,
    name: "CodeReview",
    description: "A structured code review response with issues, suggestions, and quality score"
  ),
  max_turns: 3
)

begin
  puts "Requesting structured code review output..."
  puts "-" * 50

  ClaudeAgent.query(
    "Review the file src/claude_agent/version.cr and provide a structured code review.",
    options
  ) do |message|
    case message
    when ClaudeAgent::AssistantMessage
      puts message.text unless message.text.empty?
    when ClaudeAgent::ResultMessage
      if structured = message.structured_output
        puts "\nStructured Output Received:"
        puts "-" * 50
        puts structured.to_pretty_json
      end
    end
  end
rescue ex
  puts "Error: #{ex.message}"
end
