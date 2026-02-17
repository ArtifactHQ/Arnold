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

      test "auto-repairs backwards dependency order via topological sort" do
        tasks = [
          { "title" => "Task A", "position" => 0, "depends_on" => [1] },
          { "title" => "Task B", "position" => 1, "depends_on" => [] }
        ]
        @llm.expects(:chat_json).returns({ "tasks" => tasks })

        result = @agent.call(spec_content: "spec")
        assert_equal 2, result.size
        # Task B should come first (no deps), Task A second (depends on B)
        assert_equal "Task B", result[0]["title"]
        assert_equal 1, result[0]["position"]
        assert_equal "Task A", result[1]["title"]
        assert_equal 2, result[1]["position"]
        assert_equal [1], result[1]["depends_on"]
      end

      test "strips non-existent dependency references" do
        tasks = [
          { "title" => "Task A", "position" => 0, "depends_on" => [99] }
        ]
        @llm.expects(:chat_json).returns({ "tasks" => tasks })

        result = @agent.call(spec_content: "spec")
        assert_equal 1, result.size
        assert_empty result[0]["depends_on"]
      end

      test "handles dependency cycle by stripping all deps" do
        tasks = [
          { "title" => "Task A", "position" => 0, "depends_on" => [1] },
          { "title" => "Task B", "position" => 1, "depends_on" => [0] }
        ]
        @llm.expects(:chat_json).returns({ "tasks" => tasks })

        result = @agent.call(spec_content: "spec")
        assert_equal 2, result.size
        result.each { |t| assert_empty t["depends_on"] }
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

      # -- Delta-scoped tests --

      test "forwards deltas to system and user prompts" do
        deltas = [{ "operation" => "added", "section" => "Features", "requirement" => "Dark Mode", "content" => "Dark mode support" }]
        tasks = [
          { "title" => "Add dark mode", "description" => "Implement dark mode toggle", "priority" => 0, "labels" => ["frontend"], "position" => 0, "depends_on" => [], "section_ref" => "Features > Dark Mode" }
        ]

        @llm.expects(:chat_json).with { |kwargs|
          kwargs[:system].include?("Delta Scope") &&
            kwargs[:system].include?("Dark Mode") &&
            kwargs[:messages].first[:content].include?("already built")
        }.returns({ "tasks" => tasks })

        result = @agent.call(spec_content: "# A spec", deltas: deltas)
        assert_equal 1, result.size
      end

      test "does not warn for 1 task when delta-scoped" do
        deltas = [{ "operation" => "added", "section" => "Features", "requirement" => "Fix", "content" => "Fix stuff" }]
        tasks = [
          { "title" => "Fix thing", "position" => 0, "depends_on" => [] }
        ]
        @llm.expects(:chat_json).returns({ "tasks" => tasks })

        warned = false
        logger = Logger.new(File::NULL)
        logger.define_singleton_method(:warn) { |*args, &block| warned = true; block&.call }
        agent = TaskBreaker.new(llm: @llm, logger: logger)
        result = agent.call(spec_content: "spec", deltas: deltas)
        assert_equal 1, result.size
        refute warned, "Should not warn about task count when delta-scoped"
      end

      test "warns for 1 task when not delta-scoped" do
        tasks = [
          { "title" => "Solo task", "position" => 0, "depends_on" => [] }
        ]
        @llm.expects(:chat_json).returns({ "tasks" => tasks })

        warned = false
        logger = Logger.new(File::NULL)
        logger.define_singleton_method(:warn) { |*args, &block| warned = true; block&.call }
        agent = TaskBreaker.new(llm: @llm, logger: logger)
        agent.call(spec_content: "spec")
        assert warned, "Should have warned about task count outside range"
      end

      test "passes deltas nil by default (backward compatibility)" do
        tasks = [
          { "title" => "Bootstrap", "position" => 0, "depends_on" => [], "section_ref" => "Setup" }
        ]

        @llm.expects(:chat_json).with { |kwargs|
          !kwargs[:system].include?("Delta Scope") &&
            kwargs[:messages].first[:content].include?("Break down the following")
        }.returns({ "tasks" => tasks })

        @agent.call(spec_content: "# A spec")
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
