require "test_helper"
require "arnold_pipeline/setup/result"

module ArnoldPipeline
  module Setup
    class ResultTest < ActiveSupport::TestCase
      cover "ArnoldPipeline::Setup::Result*"

      test "complete result has correct status" do
        result = Result.complete(
          project_path: "/tmp/app",
          config_path: "/home/user/.arnold_pipeline/config.yml",
          spec_summary: { version: 1 },
          task_summary: { total: 5 },
          run_id: 42
        )

        assert result.complete?
        refute result.needs_input?
        refute result.error?
      end

      test "complete result stores all fields" do
        result = Result.complete(
          project_path: "/tmp/app",
          config_path: "/config.yml",
          spec_summary: { version: 1 },
          task_summary: { total: 5 },
          run_id: 42
        )

        assert_equal "/tmp/app", result.project_path
        assert_equal "/config.yml", result.config_path
        assert_equal({ version: 1 }, result.spec_summary)
        assert_equal({ total: 5 }, result.task_summary)
        assert_equal 42, result.run_id
      end

      test "needs_input result has correct status" do
        result = Result.needs_input([ :project_path, :description ])

        assert result.needs_input?
        refute result.complete?
        refute result.error?
      end

      test "needs_input result stores missing fields" do
        result = Result.needs_input([ :project_path, :llm_api_key ])

        assert_equal [ :project_path, :llm_api_key ], result.missing_fields
      end

      test "error result has correct status" do
        result = Result.error("Something broke")

        assert result.error?
        refute result.complete?
        refute result.needs_input?
      end

      test "error result wraps single string in array" do
        result = Result.error("Something broke")
        assert_equal [ "Something broke" ], result.errors
      end

      test "error result accepts array of errors" do
        result = Result.error([ "error 1", "error 2" ])
        assert_equal [ "error 1", "error 2" ], result.errors
      end

      test "result is frozen" do
        result = Result.needs_input([ :project_path ])
        assert result.frozen?
      end

      test "missing_fields is frozen" do
        result = Result.needs_input([ :project_path ])
        assert result.missing_fields.frozen?
      end

      test "errors is frozen" do
        result = Result.error([ "bad" ])
        assert result.errors.frozen?
      end

      test "invalid status raises ArgumentError" do
        assert_raises(ArgumentError) do
          Result.new(status: :bogus)
        end
      end

      test "STATUSES constant includes all three statuses" do
        assert_equal %i[complete needs_input error], Result::STATUSES
      end
    end
  end
end
