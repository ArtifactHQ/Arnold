require "test_helper"
require "webmock/minitest"
require "arnold_pipeline/providers/llm/open_ai"

module ArnoldPipeline
  module Providers
    module Llm
      class OpenAiTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Providers::Llm::OpenAi*"

        setup do
          @provider = OpenAi.new(api_key: "sk-test-key", model: "gpt-4")
        end

        test "sends chat request and returns text" do
          stub_request(:post, "https://api.openai.com/v1/chat/completions")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: {
                choices: [ { message: { role: "assistant", content: "Hello from GPT" } } ]
              }.to_json
            )

          result = @provider.chat(messages: [ { role: :user, content: "Hello" } ])
          assert_equal "Hello from GPT", result
        end

        test "includes system message when system prompt provided" do
          stub_request(:post, "https://api.openai.com/v1/chat/completions")
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
          stub_request(:post, "https://api.openai.com/v1/chat/completions")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: { choices: [ { message: { role: "assistant", content: nil } } ] }.to_json
            )

          result = @provider.chat(messages: [ { role: :user, content: "Hi" } ])
          assert_equal "", result
        end

        test "passes request_timeout to client" do
          ::OpenAI::Client.expects(:new).with(access_token: "sk-test-key", request_timeout: 300).returns(stub(chat: {}))
          OpenAi.new(api_key: "sk-test-key", model: "gpt-4", request_timeout: 300)
        end

        test "defaults request_timeout to 600" do
          ::OpenAI::Client.expects(:new).with(access_token: "sk-test-key", request_timeout: 600).returns(stub(chat: {}))
          OpenAi.new(api_key: "sk-test-key", model: "gpt-4")
        end

        test "chat logs response body on 400 error" do
          log_output = StringIO.new
          provider = OpenAi.new(api_key: "sk-test-key", model: "gpt-4",
            logger: Logger.new(log_output))

          stub_request(:post, "https://api.openai.com/v1/chat/completions")
            .to_return(
              status: 400,
              headers: { "Content-Type" => "application/json" },
              body: { error: { message: "invalid request", type: "invalid_request_error" } }.to_json
            )

          assert_raises(Faraday::BadRequestError) do
            provider.chat(messages: [ { role: :user, content: "Hi" } ])
          end

          assert_match(/OpenAI API 400: invalid request/, log_output.string)
        end

        test "chat raises on truncated response" do
          stub_request(:post, "https://api.openai.com/v1/chat/completions")
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

          stub_request(:post, "https://api.openai.com/v1/chat/completions")
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

        test "chat_json strips markdown fences from response" do
          schema = { name: "test_schema", schema: { type: "object", properties: { key: { type: "string" } } } }

          stub_request(:post, "https://api.openai.com/v1/chat/completions")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: {
                choices: [ { message: { role: "assistant", content: "```json\n{\"key\": \"value\"}\n```" } } ]
              }.to_json
            )

          result = @provider.chat_json(
            messages: [ { role: :user, content: "Hello" } ],
            schema: schema
          )
          assert_equal({ "key" => "value" }, result)
        end

        test "chat_json strips leading preamble text from response" do
          schema = { name: "test_schema", schema: { type: "object", properties: { key: { type: "string" } } } }

          stub_request(:post, "https://api.openai.com/v1/chat/completions")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: {
                choices: [ { message: { role: "assistant", content: "Based on the analysis:\n{\"key\": \"value\"}" } } ]
              }.to_json
            )

          result = @provider.chat_json(
            messages: [ { role: :user, content: "Hello" } ],
            schema: schema
          )
          assert_equal({ "key" => "value" }, result)
        end

        test "chat_json raises when content is missing" do
          schema = { name: "test_schema", schema: { type: "object", properties: {} } }

          stub_request(:post, "https://api.openai.com/v1/chat/completions")
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
