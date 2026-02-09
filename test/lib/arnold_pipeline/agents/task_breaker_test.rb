require "test_helper"
require "arnold_pipeline/agents/task_breaker"
require "arnold_pipeline/library/manager"

module ArnoldPipeline
  module Agents
    class TaskBreakerTest < ActiveSupport::TestCase
      setup do
        @llm = stub("llm")
        @agent = TaskBreaker.new(llm: @llm, logger: Logger.new(File::NULL))
        @manager = Library::Manager.new
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

      test "passes recipe context to system prompt" do
        recipe = @manager.find_recipe("Build a responsive web dashboard")
        tasks = [
          { "title" => "Bootstrap project", "description" => "Setup Rails 8", "priority" => 0, "labels" => ["setup"], "position" => 0, "depends_on" => [] }
        ]

        @llm.expects(:chat).with { |kwargs|
          kwargs[:system].include?("Technology Context") &&
            kwargs[:system].include?(recipe.name) &&
            kwargs[:system].include?("Rails 8+")
        }.returns("```json\n#{JSON.generate(tasks)}\n```")

        @agent.call(spec_content: "# A spec", recipe: recipe)
      end

      test "works without recipe (backward compatibility)" do
        tasks = [
          { "title" => "Bootstrap", "description" => "Setup", "priority" => 0, "labels" => ["setup"], "position" => 0, "depends_on" => [] }
        ]

        @llm.expects(:chat).with { |kwargs|
          !kwargs[:system].include?("Technology Context")
        }.returns("```json\n#{JSON.generate(tasks)}\n```")

        @agent.call(spec_content: "# A spec")
      end

      test "includes supporting recipes in system prompt" do
        recipe = @manager.find_recipe("Build a responsive web dashboard")
        supporting = [@manager.find_recipe("Create a REST API with JSON endpoints")]
        tasks = [
          { "title" => "Bootstrap", "description" => "Setup", "priority" => 0, "labels" => ["setup"], "position" => 0, "depends_on" => [] }
        ]

        @llm.expects(:chat).with { |kwargs|
          kwargs[:system].include?("Supporting recipes") &&
            kwargs[:system].include?("API Service")
        }.returns("```json\n#{JSON.generate(tasks)}\n```")

        @agent.call(spec_content: "# A spec", recipe: recipe, supporting_recipes: supporting)
      end
    end
  end
end
