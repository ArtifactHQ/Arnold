require "test_helper"
require "webmock/minitest"
require "arnold_pipeline/providers/llm/open_ai"

module ArnoldPipeline
  module Providers
    module Llm
      class OpenAiTest < ActiveSupport::TestCase
        setup do
          @provider = OpenAi.new(api_key: "sk-test-key", model: "gpt-4")
        end

        test "sends chat request and returns text" do
          stub_request(:post, "https://api.openai.com/v1/chat/completions")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: {
                choices: [{ message: { role: "assistant", content: "Hello from GPT" } }]
              }.to_json
            )

          result = @provider.chat(messages: [{ role: :user, content: "Hello" }])
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
                choices: [{ message: { role: "assistant", content: "OK" } }]
              }.to_json
            )

          result = @provider.chat(
            messages: [{ role: :user, content: "Hi" }],
            system: "You are helpful"
          )
          assert_equal "OK", result
        end

        test "returns empty string when no content" do
          stub_request(:post, "https://api.openai.com/v1/chat/completions")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: { choices: [{ message: { role: "assistant", content: nil } }] }.to_json
            )

          result = @provider.chat(messages: [{ role: :user, content: "Hi" }])
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
            provider.chat(messages: [{ role: :user, content: "Hi" }])
          end

          assert_match(/OpenAI API 400: invalid request/, log_output.string)
        end
      end
    end
  end
end
