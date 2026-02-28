require "test_helper"
require "arnold_pipeline/mcp/context"
require "arnold_pipeline/mcp/tools/create_product"

module ArnoldPipeline
  module Mcp
    module Tools
      class CreateProductTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Mcp::Tools::CreateProduct*"

        setup do
          @context = Context.new

          # Pre-built pipeline run + spec that the orchestrator stub will return
          @run = PipelineRun.create!(
            nl_input: "a dog walking app where walkers find clients nearby",
            status: :paused,
            metadata: {
              "library_selections" => {
                "persona" => "Software Architect",
                "recipe" => "Web App",
                "supporting_recipes" => ["API Service"],
                "domain_type" => "SERVICE"
              },
              "paused_at" => "spec"
            }
          )
          @spec = Specification.create!(
            pipeline_run: @run,
            content: "# Dog Walking App\n\n## Purpose\nConnect dog walkers with dog owners.\n\n## Requirements\n- Booking\n- Messaging",
            version: 1,
            structured_data: {
              "product_name" => "Dog Walking App",
              "summary" => "A platform connecting dog walkers with dog owners for on-demand walks",
              "personas" => [
                { "name" => "Dog Owner", "description" => "Books walks for their dogs" },
                { "name" => "Dog Walker", "description" => "Accepts and fulfills walk requests" }
              ],
              "domains" => [
                { "name" => "Booking", "description" => "Walk scheduling and management" },
                { "name" => "Messaging", "description" => "In-app communication" }
              ],
              "open_questions" => [
                "Should walkers set their own pricing?",
                "Is payment handled in-app or externally?"
              ]
            }
          )
          SpecRevision.create!(
            specification: @spec,
            version: 1,
            content: @spec.content,
            change_source: "spec_generation"
          )

          # Stub orchestrator to return our pre-built run
          @orchestrator_stub = stub("orchestrator")
          @orchestrator_stub.stubs(:call).returns(@run)
          ArnoldPipeline::Orchestrator.stubs(:new).returns(@orchestrator_stub)
        end

        teardown do
          ArnoldPipeline.reset_configuration!
        end

        test "tool_name returns create_product" do
          assert_equal "create_product", CreateProduct.tool_name
        end

        test "description is present and non-empty" do
          assert_kind_of String, CreateProduct.description
          refute_empty CreateProduct.description
        end

        test "input_schema requires description" do
          schema = CreateProduct.input_schema
          assert_equal "object", schema[:type]
          assert schema[:properties].key?(:description)
          assert_includes schema[:required], "description"
        end

        test "call creates pipeline run from description" do
          @orchestrator_stub.expects(:call).with(
            nl_input: "a dog walking app where walkers find clients nearby",
            stop_after: :spec
          ).returns(@run)

          result = CreateProduct.call(
            { "description" => "a dog walking app where walkers find clients nearby" },
            @context
          )

          assert_equal @run.id.to_s, result[:run_id]
        end

        test "call returns product name from structured data" do
          result = CreateProduct.call(
            { "description" => "a dog walking app where walkers find clients nearby" },
            @context
          )

          assert_equal "Dog Walking App", result[:product_name]
        end

        test "call returns summary from structured data" do
          result = CreateProduct.call(
            { "description" => "a dog walking app where walkers find clients nearby" },
            @context
          )

          assert_includes result[:summary], "dog walkers with dog owners"
        end

        test "call returns personas" do
          result = CreateProduct.call(
            { "description" => "a dog walking app where walkers find clients nearby" },
            @context
          )

          assert_equal 2, result[:personas].length
          names = result[:personas].map { |p| p[:name] }
          assert_includes names, "Dog Owner"
          assert_includes names, "Dog Walker"
        end

        test "call returns domains" do
          result = CreateProduct.call(
            { "description" => "a dog walking app where walkers find clients nearby" },
            @context
          )

          assert_equal 2, result[:domains].length
          names = result[:domains].map { |d| d[:name] }
          assert_includes names, "Booking"
          assert_includes names, "Messaging"
        end

        test "call returns recipes selected from library selections" do
          result = CreateProduct.call(
            { "description" => "a dog walking app where walkers find clients nearby" },
            @context
          )

          recipe_names = result[:recipes_selected].map { |r| r[:name] }
          assert_includes recipe_names, "Web App"
          assert_includes recipe_names, "API Service"
        end

        test "call returns revision number" do
          result = CreateProduct.call(
            { "description" => "a dog walking app where walkers find clients nearby" },
            @context
          )

          assert_equal "1", result[:revision]
        end

        test "call returns open questions" do
          result = CreateProduct.call(
            { "description" => "a dog walking app where walkers find clients nearby" },
            @context
          )

          assert_equal 2, result[:open_questions].length
          assert result[:open_questions].any? { |q| q.include?("pricing") }
        end

        test "call returns error for empty description" do
          result = CreateProduct.call({ "description" => "" }, @context)
          assert_equal "description is required", result[:error]
        end

        test "call returns error for short description" do
          result = CreateProduct.call({ "description" => "app" }, @context)
          assert_includes result[:error], "at least 10 characters"
        end

        test "call returns error for nil description" do
          result = CreateProduct.call({}, @context)
          assert_equal "description is required", result[:error]
        end

        test "second call creates separate run" do
          second_run = PipelineRun.create!(
            nl_input: "a fitness tracking app",
            status: :paused,
            metadata: { "library_selections" => {} }
          )
          Specification.create!(
            pipeline_run: second_run,
            content: "# Fitness App",
            version: 1,
            structured_data: { "product_name" => "Fitness App" }
          )

          call_count = 0
          @orchestrator_stub.stubs(:call).with { call_count += 1 }.returns(@run, second_run)

          CreateProduct.call({ "description" => "a dog walking app where walkers find clients" }, @context)
          CreateProduct.call({ "description" => "a fitness tracking application" }, @context)

          assert_equal 2, call_count
        end

        test "call handles orchestrator error gracefully" do
          @orchestrator_stub.stubs(:call).raises(StandardError.new("LLM unavailable"))

          result = CreateProduct.call(
            { "description" => "a dog walking app where walkers find clients nearby" },
            @context
          )

          assert_includes result[:error], "Failed to create product"
          assert_includes result[:error], "LLM unavailable"
        end

        test "call falls back to heading for product name when structured_data lacks it" do
          @spec.update!(structured_data: {})

          result = CreateProduct.call(
            { "description" => "a dog walking app where walkers find clients nearby" },
            @context
          )

          assert_equal "Dog Walking App", result[:product_name]
        end

        test "response has all expected keys" do
          result = CreateProduct.call(
            { "description" => "a dog walking app where walkers find clients nearby" },
            @context
          )

          assert result.key?(:run_id)
          assert result.key?(:product_name)
          assert result.key?(:summary)
          assert result.key?(:personas)
          assert result.key?(:domains)
          assert result.key?(:recipes_selected)
          assert result.key?(:revision)
          assert result.key?(:open_questions)
        end
      end
    end
  end
end
