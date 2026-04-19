require "./spec_helper"

# Meta tests: version sync across shard.yml, VERSION constant, README
# install snippet, and CHANGELOG. Mirrors Python's `test_changelog.py`
# and `test_build_wheel.py`-style integrity checks.
#
# These catch the class of "forgot to bump something when releasing"
# bugs where the SDK reports one version in code and a different
# version in docs.

ROOT             = File.expand_path("..", __DIR__)
SHARD_YML        = File.join(ROOT, "shard.yml")
VERSION_CR       = File.join(ROOT, "src", "claude_agent", "version.cr")
README_MD        = File.join(ROOT, "README.md")
CHANGELOG_SOURCE = File.join(ROOT, "README.md")

describe "Meta: version + CHANGELOG health" do
  describe "version synchronization" do
    it "VERSION constant matches shard.yml version" do
      shard = File.read(SHARD_YML)
      shard_version = shard.match(/^version:\s*(\S+)/m).try(&.[1])
      shard_version.should_not be_nil

      ClaudeAgent::VERSION.should eq(shard_version)
    end

    it "README install snippet references a version compatible with VERSION" do
      readme = File.read(README_MD)
      # Match forms like: version: ~> 0.5.2   or   version: "~> 0.5.2"
      match = readme.match(/version:\s*"?~>\s*(\d+\.\d+\.\d+)"?/)
      match.should_not be_nil

      match.try do |captures|
        installed = captures[1]
        # We accept ~> X.Y.Z matching the current VERSION exactly or
        # a version in the same X.Y series (since ~> 0.5.2 matches 0.5.*).
        current_parts = ClaudeAgent::VERSION.split('.')
        installed_parts = installed.split('.')

        current_parts[0].should eq(installed_parts[0])
        current_parts[1].should eq(installed_parts[1])
      end
    end
  end

  describe "CHANGELOG health" do
    it "README has a changelog entry for the current VERSION" do
      readme = File.read(README_MD)
      expected_heading = "### #{ClaudeAgent::VERSION}"
      readme.includes?(expected_heading).should be_true
    end

    it "README changelog lists the current version before any older version" do
      readme = File.read(README_MD)
      current_idx = readme.index("### #{ClaudeAgent::VERSION}")
      current_idx.should_not be_nil

      # Walk each `### N.N.N` heading and ensure the current VERSION is
      # the first one below the main "## Changelog" banner. Prevents the
      # "forgot to move the new entry to the top" class of mistake.
      current_idx.try do |_idx|
        changelog_idx = readme.index("## Changelog")
        changelog_idx.should_not be_nil

        changelog_idx.try do |start|
          # The first semver-looking heading below "## Changelog" should
          # be the current VERSION.
          remaining = readme[start..]
          first_version_match = remaining.match(/^###\s+(\d+\.\d+\.\d+)/m)
          first_version_match.should_not be_nil
          first_version_match.try do |captures|
            captures[1].should eq(ClaudeAgent::VERSION)
          end
        end
      end
    end

    it "CHANGELOG entries are listed in descending version order" do
      readme = File.read(README_MD)
      changelog_start = readme.index("## Changelog") || 0
      section = readme[changelog_start..]

      versions = section.scan(/^###\s+(\d+\.\d+\.\d+)/m).map do |match|
        match[1].split('.').map(&.to_i)
      end

      versions.size.should be >= 2
      versions.each_cons(2) do |pair|
        # pair[0] must be >= pair[1] when compared as [major, minor, patch].
        compare = pair[0] <=> pair[1]
        (compare && compare >= 0).should be_true
      end
    end
  end

  describe "llms.txt sync" do
    it "llms.txt has a note for the current VERSION" do
      llms_path = File.join(ROOT, "llms.txt")
      if File.exists?(llms_path)
        llms = File.read(llms_path)
        llms.includes?("**#{ClaudeAgent::VERSION}**").should be_true
      end
    end
  end
end
