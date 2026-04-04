require "test_helper"
require "arnold_pipeline/providers/llm/base"

module ArnoldPipeline
  module Providers
    module Llm
      class BaseTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Providers::Llm::Base*"

        test "build creates Anthropic provider" do
          ArnoldPipeline.configure do |c|
            c.llm_provider = :anthropic
            c.llm_api_key = "sk-test"
            c.llm_model = "claude-sonnet-4-6"
          end

          provider = Llm.build
          assert_kind_of Anthropic, provider
        ensure
          ArnoldPipeline.reset_configuration!
        end

        test "build creates OpenAI provider" do
          provider = Llm.build(provider: :openai, api_key: "sk-test", model: "gpt-4")
          assert_kind_of OpenAi, provider
        end

        test "build creates OpenRouter provider" do
          provider = Llm.build(provider: :openrouter, api_key: "sk-or-test", model: "anthropic/claude-sonnet-4")
          assert_kind_of OpenRouter, provider
        end

        test "build raises on unknown provider" do
          assert_raises(ConfigurationError) do
            Llm.build(provider: :unknown, api_key: "sk-test", model: "x")
          end
        end

        test "build raises ConfigurationError when api_key is nil" do
          original_anthropic = ENV["ANTHROPIC_API_KEY"]
          original_openai = ENV["OPENAI_API_KEY"]
          original_openrouter = ENV["OPENROUTER_API_KEY"]
          ENV.delete("ANTHROPIC_API_KEY")
          ENV.delete("OPENAI_API_KEY")
          ENV.delete("OPENROUTER_API_KEY")
          ArnoldPipeline.configure { |c| c.llm_api_key = nil }

          error = assert_raises(ConfigurationError) do
            Llm.build(provider: :anthropic, model: "claude-sonnet-4-6")
          end
          assert_match(/LLM API key is required/, error.message)
        ensure
          original_anthropic ? ENV["ANTHROPIC_API_KEY"] = original_anthropic : ENV.delete("ANTHROPIC_API_KEY")
          original_openai ? ENV["OPENAI_API_KEY"] = original_openai : ENV.delete("OPENAI_API_KEY")
          original_openrouter ? ENV["OPENROUTER_API_KEY"] = original_openrouter : ENV.delete("OPENROUTER_API_KEY")
          ArnoldPipeline.reset_configuration!
        end

        test "build raises ConfigurationError when api_key is empty" do
          error = assert_raises(ConfigurationError) do
            Llm.build(provider: :openai, api_key: "", model: "gpt-4o")
          end
          assert_match(/LLM API key is required/, error.message)
        end

        test "build passes llm_request_timeout to provider" do
          ArnoldPipeline.configure do |c|
            c.llm_provider = :anthropic
            c.llm_api_key = "sk-test"
            c.llm_model = "claude-sonnet-4-6"
            c.llm_request_timeout = 900
          end

          Anthropic.expects(:new).with(api_key: "sk-test", model: "claude-sonnet-4-6", request_timeout: 900).returns(stub)
          Llm.build
        ensure
          ArnoldPipeline.reset_configuration!
        end

        test "base class raises NotImplementedError" do
          assert_raises(NotImplementedError) do
            Base.new.chat(messages: [])
          end
        end

        # -- parse_json_content tests (fence stripping) --

        test "parse_json_content parses clean JSON" do
          provider = Base.new
          response = { "choices" => [ { "message" => { "content" => '{"key": "value"}' } } ] }
          assert_equal({ "key" => "value" }, provider.send(:parse_json_content, response))
        end

        test "parse_json_content strips markdown json fences" do
          provider = Base.new
          content = "```json\n{\"key\": \"value\"}\n```"
          response = { "choices" => [ { "message" => { "content" => content } } ] }
          assert_equal({ "key" => "value" }, provider.send(:parse_json_content, response))
        end

        test "parse_json_content strips untagged markdown fences" do
          provider = Base.new
          content = "```\n{\"key\": \"value\"}\n```"
          response = { "choices" => [ { "message" => { "content" => content } } ] }
          assert_equal({ "key" => "value" }, provider.send(:parse_json_content, response))
        end

        test "parse_json_content strips leading preamble text" do
          provider = Base.new
          content = "Based on my analysis, here is the result:\n{\"key\": \"value\"}"
          response = { "choices" => [ { "message" => { "content" => content } } ] }
          assert_equal({ "key" => "value" }, provider.send(:parse_json_content, response))
        end

        test "parse_json_content handles array in fences" do
          provider = Base.new
          content = "```json\n[{\"a\": 1}, {\"b\": 2}]\n```"
          response = { "choices" => [ { "message" => { "content" => content } } ] }
          assert_equal([ { "a" => 1 }, { "b" => 2 } ], provider.send(:parse_json_content, response))
        end

        test "parse_json_content raises on nil content" do
          provider = Base.new
          response = { "choices" => [ { "message" => { "content" => nil } } ] }
          error = assert_raises(ArnoldPipeline::Error) do
            provider.send(:parse_json_content, response)
          end
          assert_match(/No content in structured output/, error.message)
        end

        test "parse_json_content raises on completely unparseable content" do
          provider = Base.new
          response = { "choices" => [ { "message" => { "content" => "No JSON here at all" } } ] }
          error = assert_raises(ArnoldPipeline::Error) do
            provider.send(:parse_json_content, response)
          end
          assert_match(/Failed to parse structured output JSON/, error.message)
        end
      end
    end
  end
end
