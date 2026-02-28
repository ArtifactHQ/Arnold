require "test_helper"
require "arnold_pipeline/agents/spec_generator"
require "arnold_pipeline/library/manager"

module ArnoldPipeline
  module Agents
    class SpecGeneratorTest < ActiveSupport::TestCase
      cover "ArnoldPipeline::Agents::SpecGenerator*"

      setup do
        @llm = stub("llm")
        @agent = SpecGenerator.new(llm: @llm, logger: Logger.new(File::NULL))
        @manager = Library::Manager.new
        @persona = @manager.find_persona("web app")
        @recipe = @manager.find_recipe("web app")
        @domain_type = @manager.find_domain_type("web app")
      end

      test "generates spec with content and structured data" do
        json_data = { "features" => [ "auth", "dashboard" ], "tech_stack" => { "backend" => "Rails" } }
        llm_response = "# App Spec\n\nSome content\n\n```json\n#{JSON.generate(json_data)}\n```"

        @llm.expects(:chat).returns(llm_response)

        result = @agent.call(nl_input: "Build a todo app", persona: @persona, recipe: @recipe, domain_type: @domain_type)

        assert_equal llm_response, result[:content]
        assert_equal json_data, result[:structured_data]
      end

      test "returns nil structured_data when JSON not parseable" do
        @llm.expects(:chat).returns("Just plain text with no JSON")

        result = @agent.call(nl_input: "Build a todo app", persona: @persona, recipe: @recipe, domain_type: @domain_type)

        assert_equal "Just plain text with no JSON", result[:content]
        assert_nil result[:structured_data]
      end
    end
  end
end
