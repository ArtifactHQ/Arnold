require "test_helper"
require "arnold_pipeline/pipeline_event_recorder"

module ArnoldPipeline
  class PipelineEventRecorderTest < ActiveSupport::TestCase
    setup do
      @run = PipelineRun.create!(nl_input: "Build a todo app")
      @recorder = PipelineEventRecorder.new(pipeline_run: @run)
    end

    teardown do
      ArnoldPipeline.reset_configuration!
    end

    test "records event with all fields" do
      @recorder.record(
        event_type: :spec_generated,
        stage: "spec_generation",
        summary: { content_length: 4521 },
        duration_ms: 3412.5,
        iteration_number: 1,
        tier_number: 0
      )

      event = @run.pipeline_events.last
      assert_equal "spec_generated", event.event_type
      assert_equal "spec_generation", event.stage
      assert_equal({ "content_length" => 4521 }, event.summary)
      assert_in_delta 3412.5, event.duration_ms
      assert_equal 1, event.iteration_number
      assert_equal 0, event.tier_number
    end

    test "skips recording when event_logging_enabled is false" do
      ArnoldPipeline.configure { |c| c.event_logging_enabled = false }

      @recorder.record(
        event_type: :spec_generated,
        stage: "spec_generation",
        summary: { content_length: 100 }
      )

      assert_equal 0, @run.pipeline_events.count
    end

    test "excludes payload when verbose_event_logging is false" do
      ArnoldPipeline.configure { |c| c.verbose_event_logging = false }

      @recorder.record(
        event_type: :spec_generated,
        stage: "spec_generation",
        summary: { content_length: 100 },
        payload: { full_response: "large data" }
      )

      event = @run.pipeline_events.last
      assert_nil event.payload
    end

    test "includes payload when verbose_event_logging is true" do
      ArnoldPipeline.configure { |c| c.verbose_event_logging = true }

      @recorder.record(
        event_type: :spec_generated,
        stage: "spec_generation",
        summary: { content_length: 100 },
        payload: { full_response: "large data" }
      )

      event = @run.pipeline_events.last
      assert_equal({ "full_response" => "large data" }, event.payload)
    end

    test "non-fatal on database errors" do
      @run.pipeline_events.stubs(:create!).raises(ActiveRecord::ActiveRecordError, "DB error")

      result = @recorder.record(
        event_type: :spec_generated,
        stage: "spec_generation",
        summary: { content_length: 100 }
      )

      assert_nil result
    end

    test "timed measures duration" do
      @recorder.timed(
        event_type: :spec_generated,
        stage: "spec_generation",
        summary: { content_length: 100 }
      ) do
        sleep(0.01) # 10ms
        "result"
      end

      event = @run.pipeline_events.last
      assert event.duration_ms >= 10, "Expected duration_ms >= 10, got #{event.duration_ms}"
    end

    test "timed returns the block result" do
      result = @recorder.timed(
        event_type: :spec_generated,
        stage: "spec_generation",
        summary: { test: true }
      ) { 42 }

      assert_equal 42, result
    end

    test "timed accepts proc for summary" do
      @recorder.timed(
        event_type: :spec_generated,
        stage: "spec_generation",
        summary: ->(r) { { result_value: r } }
      ) { "hello" }

      event = @run.pipeline_events.last
      assert_equal({ "result_value" => "hello" }, event.summary)
    end
  end
end
