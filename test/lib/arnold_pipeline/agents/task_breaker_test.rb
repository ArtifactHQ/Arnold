require "test_helper"
require "arnold_pipeline/agents/task_breaker"

module ArnoldPipeline
  module Agents
    class TaskBreakerTest < ActiveSupport::TestCase
      setup do
        @llm = stub("llm")
        @agent = TaskBreaker.new(llm: @llm, logger: Logger.new(File::NULL))
      end

      test "parses tasks from LLM response" do
        tasks = [
          { "title" => "Setup database", "description" => "Create schema", "priority" => 0, "labels" => ["database"], "position" => 0, "depends_on" => [] },
          { "title" => "Create models", "description" => "Define AR models", "priority" => 0, "labels" => ["backend"], "position" => 1, "depends_on" => [0] },
          { "title" => "Build API", "description" => "REST endpoints", "priority" => 1, "labels" => ["backend"], "position" => 2, "depends_on" => [1] },
          { "title" => "Add auth", "description" => "Auth flow", "priority" => 1, "labels" => ["backend"], "position" => 3, "depends_on" => [1] },
          { "title" => "Write tests", "description" => "Test suite", "priority" => 2, "labels" => ["testing"], "position" => 4, "depends_on" => [2, 3] }
        ]
        @llm.expects(:chat).returns("```json\n#{JSON.generate(tasks)}\n```")

        result = @agent.call(spec_content: "# A spec")
        assert_equal 5, result.size
        assert_equal "Setup database", result.first["title"]
      end

      test "raises on missing title" do
        tasks = [{ "position" => 0, "depends_on" => [] }]
        @llm.expects(:chat).returns("```json\n#{JSON.generate(tasks)}\n```")

        assert_raises(ArnoldPipeline::Error) { @agent.call(spec_content: "spec") }
      end

      test "raises on invalid dependency order" do
        tasks = [
          { "title" => "Task A", "position" => 0, "depends_on" => [1] },
          { "title" => "Task B", "position" => 1, "depends_on" => [] }
        ]
        @llm.expects(:chat).returns("```json\n#{JSON.generate(tasks)}\n```")

        assert_raises(ArnoldPipeline::Error) { @agent.call(spec_content: "spec") }
      end

      test "raises on non-existent dependency" do
        tasks = [
          { "title" => "Task A", "position" => 0, "depends_on" => [99] }
        ]
        @llm.expects(:chat).returns("```json\n#{JSON.generate(tasks)}\n```")

        assert_raises(ArnoldPipeline::Error) { @agent.call(spec_content: "spec") }
      end
    end
  end
end
