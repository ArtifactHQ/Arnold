require "test_helper"
require "webmock/minitest"
require "arnold_pipeline/providers/llm/open_router"

module ArnoldPipeline
  module Providers
    module Llm
      class OpenRouterTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Providers::Llm::OpenRouter*"

        setup do
          @provider = OpenRouter.new(api_key: "sk-or-test-key", model: "anthropic/claude-sonnet-4")
        end

        test "sends chat request and returns text" do
          stub_request(:post, "https://openrouter.ai/api/v1/chat/completions")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: {
                choices: [ { message: { role: "assistant", content: "Hello from OpenRouter" } } ]
              }.to_json
            )

          result = @provider.chat(messages: [ { role: :user, content: "Hello" } ])
          assert_equal "Hello from OpenRouter", result
        end

        test "includes system message when system prompt provided" do
          stub_request(:post, "https://openrouter.ai/api/v1/chat/completions")
            .with { |req|
              messages = JSON.parse(req.body)["messages"]
              messages.first["role"] == "system" && messages.first["content"] == "You are helpful"
            }
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: {
                choices: [ { message: { role: "assistant", content: "OK" } } ]
              }.to_json
            )

          result = @provider.chat(
            messages: [ { role: :user, content: "Hi" } ],
            system: "You are helpful"
          )
          assert_equal "OK", result
        end

        test "returns empty string when no content" do
          stub_request(:post, "https://openrouter.ai/api/v1/chat/completions")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: { choices: [ { message: { role: "assistant", content: nil } } ] }.to_json
            )

          result = @provider.chat(messages: [ { role: :user, content: "Hi" } ])
          assert_equal "", result
        end

        test "passes request_timeout to client" do
          ::OpenAI::Client.expects(:new).with(
            access_token: "sk-or-test-key",
            uri_base: "https://openrouter.ai/api/v1",
            request_timeout: 300,
            extra_headers: {
              "HTTP-Referer" => "https://github.com/ArtifactHQ/Arnold",
              "X-Title" => "Arnold Pipeline"
            }
          ).returns(stub(chat: {}))
          OpenRouter.new(api_key: "sk-or-test-key", model: "anthropic/claude-sonnet-4", request_timeout: 300)
        end

        test "defaults request_timeout to 600" do
          ::OpenAI::Client.expects(:new).with(
            access_token: "sk-or-test-key",
            uri_base: "https://openrouter.ai/api/v1",
            request_timeout: 600,
            extra_headers: {
              "HTTP-Referer" => "https://github.com/ArtifactHQ/Arnold",
              "X-Title" => "Arnold Pipeline"
            }
          ).returns(stub(chat: {}))
          OpenRouter.new(api_key: "sk-or-test-key", model: "anthropic/claude-sonnet-4")
        end

        test "passes uri_base and extra_headers to client" do
          stub_request(:post, "https://openrouter.ai/api/v1/chat/completions")
            .with { |req|
              req.headers["Http-Referer"] == "https://github.com/ArtifactHQ/Arnold" &&
                req.headers["X-Title"] == "Arnold Pipeline"
            }
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: {
                choices: [ { message: { role: "assistant", content: "OK" } } ]
              }.to_json
            )

          result = @provider.chat(messages: [ { role: :user, content: "Hi" } ])
          assert_equal "OK", result
        end

        test "chat logs response body on 400 error" do
          log_output = StringIO.new
          provider = OpenRouter.new(api_key: "sk-or-test-key", model: "anthropic/claude-sonnet-4",
            logger: Logger.new(log_output))

          stub_request(:post, "https://openrouter.ai/api/v1/chat/completions")
            .to_return(
              status: 400,
              headers: { "Content-Type" => "application/json" },
              body: { error: { message: "invalid request", type: "invalid_request_error" } }.to_json
            )

          assert_raises(Faraday::BadRequestError) do
            provider.chat(messages: [ { role: :user, content: "Hi" } ])
          end

          assert_match(/OpenRouter API 400: invalid request/, log_output.string)
        end

        test "chat raises on truncated response" do
          stub_request(:post, "https://openrouter.ai/api/v1/chat/completions")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: {
                choices: [ { message: { role: "assistant", content: "Truncated..." }, finish_reason: "length" } ]
              }.to_json
            )

          error = assert_raises(ArnoldPipeline::Error) do
            @provider.chat(messages: [ { role: :user, content: "Generate a long spec" } ])
          end
          assert_match(/Response truncated/, error.message)
          assert_match(/finish_reason: length/, error.message)
        end

        # -- chat_json tests --

        test "chat_json returns parsed hash from structured output response" do
          schema = { name: "test_schema", schema: { type: "object", properties: { key: { type: "string" } } } }

          stub_request(:post, "https://openrouter.ai/api/v1/chat/completions")
            .with { |req|
              body = JSON.parse(req.body)
              body["response_format"]["type"] == "json_schema" &&
                body["response_format"]["json_schema"]["name"] == "test_schema" &&
                body["response_format"]["json_schema"]["strict"] == true
            }
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: {
                choices: [ { message: { role: "assistant", content: '{"key": "value"}' } } ]
              }.to_json
            )

          result = @provider.chat_json(
            messages: [ { role: :user, content: "Hello" } ],
            schema: schema
          )
          assert_instance_of Hash, result
          assert_equal "value", result["key"]
        end

        test "chat_json raises when content is missing" do
          schema = { name: "test_schema", schema: { type: "object", properties: {} } }

          stub_request(:post, "https://openrouter.ai/api/v1/chat/completions")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: {
                choices: [ { message: { role: "assistant", content: nil } } ]
              }.to_json
            )

          error = assert_raises(ArnoldPipeline::Error) do
            @provider.chat_json(messages: [ { role: :user, content: "Hi" } ], schema: schema)
          end
          assert_match(/No content in structured output/, error.message)
        end
      end
    end
  end
end
