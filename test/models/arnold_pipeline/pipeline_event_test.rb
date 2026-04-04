require "test_helper"

module ArnoldPipeline
  class PipelineEventTest < ActiveSupport::TestCase
    cover "ArnoldPipeline::PipelineEvent*"

    setup do
      @run = PipelineRun.create!(nl_input: "Build a todo app")
    end

    test "valid event with all fields" do
      event = @run.pipeline_events.build(
        event_type: :spec_generated,
        stage: "spec_generation",
        summary: { content_length: 4521 },
        duration_ms: 3412.5,
        payload: { response: "full llm response" }
      )
      assert event.valid?
    end

    test "requires event_type" do
      event = @run.pipeline_events.build(stage: "spec_generation", summary: {})
      assert_not event.valid?
      assert event.errors[:event_type].any?
    end

    test "requires stage" do
      event = @run.pipeline_events.build(event_type: :spec_generated, stage: nil, summary: {})
      assert_not event.valid?
      assert_includes event.errors[:stage], "can't be blank"
    end

    test "requires valid stage" do
      event = @run.pipeline_events.build(event_type: :spec_generated, stage: "invalid_stage", summary: {})
      assert_not event.valid?
      assert_includes event.errors[:stage], "is not included in the list"
    end

    test "requires summary" do
      event = @run.pipeline_events.build(event_type: :spec_generated, stage: "spec_generation", summary: nil)
      assert_not event.valid?
      assert_includes event.errors[:summary], "can't be blank"
    end

    test "all event_type enum values" do
      expected = %w[
        library_selection spec_generated tasks_broken
        tier_execution_started tier_execution_completed task_published task_result_fetched
        tier_gate_evaluated analysis_completed iteration_decision spec_delta_merged
        pipeline_paused pipeline_failed pipeline_completed repo_context_scanned
        criteria_check verification_execution test_execution spec_test_execution
        post_merge_hooks verification_checks
        pipeline_finalized finalization_verification finalization_setup
        stack_detection codebase_profiling feature_extraction as_built_spec_generated health_baseline
        test_name_collection concern_diff_analysis
        file_manifest_built route_table_parsed git_activity_analyzed parallel_agents_completed
        pipeline_resumed spec_imported
      ]
      assert_equal expected, PipelineEvent.event_types.keys
    end

    test "VALID_STAGES includes all stages" do
      expected = %w[spec_generation task_breakdown execution tier_gate analysis iteration lifecycle brownfield]
      assert_equal expected, PipelineEvent::VALID_STAGES
    end

    test "for_stage scope" do
      @run.pipeline_events.create!(event_type: :spec_generated, stage: "spec_generation", summary: {})
      @run.pipeline_events.create!(event_type: :tasks_broken, stage: "task_breakdown", summary: {})
      @run.pipeline_events.create!(event_type: :analysis_completed, stage: "analysis", summary: {})

      assert_equal 1, @run.pipeline_events.for_stage("spec_generation").count
      assert_equal 1, @run.pipeline_events.for_stage("analysis").count
    end

    test "chronological scope orders by created_at" do
      e1 = @run.pipeline_events.create!(event_type: :spec_generated, stage: "spec_generation", summary: {})
      e2 = @run.pipeline_events.create!(event_type: :tasks_broken, stage: "task_breakdown", summary: {})

      events = @run.pipeline_events.chronological
      assert_equal [ e1.id, e2.id ], events.map(&:id)
    end

    test "with_payloads scope" do
      @run.pipeline_events.create!(event_type: :spec_generated, stage: "spec_generation", summary: {}, payload: { data: "test" })
      @run.pipeline_events.create!(event_type: :tasks_broken, stage: "task_breakdown", summary: {})

      assert_equal 1, @run.pipeline_events.with_payloads.count
    end

    test "belongs_to pipeline_run" do
      event = @run.pipeline_events.create!(event_type: :spec_generated, stage: "spec_generation", summary: {})
      assert_equal @run, event.pipeline_run
    end

    test "dependent destroy removes events when pipeline_run is destroyed" do
      @run.pipeline_events.create!(event_type: :spec_generated, stage: "spec_generation", summary: {})
      @run.pipeline_events.create!(event_type: :tasks_broken, stage: "task_breakdown", summary: {})

      assert_equal 2, PipelineEvent.where(pipeline_run_id: @run.id).count
      @run.destroy!
      assert_equal 0, PipelineEvent.where(pipeline_run_id: @run.id).count
    end

    test "optional fields can be nil" do
      event = @run.pipeline_events.create!(
        event_type: :library_selection,
        stage: "spec_generation",
        summary: { persona: "Software Architect" }
      )
      assert_nil event.payload
      assert_nil event.duration_ms
      assert_nil event.iteration_number
      assert_nil event.tier_number
    end

    test "stores iteration_number and tier_number" do
      event = @run.pipeline_events.create!(
        event_type: :analysis_completed,
        stage: "analysis",
        summary: { decision: "done" },
        iteration_number: 2,
        tier_number: 1
      )
      assert_equal 2, event.iteration_number
      assert_equal 1, event.tier_number
    end
  end
end
