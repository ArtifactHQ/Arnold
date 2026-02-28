require "test_helper"
require "arnold_pipeline/agents/spec_test_generator"
require "json_schemer"

module ArnoldPipeline
  module Agents
    class SpecTestGeneratorTest < ActiveSupport::TestCase
      cover "ArnoldPipeline::Agents::SpecTestGenerator*"

      setup do
        @llm = stub("llm")
        @agent = SpecTestGenerator.new(llm: @llm, logger: Logger.new(File::NULL))
        ArnoldPipeline.configure do |c|
          c.spec_test_directory = "test/spec_integration"
          c.spec_test_persona = "testing_specialist"
        end
      end

      teardown do
        ArnoldPipeline.reset_configuration!
      end

      test "generates test files from spec content" do
        result = {
          "test_files" => [
            {
              "path" => "test/spec_integration/req_auth_001_test.rb",
              "content" => "require 'test_helper'\nclass ReqAuth001Test < ActionDispatch::IntegrationTest\nend",
              "requirement_ids" => [ "REQ-AUTH-001" ]
            }
          ]
        }
        @llm.expects(:chat_json).returns(result)

        response = @agent.call(spec_content: "## Requirements\n### Requirement: Login")

        assert_equal 1, response["test_files"].size
        assert_equal "test/spec_integration/req_auth_001_test.rb", response["test_files"].first["path"]
        assert_includes response["test_files"].first["content"], "ReqAuth001Test"
      end

      test "generates multiple test files" do
        result = {
          "test_files" => [
            {
              "path" => "test/spec_integration/req_auth_001_test.rb",
              "content" => "class ReqAuth001Test; end",
              "requirement_ids" => [ "REQ-AUTH-001" ]
            },
            {
              "path" => "test/spec_integration/req_auth_002_test.rb",
              "content" => "class ReqAuth002Test; end",
              "requirement_ids" => [ "REQ-AUTH-002" ]
            }
          ]
        }
        @llm.expects(:chat_json).returns(result)

        response = @agent.call(spec_content: "spec with multiple requirements")
        assert_equal 2, response["test_files"].size
      end

      test "uses configured test_directory" do
        ArnoldPipeline.configure { |c| c.spec_test_directory = "spec/integration" }

        @llm.expects(:chat_json).with { |params|
          user_msg = params[:messages].first[:content]
          user_msg.include?("spec/integration/")
        }.returns({
          "test_files" => [
            { "path" => "spec/integration/req_001_test.rb", "content" => "test", "requirement_ids" => [ "REQ-001" ] }
          ]
        })

        @agent.call(spec_content: "spec content")
      end

      test "accepts custom test_directory parameter" do
        @llm.expects(:chat_json).with { |params|
          user_msg = params[:messages].first[:content]
          user_msg.include?("custom/tests/")
        }.returns({
          "test_files" => [
            { "path" => "custom/tests/test.rb", "content" => "test", "requirement_ids" => [ "REQ-001" ] }
          ]
        })

        @agent.call(spec_content: "spec content", test_directory: "custom/tests")
      end

      test "raises on invalid result type" do
        @llm.expects(:chat_json).returns("not a hash")

        assert_raises(ArnoldPipeline::Error) do
          @agent.call(spec_content: "spec content")
        end
      end

      test "raises on missing test_files" do
        @llm.expects(:chat_json).returns({ "test_files" => "not an array" })

        assert_raises(ArnoldPipeline::Error) do
          @agent.call(spec_content: "spec content")
        end
      end

      test "raises on test_file without path" do
        @llm.expects(:chat_json).returns({
          "test_files" => [ { "content" => "test code", "requirement_ids" => [] } ]
        })

        assert_raises(ArnoldPipeline::Error) do
          @agent.call(spec_content: "spec content")
        end
      end

      test "raises on test_file with empty content" do
        @llm.expects(:chat_json).returns({
          "test_files" => [ { "path" => "test.rb", "content" => "  ", "requirement_ids" => [] } ]
        })

        assert_raises(ArnoldPipeline::Error) do
          @agent.call(spec_content: "spec content")
        end
      end

      test "passes recipe framework to prompt" do
        recipe = stub(framework: { "language" => "Ruby", "name" => "Rails" })

        @llm.expects(:chat_json).with { |params|
          params[:system].include?("Ruby") && params[:system].include?("Rails")
        }.returns({
          "test_files" => [
            { "path" => "test/test.rb", "content" => "test", "requirement_ids" => [] }
          ]
        })

        @agent.call(spec_content: "spec", recipe: recipe)
      end

      # -- Schema validation --

      test "RESPONSE_SCHEMA validates a valid result" do
        schemer = JSONSchemer.schema(SpecTestGenerator::RESPONSE_SCHEMA[:schema])
        data = {
          "test_files" => [
            {
              "path" => "test/spec_integration/req_auth_001_test.rb",
              "content" => "require 'test_helper'\nclass Test < Minitest::Test\nend",
              "requirement_ids" => [ "REQ-AUTH-001" ]
            }
          ]
        }
        assert schemer.valid?(data), "Expected valid, got: #{schemer.validate(data).map(&:to_h)}"
      end

      test "RESPONSE_SCHEMA rejects missing test_files" do
        schemer = JSONSchemer.schema(SpecTestGenerator::RESPONSE_SCHEMA[:schema])
        data = {}
        refute schemer.valid?(data)
      end

      test "RESPONSE_SCHEMA rejects test_file without required fields" do
        schemer = JSONSchemer.schema(SpecTestGenerator::RESPONSE_SCHEMA[:schema])
        data = { "test_files" => [ { "path" => "test.rb" } ] }
        refute schemer.valid?(data)
      end
    end
  end
end
