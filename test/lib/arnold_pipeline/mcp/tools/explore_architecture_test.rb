require "test_helper"
require "arnold_pipeline/mcp/context"
require "arnold_pipeline/mcp/tools/explore_architecture"

module ArnoldPipeline
  module Mcp
    module Tools
      class ExploreArchitectureTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Mcp::Tools::ExploreArchitecture*"

        setup do
          @context = Context.new
          @run = PipelineRun.create!(
            nl_input: "Build a todo app with user accounts",
            metadata: {
              "library_selections" => {
                "persona" => "Software Architect",
                "recipe" => "Web App",
                "supporting_recipes" => [ "API Service" ],
                "domain_type" => "PRODUCTIVITY"
              }
            }
          )
          @spec = Specification.create!(
            pipeline_run: @run,
            content: "# Todo App\n\n## Features\n- Task management\n- User authentication\n\n## Tech Stack\n- Rails 8+\n- Hotwire\n- SQLite",
            version: 1,
            structured_data: {
              "tech_stack" => { "backend" => "Rails 8+", "frontend" => "Hotwire", "database" => "SQLite" },
              "domains" => [
                { "name" => "Tasks", "components" => "Task CRUD, lists", "data_summary" => "Task model", "integrations" => "Uses Auth" },
                { "name" => "Auth", "components" => "Login, registration", "data_summary" => "User model", "integrations" => "Used by Tasks" }
              ],
              "recipes" => [ { "name" => "Web App" } ]
            }
          )
        end

        teardown do
          ArnoldPipeline.reset_configuration!
        end

        test "tool_name returns explore_architecture" do
          assert_equal "explore_architecture", ExploreArchitecture.tool_name
        end

        test "description is present and non-empty" do
          assert_kind_of String, ExploreArchitecture.description
          refute_empty ExploreArchitecture.description
        end

        test "input_schema has optional domain and run_id" do
          schema = ExploreArchitecture.input_schema
          assert_equal "object", schema[:type]
          assert schema[:properties].key?(:domain)
          assert schema[:properties].key?(:run_id)
          assert_equal [], schema[:required]
        end

        test "call returns architecture via LLM" do
          llm_response = {
            "architecture" => {
              "stack" => "Rails 8+ with Hotwire and SQLite",
              "rationale" => "Full-stack Ruby framework for rapid development",
              "domains" => [
                {
                  "name" => "Tasks",
                  "components" => "TasksController, Task model",
                  "recipes_used" => [ "Web App" ],
                  "data_summary" => "Task belongs_to User",
                  "integrations" => "Depends on Auth for user context"
                },
                {
                  "name" => "Auth",
                  "components" => "SessionsController, User model",
                  "recipes_used" => [ "Web App" ],
                  "data_summary" => "User has_many Tasks",
                  "integrations" => "Provides current_user to all domains"
                }
              ]
            }
          }

          llm = stub("llm")
          llm.stubs(:chat_json).returns(llm_response)
          Providers::Llm.stubs(:build).returns(llm)

          result = ExploreArchitecture.call({}, @context)

          assert_kind_of Hash, result[:architecture]
          assert_equal "Rails 8+ with Hotwire and SQLite", result[:architecture][:stack]
          assert_equal 2, result[:architecture][:domains].length
        end

        test "call filters by domain" do
          llm_response = {
            "architecture" => {
              "stack" => "Rails 8+",
              "rationale" => "Focused view",
              "domains" => [
                {
                  "name" => "Tasks",
                  "components" => "TasksController",
                  "recipes_used" => [ "Web App" ],
                  "data_summary" => "Task model",
                  "integrations" => "Auth"
                }
              ]
            }
          }

          llm = stub("llm")
          llm.stubs(:chat_json).returns(llm_response)
          Providers::Llm.stubs(:build).returns(llm)

          result = ExploreArchitecture.call({ "domain" => "Tasks" }, @context)

          assert_kind_of Hash, result[:architecture]
          # LLM may return only the filtered domain
          assert result[:architecture][:domains].length >= 1
        end

        test "call works with specific run_id" do
          llm_response = {
            "architecture" => {
              "stack" => "Rails 8+",
              "rationale" => "Good choice",
              "domains" => []
            }
          }

          llm = stub("llm")
          llm.stubs(:chat_json).returns(llm_response)
          Providers::Llm.stubs(:build).returns(llm)

          result = ExploreArchitecture.call(
            { "run_id" => @run.id.to_s },
            @context
          )

          assert_kind_of Hash, result[:architecture]
        end

        test "call returns error when no pipeline run found" do
          PipelineRun.destroy_all
          result = ExploreArchitecture.call({}, @context)
          assert_equal "No pipeline run found", result[:error]
        end

        test "call returns error when run has no specification" do
          run_no_spec = PipelineRun.create!(nl_input: "no spec")
          result = ExploreArchitecture.call(
            { "run_id" => run_no_spec.id.to_s },
            @context
          )
          assert_includes result[:error], "No specification found"
        end

        test "call falls back gracefully when LLM is unavailable" do
          Providers::Llm.stubs(:build).raises(ConfigurationError, "No API key")

          result = ExploreArchitecture.call({}, @context)

          assert_kind_of Hash, result[:architecture]
          assert_kind_of String, result[:architecture][:stack]
          refute_empty result[:architecture][:stack]
          assert_kind_of String, result[:architecture][:rationale]
          assert_kind_of Array, result[:architecture][:domains]
        end

        test "fallback extracts stack from structured_data" do
          Providers::Llm.stubs(:build).raises(ConfigurationError, "No API key")

          result = ExploreArchitecture.call({}, @context)

          stack = result[:architecture][:stack]
          assert stack.include?("Rails") || stack.include?("backend")
        end

        test "fallback extracts domains from structured_data" do
          Providers::Llm.stubs(:build).raises(ConfigurationError, "No API key")

          result = ExploreArchitecture.call({}, @context)

          domain_names = result[:architecture][:domains].map { |d| d[:name] }
          assert_includes domain_names, "Tasks"
          assert_includes domain_names, "Auth"
        end

        test "fallback filters domains by domain parameter" do
          Providers::Llm.stubs(:build).raises(ConfigurationError, "No API key")

          result = ExploreArchitecture.call({ "domain" => "Tasks" }, @context)

          domain_names = result[:architecture][:domains].map { |d| d[:name] }
          assert_includes domain_names, "Tasks"
          refute_includes domain_names, "Auth"
        end

        test "call handles missing structured_data gracefully" do
          @spec.update!(structured_data: nil)

          Providers::Llm.stubs(:build).raises(ConfigurationError, "No API key")

          result = ExploreArchitecture.call({}, @context)

          assert_kind_of Hash, result[:architecture]
          assert_kind_of String, result[:architecture][:stack]
        end

        test "call handles empty structured_data" do
          @spec.update!(structured_data: {})

          Providers::Llm.stubs(:build).raises(ConfigurationError, "No API key")

          result = ExploreArchitecture.call({}, @context)

          assert_kind_of Hash, result[:architecture]
        end

        test "call extracts domains from spec content when structured_data has none" do
          @spec.update!(
            structured_data: { "tech_stack" => { "backend" => "Rails" } },
            content: "# App\n\n## Features\n- User management\n- Notifications\n"
          )

          Providers::Llm.stubs(:build).raises(ConfigurationError, "No API key")

          result = ExploreArchitecture.call({}, @context)

          domain_names = result[:architecture][:domains].map { |d| d[:name] }
          assert_includes domain_names, "User management"
        end

        test "response has all expected keys with correct types" do
          llm_response = {
            "architecture" => {
              "stack" => "Rails 8+",
              "rationale" => "Modern Ruby framework",
              "domains" => [ {
                "name" => "Core",
                "components" => "Models, Controllers",
                "recipes_used" => [ "Web App" ],
                "data_summary" => "Standard CRUD",
                "integrations" => "None"
              } ]
            }
          }

          llm = stub("llm")
          llm.stubs(:chat_json).returns(llm_response)
          Providers::Llm.stubs(:build).returns(llm)

          result = ExploreArchitecture.call({}, @context)

          assert_kind_of Hash, result[:architecture]
          assert_kind_of String, result[:architecture][:stack]
          assert_kind_of String, result[:architecture][:rationale]
          assert_kind_of Array, result[:architecture][:domains]

          domain = result[:architecture][:domains].first
          assert_kind_of String, domain[:name]
          assert_kind_of String, domain[:components]
          assert_kind_of Array, domain[:recipes_used]
          assert_kind_of String, domain[:data_summary]
          assert_kind_of String, domain[:integrations]
        end

        test "call handles nil metadata gracefully" do
          @run.update_column(:metadata, nil)

          Providers::Llm.stubs(:build).raises(ConfigurationError, "No API key")

          result = ExploreArchitecture.call({}, @context)

          assert_kind_of Hash, result[:architecture]
        end

        test "fallback extracts stack from recipe framework when no tech_stack in structured_data" do
          @spec.update!(structured_data: {})
          # The recipe lookup from library_selections["recipe"] = "Web App" should still work

          Providers::Llm.stubs(:build).raises(ConfigurationError, "No API key")

          result = ExploreArchitecture.call({}, @context)

          assert_kind_of String, result[:architecture][:stack]
        end
      end
    end
  end
end
