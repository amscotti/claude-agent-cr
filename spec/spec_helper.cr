require "spec"
require "../src/claude-agent-cr"

module SpecHelpers
  extend self

  def live_e2e_enabled? : Bool
    ENV["CLAUDE_AGENT_RUN_E2E"]? == "1"
  end
end
