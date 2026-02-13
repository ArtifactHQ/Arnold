require "test_helper"
require "arnold_pipeline/agents/task_breaker"
require "arnold_pipeline/library/manager"
require "json_schemer"

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
          { "title" => "Setup database", "description" => "Create schema", "priority" => 0, "labels" => ["database"], "position" => 0, "depends_on" => [], "section_ref" => "Setup" },
          { "title" => "Create models", "description" => "Define AR models", "priority" => 0, "labels" => ["backend"], "position" => 1, "depends_on" => [0], "section_ref" => "Models" },
          { "title" => "Build API", "description" => "REST endpoints", "priority" => 1, "labels" => ["backend"], "position" => 2, "depends_on" => [1], "section_ref" => "API" },
          { "title" => "Add auth", "description" => "Auth flow", "priority" => 1, "labels" => ["backend"], "position" => 3, "depends_on" => [1], "section_ref" => "Auth" },
          { "title" => "Write tests", "description" => "Test suite", "priority" => 2, "labels" => ["testing"], "position" => 4, "depends_on" => [2, 3], "section_ref" => "Testing" }
        ]
        @llm.expects(:chat_json).returns({ "tasks" => tasks })

        result = @agent.call(spec_content: "# A spec")
        assert_equal 5, result.size
        assert_equal "Setup database", result.first["title"]
      end

      test "raises on missing title" do
        tasks = [{ "position" => 0, "depends_on" => [] }]
        @llm.expects(:chat_json).returns({ "tasks" => tasks })

        assert_raises(ArnoldPipeline::Error) { @agent.call(spec_content: "spec") }
      end

      test "raises on invalid dependency order" do
        tasks = [
          { "title" => "Task A", "position" => 0, "depends_on" => [1] },
          { "title" => "Task B", "position" => 1, "depends_on" => [] }
        ]
        @llm.expects(:chat_json).returns({ "tasks" => tasks })

        assert_raises(ArnoldPipeline::Error) { @agent.call(spec_content: "spec") }
      end

      test "raises on non-existent dependency" do
        tasks = [
          { "title" => "Task A", "position" => 0, "depends_on" => [99] }
        ]
        @llm.expects(:chat_json).returns({ "tasks" => tasks })

        assert_raises(ArnoldPipeline::Error) { @agent.call(spec_content: "spec") }
      end

      test "passes recipe context to system prompt" do
        recipe = @manager.find_recipe("Build a responsive web dashboard")
        tasks = [
          { "title" => "Bootstrap project", "description" => "Setup Rails 8", "priority" => 0, "labels" => ["setup"], "position" => 0, "depends_on" => [], "section_ref" => "Setup" }
        ]

        @llm.expects(:chat_json).with { |kwargs|
          kwargs[:system].include?("Technology Context") &&
            kwargs[:system].include?(recipe.name) &&
            kwargs[:system].include?("Rails 8+")
        }.returns({ "tasks" => tasks })

        @agent.call(spec_content: "# A spec", recipe: recipe)
      end

      test "works without recipe (backward compatibility)" do
        tasks = [
          { "title" => "Bootstrap", "description" => "Setup", "priority" => 0, "labels" => ["setup"], "position" => 0, "depends_on" => [], "section_ref" => "Setup" }
        ]

        @llm.expects(:chat_json).with { |kwargs|
          !kwargs[:system].include?("Technology Context")
        }.returns({ "tasks" => tasks })

        @agent.call(spec_content: "# A spec")
      end

      test "includes supporting recipes in system prompt" do
        recipe = @manager.find_recipe("Build a responsive web dashboard")
        supporting = [@manager.find_recipe("Create a REST API with JSON endpoints")]
        tasks = [
          { "title" => "Bootstrap", "description" => "Setup", "priority" => 0, "labels" => ["setup"], "position" => 0, "depends_on" => [], "section_ref" => "Setup" }
        ]

        @llm.expects(:chat_json).with { |kwargs|
          kwargs[:system].include?("Supporting recipes") &&
            kwargs[:system].include?("API Service")
        }.returns({ "tasks" => tasks })

        @agent.call(spec_content: "# A spec", recipe: recipe, supporting_recipes: supporting)
      end

      # -- Schema validation --

      test "RESPONSE_SCHEMA validates a well-formed task breakdown" do
        schemer = JSONSchemer.schema(TaskBreaker::RESPONSE_SCHEMA[:schema])
        data = {
          "tasks" => [
            { "title" => "Setup", "description" => "Bootstrap", "priority" => 0,
              "labels" => ["setup"], "position" => 0, "depends_on" => [], "section_ref" => "Setup",
              "acceptance_criteria" => [
                { "type" => "file_exists", "description" => "Project exists", "params" => '{"pattern": "Gemfile"}' }
              ] }
          ]
        }
        assert schemer.valid?(data), "Expected valid, got: #{schemer.validate(data).map(&:to_h)}"
      end

      test "RESPONSE_SCHEMA rejects missing required field" do
        schemer = JSONSchemer.schema(TaskBreaker::RESPONSE_SCHEMA[:schema])
        data = { "tasks" => [{ "title" => "Setup" }] }
        refute schemer.valid?(data)
      end
    end
  end
end
