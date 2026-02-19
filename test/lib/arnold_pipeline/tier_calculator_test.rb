require "test_helper"
require "arnold_pipeline/tier_calculator"

module ArnoldPipeline
  class TierCalculatorTest < ActiveSupport::TestCase
    cover "ArnoldPipeline::TierCalculator*"

    setup do
      @pipeline_run = PipelineRun.create!(nl_input: "Build an app")
    end

    test "linear chain A→B→C produces tiers 0,1,2" do
      create_task!(position: 0, depends_on: [])
      create_task!(position: 1, depends_on: [0])
      create_task!(position: 2, depends_on: [1])

      result = TierCalculator.call(@pipeline_run.tasks.reload)

      assert_equal({ 0 => 0, 1 => 1, 2 => 2 }, result)
    end

    test "diamond A→{B,C}→D produces tiers 0,1,1,2" do
      create_task!(position: 0, depends_on: [])
      create_task!(position: 1, depends_on: [0])
      create_task!(position: 2, depends_on: [0])
      create_task!(position: 3, depends_on: [1, 2])

      result = TierCalculator.call(@pipeline_run.tasks.reload)

      assert_equal({ 0 => 0, 1 => 1, 2 => 1, 3 => 2 }, result)
    end

    test "all independent tasks get tier 0" do
      create_task!(position: 0, depends_on: [])
      create_task!(position: 1, depends_on: [])
      create_task!(position: 2, depends_on: [])

      result = TierCalculator.call(@pipeline_run.tasks.reload)

      assert_equal({ 0 => 0, 1 => 0, 2 => 0 }, result)
    end

    test "sample_tasks fixture produces expected tiers" do
      # Setup database (no deps) → tier 0
      # Create models (dep: 0) → tier 1
      # Build API (dep: 1) → tier 2
      # Add auth (dep: 1) → tier 2
      # Write tests (dep: 2, 3) → tier 3
      create_task!(position: 0, depends_on: [])
      create_task!(position: 1, depends_on: [0])
      create_task!(position: 2, depends_on: [1])
      create_task!(position: 3, depends_on: [1])
      create_task!(position: 4, depends_on: [2, 3])

      result = TierCalculator.call(@pipeline_run.tasks.reload)

      assert_equal({ 0 => 0, 1 => 1, 2 => 2, 3 => 2, 4 => 3 }, result)
    end

    test "updates AR task objects tier column" do
      create_task!(position: 0, depends_on: [])
      create_task!(position: 1, depends_on: [0])

      TierCalculator.call(@pipeline_run.tasks.reload)

      tasks = @pipeline_run.tasks.reload
      assert_equal 0, tasks.find_by(position: 0).tier
      assert_equal 1, tasks.find_by(position: 1).tier
    end

    test "raises CycleError on dependency cycle" do
      create_task!(position: 0, depends_on: [1])
      create_task!(position: 1, depends_on: [0])

      assert_raises(TierCalculator::CycleError) do
        TierCalculator.call(@pipeline_run.tasks.reload)
      end
    end

    private

    def create_task!(position:, depends_on:)
      @pipeline_run.tasks.create!(
        title: "Task #{position}",
        position: position,
        depends_on: depends_on
      )
    end
  end
end
