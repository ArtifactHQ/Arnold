require "test_helper"
require "webmock/minitest"
require "arnold_pipeline/providers/llm/anthropic"

module ArnoldPipeline
  module Providers
    module Llm
      class AnthropicTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Providers::Llm::Anthropic*"

        setup do
          @provider = Anthropic.new(api_key: "sk-test-key", model: "claude-sonnet-4-6")
        end

        test "sends chat request and returns text" do
          stub_request(:post, "https://api.anthropic.com/v1/messages")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: {
                content: [{ type: "text", text: "Hello from Claude" }],
                role: "assistant"
              }.to_json
            )

          result = @provider.chat(messages: [{ role: :user, content: "Hello" }])
          assert_equal "Hello from Claude", result
        end

        test "includes system prompt when provided" do
          stub_request(:post, "https://api.anthropic.com/v1/messages")
            .with { |req| JSON.parse(req.body)["system"] == "You are helpful" }
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: { content: [{ type: "text", text: "OK" }] }.to_json
            )

          result = @provider.chat(
            messages: [{ role: :user, content: "Hi" }],
            system: "You are helpful"
          )
          assert_equal "OK", result
        end

        test "returns empty string when no content" do
          stub_request(:post, "https://api.anthropic.com/v1/messages")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: { content: [] }.to_json
            )

          result = @provider.chat(messages: [{ role: :user, content: "Hi" }])
          assert_equal "", result
        end

        test "chat logs response body on 400 error" do
          log_output = StringIO.new
          provider = Anthropic.new(api_key: "sk-test-key", model: "claude-sonnet-4-6",
            logger: Logger.new(log_output))

          stub_request(:post, "https://api.anthropic.com/v1/messages")
            .to_return(
              status: 400,
              headers: { "Content-Type" => "application/json" },
              body: { error: { type: "invalid_request_error", message: "prompt is too long" } }.to_json
            )

          assert_raises(Faraday::BadRequestError) do
            provider.chat(messages: [{ role: :user, content: "Hi" }])
          end

          assert_match(/Anthropic API 400: prompt is too long/, log_output.string)
        end

        test "passes request_timeout to client" do
          ::Anthropic::Client.expects(:new).with(access_token: "sk-test-key", request_timeout: 300).returns(stub(messages: {}))
          Anthropic.new(api_key: "sk-test-key", model: "claude-sonnet-4-6", request_timeout: 300)
        end

        test "defaults request_timeout to 600" do
          ::Anthropic::Client.expects(:new).with(access_token: "sk-test-key", request_timeout: 600).returns(stub(messages: {}))
          Anthropic.new(api_key: "sk-test-key", model: "claude-sonnet-4-6")
        end

        test "chat logs response body on 429 error" do
          log_output = StringIO.new
          provider = Anthropic.new(api_key: "sk-test-key", model: "claude-sonnet-4-6",
            logger: Logger.new(log_output))

          stub_request(:post, "https://api.anthropic.com/v1/messages")
            .to_return(
              status: 429,
              headers: { "Content-Type" => "application/json" },
              body: { error: { type: "rate_limit_error", message: "rate limit exceeded" } }.to_json
            )

          assert_raises(Faraday::ClientError) do
            provider.chat(messages: [{ role: :user, content: "Hi" }])
          end

          assert_match(/Anthropic API 429: rate limit exceeded/, log_output.string)
        end

        test "chat raises on truncated response" do
          stub_request(:post, "https://api.anthropic.com/v1/messages")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: {
                content: [{ type: "text", text: "Truncated content..." }],
                stop_reason: "max_tokens",
                usage: { output_tokens: 16_384 }
              }.to_json
            )

          error = assert_raises(ArnoldPipeline::Error) do
            @provider.chat(messages: [{ role: :user, content: "Generate a long spec" }])
          end
          assert_match(/Response truncated/, error.message)
          assert_match(/16384/, error.message)
        end

        # -- chat_json tests --

        test "chat_json returns parsed hash from tool_use response" do
          schema = { name: "test_tool", schema: { type: "object", properties: { key: { type: "string" } } } }

          stub_request(:post, "https://api.anthropic.com/v1/messages")
            .with { |req|
              body = JSON.parse(req.body)
              body["tools"].first["name"] == "test_tool" &&
                body["tool_choice"] == { "type" => "tool", "name" => "test_tool" }
            }
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: {
                content: [{ type: "tool_use", id: "toolu_123", name: "test_tool", input: { "key" => "value" } }],
                role: "assistant"
              }.to_json
            )

          result = @provider.chat_json(
            messages: [{ role: :user, content: "Hello" }],
            schema: schema
          )
          assert_instance_of Hash, result
          assert_equal "value", result["key"]
        end

        test "chat_json raises when no tool_use block in response" do
          schema = { name: "test_tool", schema: { type: "object", properties: {} } }

          stub_request(:post, "https://api.anthropic.com/v1/messages")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: {
                content: [{ type: "text", text: "No tool use here" }],
                role: "assistant"
              }.to_json
            )

          error = assert_raises(ArnoldPipeline::Error) do
            @provider.chat_json(messages: [{ role: :user, content: "Hi" }], schema: schema)
          end
          assert_match(/No tool_use block/, error.message)
        end
      end
    end
  end
end
