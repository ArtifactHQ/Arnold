require "test_helper"
require "arnold_pipeline/mcp/context"

module ArnoldPipeline
  module Mcp
    class ContextTest < ActiveSupport::TestCase
      cover "ArnoldPipeline::Mcp::Context*"

      setup do
        @context = Context.new
      end

      teardown do
        ArnoldPipeline.reset_configuration!
      end

      test "pipeline_run returns latest run when no run_id given" do
        old_run = PipelineRun.create!(nl_input: "old run")
        new_run = PipelineRun.create!(nl_input: "new run")

        result = @context.pipeline_run
        assert_equal new_run.id, result.id
      end

      test "pipeline_run returns specific run by id" do
        run1 = PipelineRun.create!(nl_input: "first")
        _run2 = PipelineRun.create!(nl_input: "second")

        result = @context.pipeline_run(run_id: run1.id)
        assert_equal run1.id, result.id
      end

      test "pipeline_run returns nil when run_id not found" do
        result = @context.pipeline_run(run_id: 999999)
        assert_nil result
      end

      test "pipeline_run returns nil when no runs exist" do
        PipelineRun.destroy_all
        result = @context.pipeline_run
        assert_nil result
      end

      test "specification returns spec for latest run" do
        run = PipelineRun.create!(nl_input: "test")
        spec = Specification.create!(pipeline_run: run, content: "# Spec", version: 1)

        result = @context.specification
        assert_equal spec.id, result.id
      end

      test "specification returns spec for specific run" do
        run = PipelineRun.create!(nl_input: "test")
        spec = Specification.create!(pipeline_run: run, content: "# Spec", version: 1)

        result = @context.specification(run_id: run.id)
        assert_equal spec.id, result.id
      end

      test "specification returns nil when run has no spec" do
        run = PipelineRun.create!(nl_input: "test")
        result = @context.specification(run_id: run.id)
        assert_nil result
      end

      test "library_manager returns a Library::Manager instance" do
        manager = @context.library_manager
        assert_instance_of Library::Manager, manager
      end

      test "library_manager is memoized" do
        manager1 = @context.library_manager
        manager2 = @context.library_manager
        assert_same manager1, manager2
      end

      test "configuration returns ArnoldPipeline configuration" do
        config = @context.configuration
        assert_equal ArnoldPipeline.configuration, config
      end
    end
  end
end
