require "test_helper"
require "arnold_pipeline/providers/execution/null"
require_relative "shared_provider_tests"

module ArnoldPipeline
  module Providers
    module Execution
      class NullProviderTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Providers::Execution::Null*"

        include SharedProviderTests

        def provider_instance
          @provider
        end

        setup do
          @provider = Null.new
          @pipeline_run = ArnoldPipeline::PipelineRun.create!(nl_input: "Build an app")
        end

        test "async? returns false" do
          refute @provider.async?
        end

        test "recoverable_errors returns empty array" do
          assert_equal [], @provider.recoverable_errors
        end

        test "create_tasks returns external_ids" do
          tasks = [
            { "title" => "Setup DB", "description" => "Create schema" },
            { "title" => "Build API", "description" => "Create endpoints" }
          ]

          results = @provider.create_tasks(tasks:, pipeline_run: @pipeline_run)

          assert_equal 2, results.size
          assert_equal "null-0", results[0][:external_id]
          assert_equal "Setup DB", results[0][:title]
          assert_nil results[0][:external_url]
          assert_equal "null-1", results[1][:external_id]
        end

        test "fetch_results returns completed status" do
          task = @pipeline_run.tasks.create!(title: "Setup DB", position: 0, external_id: "null-0")

          results = @provider.fetch_results(pipeline_run: @pipeline_run)

          assert_equal 1, results.size
          assert_equal task.id, results.first[:task_id]
          assert_equal :completed, results.first[:status]
          assert_equal false, results.first[:workflow_active]
          assert_equal [], results.first[:diffs]
        end

        test "fetch_results skips tasks without external_id" do
          @pipeline_run.tasks.create!(title: "Unpublished", position: 0)

          results = @provider.fetch_results(pipeline_run: @pipeline_run)

          assert_empty results
        end

        test "merge_results returns empty array" do
          assert_equal [], @provider.merge_results(pipeline_run: @pipeline_run)
        end

        test "can be built via Execution.build" do
          ArnoldPipeline.configure do |c|
            c.execution_provider = :null
            c.llm_api_key = "test"
          end

          provider = Execution.build
          assert_kind_of Null, provider
        ensure
          ArnoldPipeline.reset_configuration!
        end

        test "validate_configuration! is a no-op" do
          assert_nil Null.validate_configuration!(stub)
        end
      end
    end
  end
end
