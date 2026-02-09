require "test_helper"

module ArnoldPipeline
  class IterationTest < ActiveSupport::TestCase
    setup do
      @run = PipelineRun.create!(nl_input: "Build a todo app")
    end

    test "requires number" do
      iteration = @run.iterations.build(number: nil)
      assert_not iteration.valid?
      assert_includes iteration.errors[:number], "can't be blank"
    end

    test "number must be greater than 0 and within configured max" do
      assert_not @run.iterations.build(number: 0).valid?
      assert @run.iterations.build(number: 1).valid?
      assert @run.iterations.build(number: 3).valid?
      assert_not @run.iterations.build(number: 4).valid?
    end

    test "number respects configured max_iterations" do
      ArnoldPipeline.configure { |c| c.max_iterations = 5 }
      assert @run.iterations.build(number: 4).valid?
      assert @run.iterations.build(number: 5).valid?
      assert_not @run.iterations.build(number: 6).valid?
    ensure
      ArnoldPipeline.reset_configuration!
    end

    test "decision must be valid if present" do
      iteration = @run.iterations.build(number: 1, decision: "invalid")
      assert_not iteration.valid?
      assert_includes iteration.errors[:decision], "is not included in the list"
    end

    test "accepts valid decisions" do
      %w[iterate_tasks iterate_spec done].each do |decision|
        iteration = @run.iterations.build(number: 1, decision: decision)
        assert iteration.valid?, "Expected #{decision} to be valid"
      end
    end

    test "confidence must be 0-100 if present" do
      assert_not @run.iterations.build(number: 1, confidence: -1).valid?
      assert @run.iterations.build(number: 1, confidence: 0).valid?
      assert @run.iterations.build(number: 1, confidence: 100).valid?
      assert_not @run.iterations.build(number: 1, confidence: 101).valid?
    end

    test "flags low confidence for human review" do
      iteration = @run.iterations.create!(number: 1, decision: "iterate_tasks", confidence: 50)
      assert iteration.needs_human_review
    end

    test "does not flag high confidence" do
      iteration = @run.iterations.create!(number: 1, decision: "done", confidence: 85)
      assert_not iteration.needs_human_review
    end

    test "flags confidence at exactly 69" do
      iteration = @run.iterations.create!(number: 1, decision: "done", confidence: 69)
      assert iteration.needs_human_review
    end

    test "does not flag confidence at exactly 70" do
      iteration = @run.iterations.create!(number: 1, decision: "done", confidence: 70)
      assert_not iteration.needs_human_review
    end

    test "belongs to pipeline_run" do
      iteration = @run.iterations.create!(number: 1, decision: "done", confidence: 90)
      assert_equal @run, iteration.pipeline_run
    end
  end
end
