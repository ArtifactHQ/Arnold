require "test_helper"
require "arnold_pipeline/mcp/context"
require "arnold_pipeline/mcp/tools/ask_engineer"

module ArnoldPipeline
  module Mcp
    module Tools
      class AskEngineerTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Mcp::Tools::AskEngineer*"

        setup do
          @context = Context.new
          @run = PipelineRun.create!(
            nl_input: "Build a real-time collaboration web app",
            metadata: {
              "library_selections" => {
                "persona" => "Software Architect",
                "recipe" => "Web App",
                "supporting_recipes" => ["API Service"],
                "domain_type" => "PRODUCTIVITY"
              }
            }
          )
          @spec = Specification.create!(
            pipeline_run: @run,
            content: "# Collaboration App\n\n## Features\n- Real-time editing\n- User authentication\n\n## Tech Stack\n- Rails 8+\n- Hotwire\n- SQLite",
            version: 1,
            structured_data: {
              "tech_stack" => { "backend" => "Rails 8+", "frontend" => "Hotwire" },
              "domains" => [{ "name" => "Collaboration" }],
              "recipes" => [{ "name" => "Web App" }]
            }
          )
        end

        teardown do
          ArnoldPipeline.reset_configuration!
        end

        test "tool_name returns ask_engineer" do
          assert_equal "ask_engineer", AskEngineer.tool_name
        end

        test "description is present and non-empty" do
          assert_kind_of String, AskEngineer.description
          refute_empty AskEngineer.description
        end

        test "input_schema has question as required" do
          schema = AskEngineer.input_schema
          assert_equal "object", schema[:type]
          assert schema[:properties].key?(:question)
          assert schema[:properties].key?(:run_id)
          assert_includes schema[:required], "question"
        end

        test "call returns structured answer via LLM" do
          llm_response = {
            "answer" => "Use Action Cable with Turbo Streams for real-time.",
            "recipes_referenced" => [{ "name" => "Web App", "relevance" => "Provides Hotwire stack" }],
            "constraints" => ["Must use Hotwire, no SPA frameworks"],
            "alternatives_considered" => [
              { "approach" => "Phoenix LiveView", "reason_rejected" => "Project uses Rails" }
            ]
          }

          llm = stub("llm")
          llm.stubs(:chat_json).returns(llm_response)
          Providers::Llm.stubs(:build).returns(llm)

          result = AskEngineer.call({ "question" => "How should I implement real-time?" }, @context)

          assert_equal "Use Action Cable with Turbo Streams for real-time.", result[:answer]
          assert_equal 1, result[:recipes_referenced].length
          assert_equal "Web App", result[:recipes_referenced].first[:name]
          assert_includes result[:constraints], "Must use Hotwire, no SPA frameworks"
          assert_equal 1, result[:alternatives_considered].length
          assert_equal "Phoenix LiveView", result[:alternatives_considered].first[:approach]
        end

        test "call returns answer for specific run_id" do
          llm_response = {
            "answer" => "Specific answer",
            "recipes_referenced" => [],
            "constraints" => [],
            "alternatives_considered" => []
          }

          llm = stub("llm")
          llm.stubs(:chat_json).returns(llm_response)
          Providers::Llm.stubs(:build).returns(llm)

          result = AskEngineer.call(
            { "question" => "How?", "run_id" => @run.id.to_s },
            @context
          )

          assert_equal "Specific answer", result[:answer]
        end

        test "call falls back to latest run when run_id is nil" do
          llm_response = {
            "answer" => "Answer from latest",
            "recipes_referenced" => [],
            "constraints" => [],
            "alternatives_considered" => []
          }

          llm = stub("llm")
          llm.stubs(:chat_json).returns(llm_response)
          Providers::Llm.stubs(:build).returns(llm)

          result = AskEngineer.call({ "question" => "What stack?" }, @context)

          assert_equal "Answer from latest", result[:answer]
        end

        test "call returns error when question is empty" do
          result = AskEngineer.call({ "question" => "" }, @context)
          assert_equal "question is required", result[:error]
        end

        test "call returns error when question is nil" do
          result = AskEngineer.call({}, @context)
          assert_equal "question is required", result[:error]
        end

        test "call returns error when no pipeline run found" do
          PipelineRun.destroy_all
          result = AskEngineer.call({ "question" => "How?" }, @context)
          assert_equal "No pipeline run found", result[:error]
        end

        test "call returns error when run has no specification" do
          run_no_spec = PipelineRun.create!(nl_input: "no spec")
          result = AskEngineer.call(
            { "question" => "How?", "run_id" => run_no_spec.id.to_s },
            @context
          )
          assert_includes result[:error], "No specification found"
        end

        test "call falls back gracefully when LLM is unavailable" do
          Providers::Llm.stubs(:build).raises(ConfigurationError, "No API key")

          result = AskEngineer.call({ "question" => "How should I build auth?" }, @context)

          assert_kind_of String, result[:answer]
          refute_empty result[:answer]
          assert_kind_of Array, result[:recipes_referenced]
          assert_kind_of Array, result[:constraints]
          assert_kind_of Array, result[:alternatives_considered]
        end

        test "fallback includes recipe info when available" do
          Providers::Llm.stubs(:build).raises(ConfigurationError, "No API key")

          result = AskEngineer.call({ "question" => "What framework?" }, @context)

          recipe_names = result[:recipes_referenced].map { |r| r[:name] }
          assert_includes recipe_names, "Web App"
        end

        test "fallback includes tech stack constraints from structured_data" do
          Providers::Llm.stubs(:build).raises(ConfigurationError, "No API key")

          result = AskEngineer.call({ "question" => "What stack?" }, @context)

          assert result[:constraints].any? { |c| c.include?("Rails") || c.include?("Hotwire") }
        end

        test "call handles run with no library_selections gracefully" do
          @run.update!(metadata: {})

          llm_response = {
            "answer" => "Based on the spec alone",
            "recipes_referenced" => [],
            "constraints" => [],
            "alternatives_considered" => []
          }

          llm = stub("llm")
          llm.stubs(:chat_json).returns(llm_response)
          Providers::Llm.stubs(:build).returns(llm)

          result = AskEngineer.call({ "question" => "How?" }, @context)
          assert_equal "Based on the spec alone", result[:answer]
        end

        test "call handles run with nil metadata gracefully" do
          @run.update_column(:metadata, nil)

          llm_response = {
            "answer" => "Based on spec only",
            "recipes_referenced" => [],
            "constraints" => [],
            "alternatives_considered" => []
          }

          llm = stub("llm")
          llm.stubs(:chat_json).returns(llm_response)
          Providers::Llm.stubs(:build).returns(llm)

          result = AskEngineer.call({ "question" => "How?" }, @context)
          assert_equal "Based on spec only", result[:answer]
        end

        test "response has all expected keys with correct types" do
          llm_response = {
            "answer" => "Use Rails 8+",
            "recipes_referenced" => [{ "name" => "Web App", "relevance" => "Primary" }],
            "constraints" => ["Rails 8+"],
            "alternatives_considered" => [{ "approach" => "Django", "reason_rejected" => "Not Ruby" }]
          }

          llm = stub("llm")
          llm.stubs(:chat_json).returns(llm_response)
          Providers::Llm.stubs(:build).returns(llm)

          result = AskEngineer.call({ "question" => "What framework?" }, @context)

          assert_kind_of String, result[:answer]
          assert_kind_of Array, result[:recipes_referenced]
          assert_kind_of Array, result[:constraints]
          assert_kind_of Array, result[:alternatives_considered]

          ref = result[:recipes_referenced].first
          assert_kind_of String, ref[:name]
          assert_kind_of String, ref[:relevance]

          alt = result[:alternatives_considered].first
          assert_kind_of String, alt[:approach]
          assert_kind_of String, alt[:reason_rejected]
        end
      end
    end
  end
end
