require "test_helper"
require "arnold_pipeline/openspec_bridge"

module ArnoldPipeline
  class OpenspecBridgeTest < ActiveSupport::TestCase
    setup do
      ArnoldPipeline.configure do |c|
        c.openspec_enabled = true
        c.openspec_cli_path = "openspec"
      end
    end

    teardown do
      ArnoldPipeline.reset_configuration!
    end

    test "scaffold! creates required directory structure" do
      Dir.mktmpdir("arnold_test_") do |dir|
        bridge = OpenspecBridge.new(working_dir: dir, logger: Logger.new(File::NULL))
        bridge.scaffold!

        assert File.directory?(File.join(dir, "openspec", "specs"))
        assert File.directory?(File.join(dir, "openspec", "changes"))
        assert File.exist?(File.join(dir, "openspec", "config.yaml"))

        config = File.read(File.join(dir, "openspec", "config.yaml"))
        assert_equal "schema: spec-driven\n", config
      end
    end

    test "scaffold! does not overwrite existing config" do
      Dir.mktmpdir("arnold_test_") do |dir|
        config_path = File.join(dir, "openspec", "config.yaml")
        FileUtils.mkdir_p(File.dirname(config_path))
        File.write(config_path, "custom: true\n")

        bridge = OpenspecBridge.new(working_dir: dir, logger: Logger.new(File::NULL))
        bridge.scaffold!

        assert_equal "custom: true\n", File.read(config_path)
      end
    end

    test "write_spec! writes specification content to spec.md" do
      Dir.mktmpdir("arnold_test_") do |dir|
        bridge = OpenspecBridge.new(working_dir: dir, logger: Logger.new(File::NULL))
        bridge.scaffold!

        spec = stub(content: "## Purpose\nTest spec.\n\n## Requirements\n### Requirement: Login\nUsers SHALL log in.")
        bridge.write_spec!(spec)

        written = File.read(File.join(dir, "openspec", "specs", "app", "spec.md"))
        assert_includes written, "## Purpose"
        assert_includes written, "### Requirement: Login"
      end
    end

    test "with_workspace creates and cleans up temp directory" do
      captured_dir = nil

      OpenspecBridge.with_workspace(logger: Logger.new(File::NULL)) do |bridge|
        captured_dir = bridge.working_dir
        assert File.directory?(captured_dir)
        assert File.directory?(File.join(captured_dir, "openspec", "specs"))
      end

      assert_not File.exist?(captured_dir), "Temp directory should be cleaned up"
    end

    test "with_workspace cleans up even on exception" do
      captured_dir = nil

      assert_raises(RuntimeError) do
        OpenspecBridge.with_workspace(logger: Logger.new(File::NULL)) do |bridge|
          captured_dir = bridge.working_dir
          raise "test error"
        end
      end

      assert_not File.exist?(captured_dir), "Temp directory should be cleaned up after error"
    end

    test "format_delta_markdown produces ADDED section" do
      bridge = OpenspecBridge.new(working_dir: "/tmp", logger: Logger.new(File::NULL))
      deltas = [
        {
          "operation" => "added",
          "section" => "Auth",
          "content" => "### Requirement: Password Reset\nUsers SHALL reset passwords.\n\n#### Scenario: Successful Reset\n- GIVEN a user\n- WHEN they request reset\n- THEN email is sent"
        }
      ]

      md = bridge.send(:format_delta_markdown, deltas)
      assert_includes md, "## ADDED Requirements"
      assert_includes md, "### Requirement: Password Reset"
    end

    test "format_delta_markdown produces MODIFIED section" do
      bridge = OpenspecBridge.new(working_dir: "/tmp", logger: Logger.new(File::NULL))
      deltas = [
        {
          "operation" => "modified",
          "section" => "Auth",
          "requirement" => "User Login",
          "before_content" => "old",
          "after_content" => "### Requirement: User Login\nUsers SHALL authenticate with OAuth.\n\n#### Scenario: OAuth Login\n- GIVEN a user\n- WHEN they click OAuth\n- THEN authenticated"
        }
      ]

      md = bridge.send(:format_delta_markdown, deltas)
      assert_includes md, "## MODIFIED Requirements"
      assert_includes md, "### Requirement: User Login"
    end

    test "format_delta_markdown produces REMOVED section" do
      bridge = OpenspecBridge.new(working_dir: "/tmp", logger: Logger.new(File::NULL))
      deltas = [
        {
          "operation" => "removed",
          "section" => "Auth",
          "requirement" => "SMS Verify",
          "rationale" => "Out of scope"
        }
      ]

      md = bridge.send(:format_delta_markdown, deltas)
      assert_includes md, "## REMOVED Requirements"
      assert_includes md, "### Requirement: SMS Verify"
    end

    test "format_delta_markdown handles mixed operations" do
      bridge = OpenspecBridge.new(working_dir: "/tmp", logger: Logger.new(File::NULL))
      deltas = [
        { "operation" => "added", "section" => "Auth", "content" => "### Requirement: New\nShall.\n\n#### Scenario: S1\n- GIVEN x\n- WHEN y\n- THEN z" },
        { "operation" => "modified", "section" => "Auth", "requirement" => "Login", "after_content" => "### Requirement: Login\nUpdated.\n\n#### Scenario: S2\n- GIVEN a\n- WHEN b\n- THEN c" },
        { "operation" => "removed", "section" => "Auth", "requirement" => "Old", "rationale" => "Gone" }
      ]

      md = bridge.send(:format_delta_markdown, deltas)
      assert_includes md, "## ADDED Requirements"
      assert_includes md, "## MODIFIED Requirements"
      assert_includes md, "## REMOVED Requirements"
    end

    test "write_delta_and_merge! returns nil when validation fails" do
      Dir.mktmpdir("arnold_test_") do |dir|
        bridge = OpenspecBridge.new(working_dir: dir, logger: Logger.new(File::NULL))
        bridge.scaffold!

        spec = stub(content: "## Purpose\nTest.\n\n## Requirements\n### Requirement: Login\nShall.\n\n#### Scenario: S1\n- GIVEN x\n- WHEN y\n- THEN z")
        bridge.write_spec!(spec)

        # Delta with no scenarios should fail validation
        deltas = [
          { "operation" => "added", "section" => "Auth", "content" => "### Requirement: Bad\nNo scenarios here." }
        ]

        result = bridge.write_delta_and_merge!(change_name: "test", deltas: deltas)
        assert_nil result
      end
    end

    test "write_delta_and_merge! successfully merges valid ADDED delta" do
      skip "openspec CLI not available" unless system("which openspec > /dev/null 2>&1")

      Dir.mktmpdir("arnold_test_") do |dir|
        bridge = OpenspecBridge.new(working_dir: dir, logger: Logger.new(File::NULL))
        bridge.scaffold!

        spec_content = <<~MD
          ## Purpose
          Test application spec.

          ## Requirements

          ### Requirement: User Login
          Users SHALL be able to authenticate.

          #### Scenario: Successful Login
          - GIVEN a registered user
          - WHEN they submit valid credentials
          - THEN they are authenticated
        MD

        spec = stub(content: spec_content)
        bridge.write_spec!(spec)

        deltas = [
          {
            "operation" => "added",
            "section" => "Authentication",
            "content" => "### Requirement: Password Reset\nUsers SHALL be able to reset their password via email.\n\n#### Scenario: Successful Reset\n- GIVEN a registered user\n- WHEN they request a password reset\n- THEN a reset email is sent",
            "rationale" => "Missing feature"
          }
        ]

        result = bridge.write_delta_and_merge!(change_name: "iteration-1", deltas: deltas)

        assert_not_nil result, "Expected merged content, got nil"
        assert_includes result, "User Login"
        assert_includes result, "Password Reset"
      end
    end

    test "write_delta_and_merge! returns nil when CLI is not found" do
      ArnoldPipeline.configure { |c| c.openspec_cli_path = "/nonexistent/openspec" }

      Dir.mktmpdir("arnold_test_") do |dir|
        bridge = OpenspecBridge.new(working_dir: dir, logger: Logger.new(File::NULL))
        bridge.scaffold!

        spec = stub(content: "## Purpose\nTest.\n\n## Requirements\n### Requirement: Login\nShall.\n\n#### Scenario: S\n- GIVEN x\n- WHEN y\n- THEN z")
        bridge.write_spec!(spec)

        deltas = [{ "operation" => "added", "section" => "Auth", "content" => "### Requirement: New\nShall.\n\n#### Scenario: S\n- GIVEN x\n- WHEN y\n- THEN z" }]

        result = bridge.write_delta_and_merge!(change_name: "test", deltas: deltas)
        assert_nil result
      end
    end
  end
end
