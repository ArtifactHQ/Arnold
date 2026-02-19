require "test_helper"

module ArnoldPipeline
  class SpecDeltaTest < ActiveSupport::TestCase
    cover "ArnoldPipeline::SpecDelta*"

    setup do
      @run = PipelineRun.create!(nl_input: "Build a todo app")
      @spec = @run.create_specification!(content: "# Spec", version: 1)
      @iteration = @run.iterations.create!(number: 1, decision: "iterate_spec", confidence: 80)
    end

    test "valid added delta" do
      delta = @spec.spec_deltas.build(
        iteration: @iteration,
        operation: "added",
        section: "Authentication",
        after_content: "### Requirement: Password Reset\nUsers SHALL be able to reset passwords."
      )
      assert delta.valid?
    end

    test "valid modified delta" do
      delta = @spec.spec_deltas.build(
        iteration: @iteration,
        operation: "modified",
        section: "Authentication",
        requirement: "User Login",
        before_content: "### Requirement: User Login\nOld content.",
        after_content: "### Requirement: User Login\nNew content.",
        rationale: "Spec was ambiguous"
      )
      assert delta.valid?
    end

    test "valid removed delta" do
      delta = @spec.spec_deltas.build(
        iteration: @iteration,
        operation: "removed",
        section: "Authentication",
        requirement: "SMS Verification",
        rationale: "Out of scope"
      )
      assert delta.valid?
    end

    test "rejects invalid operation" do
      delta = @spec.spec_deltas.build(
        iteration: @iteration,
        operation: "invalid",
        section: "Authentication"
      )
      assert_not delta.valid?
      assert_includes delta.errors[:operation], "is not included in the list"
    end

    test "requires section" do
      delta = @spec.spec_deltas.build(
        iteration: @iteration,
        operation: "added",
        section: nil,
        after_content: "content"
      )
      assert_not delta.valid?
      assert_includes delta.errors[:section], "can't be blank"
    end

    test "requires requirement for modified operation" do
      delta = @spec.spec_deltas.build(
        iteration: @iteration,
        operation: "modified",
        section: "Auth",
        requirement: nil,
        before_content: "old",
        after_content: "new"
      )
      assert_not delta.valid?
      assert_includes delta.errors[:requirement], "can't be blank"
    end

    test "requires requirement for removed operation" do
      delta = @spec.spec_deltas.build(
        iteration: @iteration,
        operation: "removed",
        section: "Auth",
        requirement: nil
      )
      assert_not delta.valid?
      assert_includes delta.errors[:requirement], "can't be blank"
    end

    test "does not require requirement for added operation" do
      delta = @spec.spec_deltas.build(
        iteration: @iteration,
        operation: "added",
        section: "Auth",
        requirement: nil,
        after_content: "new content"
      )
      assert delta.valid?
    end

    test "requires after_content for added operation" do
      delta = @spec.spec_deltas.build(
        iteration: @iteration,
        operation: "added",
        section: "Auth",
        after_content: nil
      )
      assert_not delta.valid?
      assert_includes delta.errors[:after_content], "can't be blank"
    end

    test "requires before_content for modified operation" do
      delta = @spec.spec_deltas.build(
        iteration: @iteration,
        operation: "modified",
        section: "Auth",
        requirement: "Login",
        before_content: nil,
        after_content: "new"
      )
      assert_not delta.valid?
      assert_includes delta.errors[:before_content], "can't be blank"
    end

    test "does not require after_content for removed operation" do
      delta = @spec.spec_deltas.build(
        iteration: @iteration,
        operation: "removed",
        section: "Auth",
        requirement: "SMS Verify"
      )
      assert delta.valid?
    end

    test "additions scope" do
      @spec.spec_deltas.create!(iteration: @iteration, operation: "added", section: "Auth", after_content: "new")
      @spec.spec_deltas.create!(iteration: @iteration, operation: "removed", section: "Auth", requirement: "Old")

      assert_equal 1, @spec.spec_deltas.additions.count
    end

    test "modifications scope" do
      @spec.spec_deltas.create!(iteration: @iteration, operation: "modified", section: "Auth", requirement: "Login", before_content: "old", after_content: "new")

      assert_equal 1, @spec.spec_deltas.modifications.count
    end

    test "removals scope" do
      @spec.spec_deltas.create!(iteration: @iteration, operation: "removed", section: "Auth", requirement: "SMS")

      assert_equal 1, @spec.spec_deltas.removals.count
    end

    test "by_section scope" do
      @spec.spec_deltas.create!(iteration: @iteration, operation: "added", section: "Auth", after_content: "new")
      @spec.spec_deltas.create!(iteration: @iteration, operation: "added", section: "Payments", after_content: "pay")

      assert_equal 1, @spec.spec_deltas.by_section("Auth").count
      assert_equal 1, @spec.spec_deltas.by_section("Payments").count
    end

    test "belongs to specification" do
      delta = @spec.spec_deltas.create!(iteration: @iteration, operation: "added", section: "Auth", after_content: "new")
      assert_equal @spec, delta.specification
    end

    test "belongs to iteration" do
      delta = @spec.spec_deltas.create!(iteration: @iteration, operation: "added", section: "Auth", after_content: "new")
      assert_equal @iteration, delta.iteration
    end

    test "specification has_many spec_deltas with dependent destroy" do
      @spec.spec_deltas.create!(iteration: @iteration, operation: "added", section: "Auth", after_content: "new")
      assert_equal 1, @spec.spec_deltas.count

      @spec.destroy!
      assert_equal 0, SpecDelta.where(specification_id: @spec.id).count
    end

    test "iteration has_many spec_deltas with dependent destroy" do
      @spec.spec_deltas.create!(iteration: @iteration, operation: "added", section: "Auth", after_content: "new")

      @iteration.destroy!
      assert_equal 0, SpecDelta.where(iteration_id: @iteration.id).count
    end
  end
end
