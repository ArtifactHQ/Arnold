require "test_helper"

module ArnoldPipeline
  class SpecificationTest < ActiveSupport::TestCase
    cover "ArnoldPipeline::Specification*"

    setup do
      @run = PipelineRun.create!(nl_input: "Build a todo app")
    end

    # --- Validations ---

    test "valid specification" do
      spec = @run.build_specification(content: "# Todo App Spec", version: 1)
      assert spec.valid?
    end

    test "requires content" do
      spec = @run.build_specification(content: nil, version: 1)
      assert_not spec.valid?
      assert_includes spec.errors[:content], "can't be blank"
    end

    test "rejects blank content" do
      spec = @run.build_specification(content: "", version: 1)
      assert_not spec.valid?
      assert_includes spec.errors[:content], "can't be blank"
    end

    test "requires version" do
      spec = @run.build_specification(content: "# Spec", version: nil)
      assert_not spec.valid?
      assert_includes spec.errors[:version], "can't be blank"
    end

    test "version must be numeric" do
      spec = @run.build_specification(content: "# Spec", version: "abc")
      assert_not spec.valid?
      assert_includes spec.errors[:version], "is not a number"
    end

    test "version must be greater than 0" do
      spec = @run.build_specification(content: "# Spec", version: 0)
      assert_not spec.valid?
      assert_includes spec.errors[:version], "must be greater than 0"
    end

    test "version 1 is valid" do
      spec = @run.build_specification(content: "# Spec", version: 1)
      assert spec.valid?
    end

    # --- Associations ---

    test "belongs to pipeline_run" do
      spec = @run.create_specification!(content: "# Spec", version: 1)
      assert_equal @run, spec.pipeline_run
    end

    test "has_many spec_deltas" do
      spec = @run.create_specification!(content: "# Spec", version: 1)
      iteration = @run.iterations.create!(number: 1, decision: "iterate_spec", confidence: 80)
      delta = spec.spec_deltas.create!(
        iteration: iteration,
        operation: "added",
        section: "Auth",
        after_content: "new auth"
      )

      assert_includes spec.reload.spec_deltas, delta
    end

    test "has_many spec_revisions" do
      spec = @run.create_specification!(content: "# Spec", version: 1)
      revision = spec.spec_revisions.create!(version: 1, content: "# Spec v1")

      assert_includes spec.reload.spec_revisions, revision
    end

    test "destroys dependent spec_deltas" do
      spec = @run.create_specification!(content: "# Spec", version: 1)
      iteration = @run.iterations.create!(number: 1, decision: "iterate_spec", confidence: 80)
      spec.spec_deltas.create!(
        iteration: iteration,
        operation: "added",
        section: "Auth",
        after_content: "new"
      )

      assert_difference "SpecDelta.count", -1 do
        spec.destroy!
      end
    end

    test "destroys dependent spec_revisions" do
      spec = @run.create_specification!(content: "# Spec", version: 1)
      spec.spec_revisions.create!(version: 1, content: "# Spec v1")

      assert_difference "SpecRevision.count", -1 do
        spec.destroy!
      end
    end

    # --- Pipeline run association ---

    test "pipeline_run has_one specification" do
      spec = @run.create_specification!(content: "# Spec", version: 1)
      assert_equal spec, @run.reload.specification
    end
  end
end
