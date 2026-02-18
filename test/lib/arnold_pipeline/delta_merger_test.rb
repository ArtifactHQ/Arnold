require "test_helper"
require "arnold_pipeline/delta_merger"

module ArnoldPipeline
  class DeltaMergerTest < ActiveSupport::TestCase
    cover "ArnoldPipeline::DeltaMerger*"

    setup do
      @merger = DeltaMerger.new(logger: Logger.new(File::NULL))

      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.openspec_enabled = false
      end

      @pipeline_run = PipelineRun.create!(nl_input: "Build a test app", status: :executing)
      @spec = @pipeline_run.create_specification!(content: "# Test Spec\n\nOriginal content", version: 1)
    end

    teardown do
      ArnoldPipeline.reset_configuration!
    end

    # --- apply! tests ---

    test "apply! merges deltas and creates revision with correct change_source" do
      deltas = [
        { "operation" => "added", "section" => "Auth", "content" => "### Requirement: Login\nNew.", "rationale" => "Missing feature" }
      ]

      result = @merger.apply!(spec: @spec, raw_deltas: deltas, change_source: "iterate_spec")

      assert_equal "append", result[:merge_strategy]
      assert_equal 1, result[:delta_count]
      assert_equal 2, result[:new_version]

      revision = @spec.spec_revisions.last
      assert_equal "iterate_spec", revision.change_source
      assert_equal 2, revision.version
    end

    test "apply! with user_iterate change_source creates revision" do
      deltas = [
        { "operation" => "added", "section" => "UI", "content" => "### Requirement: Dark Mode\nSupport dark mode.", "rationale" => "User request" }
      ]

      result = @merger.apply!(spec: @spec, raw_deltas: deltas, change_source: "user_iterate")

      revision = @spec.spec_revisions.last
      assert_equal "user_iterate", revision.change_source
      assert_equal 1, result[:delta_count]
    end

    test "apply! persists deltas when iteration is provided" do
      iteration = @pipeline_run.iterations.create!(
        number: 1, decision: "iterate_spec", confidence: 60, reasoning: "Test"
      )

      deltas = [
        { "operation" => "added", "section" => "Auth", "content" => "### Requirement: Signup\nNew.", "rationale" => "Missing" }
      ]

      @merger.apply!(spec: @spec, raw_deltas: deltas, change_source: "iterate_spec", pipeline_run: @pipeline_run, iteration: iteration)

      assert_equal 1, @spec.spec_deltas.count
      delta = @spec.spec_deltas.first
      assert_equal "added", delta.operation
      assert_equal "Auth", delta.section
      assert_equal iteration, delta.iteration
    end

    test "apply! skips persist_deltas! when iteration is nil" do
      deltas = [
        { "operation" => "added", "section" => "Auth", "content" => "### Requirement: Signup\nNew.", "rationale" => "Missing" }
      ]

      @merger.apply!(spec: @spec, raw_deltas: deltas, change_source: "user_iterate")

      assert_equal 0, @spec.spec_deltas.count
      # But revision and content merge should still happen
      assert_equal 1, @spec.spec_revisions.count
      assert_includes @spec.reload.content, "Signup"
    end

    # --- append_deltas! tests ---

    test "append_deltas! adds content for additions" do
      deltas = [
        { "operation" => "added", "section" => "Auth", "content" => "### Requirement: Password Reset\nUsers can reset.", "rationale" => "Missing" }
      ]

      @merger.append_deltas!(@spec, deltas)

      assert_includes @spec.reload.content, "## Spec Iteration"
      assert_includes @spec.content, "Password Reset"
      assert_equal 2, @spec.version
    end

    test "append_deltas! adds after_content for modifications" do
      deltas = [
        { "operation" => "modified", "section" => "Auth", "requirement" => "Login", "before_content" => "old", "after_content" => "### Requirement: Login\nUpdated login flow.", "rationale" => "Ambiguous" }
      ]

      @merger.append_deltas!(@spec, deltas)

      assert_includes @spec.reload.content, "Updated login flow"
    end

    test "append_deltas! handles removed operations" do
      deltas = [
        { "operation" => "removed", "section" => "Auth", "requirement" => "SMS Verify", "rationale" => "Out of scope" }
      ]

      @merger.append_deltas!(@spec, deltas)

      content = @spec.reload.content
      assert_includes content, "REMOVED: SMS Verify"
      assert_includes content, "Out of scope"
    end

    test "append_deltas! handles mixed operations" do
      deltas = [
        { "operation" => "added", "section" => "Auth", "content" => "### Requirement: OAuth\nOAuth support.", "rationale" => "New" },
        { "operation" => "modified", "section" => "Auth", "requirement" => "Login", "before_content" => "old", "after_content" => "Updated login.", "rationale" => "Clarify" },
        { "operation" => "removed", "section" => "UI", "requirement" => "Legacy Theme", "rationale" => "Deprecated" }
      ]

      @merger.append_deltas!(@spec, deltas)

      content = @spec.reload.content
      assert_includes content, "OAuth support"
      assert_includes content, "Updated login"
      assert_includes content, "REMOVED: Legacy Theme"
    end

    # --- persist_deltas! tests ---

    test "persist_deltas! creates SpecDelta records" do
      iteration = @pipeline_run.iterations.create!(
        number: 1, decision: "iterate_spec", confidence: 60, reasoning: "Test"
      )

      deltas = [
        { "operation" => "added", "section" => "Auth", "content" => "New content", "rationale" => "Missing" },
        { "operation" => "modified", "section" => "UI", "requirement" => "Theme", "before_content" => "old", "after_content" => "new", "rationale" => "Clarify" }
      ]

      @merger.persist_deltas!(@spec, iteration, deltas)

      assert_equal 2, @spec.spec_deltas.count

      added = @spec.spec_deltas.additions.first
      assert_equal "Auth", added.section
      assert_equal "New content", added.after_content

      modified = @spec.spec_deltas.modifications.first
      assert_equal "Theme", modified.requirement
      assert_equal "old", modified.before_content
      assert_equal "new", modified.after_content
    end

    # --- snapshot_revision! tests ---

    test "snapshot_revision! creates SpecRevision record" do
      @spec.update!(version: 2, content: "Updated content")

      deltas = [
        { "operation" => "added", "section" => "Auth", "requirement" => nil, "rationale" => "Missing" },
        { "operation" => "modified", "section" => "UI", "requirement" => "Theme", "rationale" => "Clarify" }
      ]

      @merger.snapshot_revision!(@spec, deltas, "iterate_spec")

      assert_equal 1, @spec.spec_revisions.count
      revision = @spec.spec_revisions.first
      assert_equal 2, revision.version
      assert_equal "Updated content", revision.content
      assert_equal "iterate_spec", revision.change_source
      assert_includes revision.delta_summary, "ADDED: Auth > new requirement"
      assert_includes revision.delta_summary, "MODIFIED: UI > Theme"
    end

    test "snapshot_revision! handles failure gracefully" do
      # Force a validation error by using an invalid change_source
      deltas = [{ "operation" => "added", "section" => "X", "rationale" => "Y" }]

      # Create a spec with version 0 which will fail the version > 0 validation on revision
      @spec.update_column(:version, 0)

      # Should not raise — logs a warning instead
      assert_nothing_raised do
        @merger.snapshot_revision!(@spec, deltas, "iterate_spec")
      end
    end

    # --- openspec merge path tests ---

    test "attempts openspec merge when config enabled" do
      ArnoldPipeline.configure { |c| c.openspec_enabled = true }

      iteration = @pipeline_run.iterations.create!(
        number: 1, decision: "iterate_spec", confidence: 60, reasoning: "Test"
      )

      deltas = [
        { "operation" => "added", "section" => "Auth", "content" => "### Requirement: New\nShall.", "rationale" => "Missing" }
      ]

      # Stub the OpenSpec bridge to simulate a successful merge
      merged_content = "# Merged Spec\n\nMerged by OpenSpec"
      bridge = stub("bridge")
      bridge.stubs(:write_spec!)
      bridge.stubs(:write_delta_and_merge!).returns(merged_content)

      OpenspecBridge.stubs(:with_workspace).yields(bridge)

      @merger.apply!(spec: @spec, raw_deltas: deltas, change_source: "iterate_spec", pipeline_run: @pipeline_run, iteration: iteration)

      assert_includes @spec.reload.content, "Merged by OpenSpec"
    end

    test "falls back to append when openspec merge fails" do
      ArnoldPipeline.configure { |c| c.openspec_enabled = true }

      deltas = [
        { "operation" => "added", "section" => "Auth", "content" => "### Requirement: Fallback\nFallback content.", "rationale" => "Test" }
      ]

      OpenspecBridge.stubs(:with_workspace).raises(RuntimeError, "CLI not found")

      @merger.apply!(spec: @spec, raw_deltas: deltas, change_source: "iterate_spec")

      # Should fall back to append
      assert_includes @spec.reload.content, "Fallback content"
      assert_includes @spec.content, "## Spec Iteration"
    end

    test "falls back to append when openspec merge returns nil" do
      ArnoldPipeline.configure { |c| c.openspec_enabled = true }

      deltas = [
        { "operation" => "added", "section" => "Auth", "content" => "### Requirement: Nil\nNil merge.", "rationale" => "Test" }
      ]

      bridge = stub("bridge")
      bridge.stubs(:write_spec!)
      bridge.stubs(:write_delta_and_merge!).returns(nil)

      OpenspecBridge.stubs(:with_workspace).yields(bridge)

      @merger.apply!(spec: @spec, raw_deltas: deltas, change_source: "iterate_spec")

      # Should fall back to append since merge returned nil
      assert_includes @spec.reload.content, "## Spec Iteration"
      assert_includes @spec.content, "Nil merge"
    end

    test "openspec merge uses pipeline_run iteration for change_name" do
      ArnoldPipeline.configure { |c| c.openspec_enabled = true }

      iteration = @pipeline_run.iterations.create!(
        number: 3, decision: "iterate_spec", confidence: 60, reasoning: "Test"
      )

      deltas = [
        { "operation" => "added", "section" => "Auth", "content" => "### Requirement: New\nShall.", "rationale" => "Missing" }
      ]

      bridge = stub("bridge")
      bridge.stubs(:write_spec!)
      bridge.expects(:write_delta_and_merge!).with { |kwargs|
        kwargs[:change_name] == "iteration-3"
      }.returns("# Merged")

      OpenspecBridge.stubs(:with_workspace).yields(bridge)

      @merger.merge_deltas!(@spec, deltas, @pipeline_run)
    end

    test "openspec merge generates change_name without pipeline_run" do
      ArnoldPipeline.configure { |c| c.openspec_enabled = true }

      deltas = [
        { "operation" => "added", "section" => "Auth", "content" => "### Requirement: New\nShall.", "rationale" => "Missing" }
      ]

      bridge = stub("bridge")
      bridge.stubs(:write_spec!)
      bridge.expects(:write_delta_and_merge!).with { |kwargs|
        kwargs[:change_name].start_with?("user-iterate-")
      }.returns("# Merged")

      OpenspecBridge.stubs(:with_workspace).yields(bridge)

      @merger.merge_deltas!(@spec, deltas, nil)
    end
  end
end
