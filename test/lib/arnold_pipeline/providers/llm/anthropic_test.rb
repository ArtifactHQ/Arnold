require "test_helper"
require "webmock/minitest"
require "arnold_pipeline/providers/llm/anthropic"

module ArnoldPipeline
  module Providers
    module Llm
      class AnthropicTest < ActiveSupport::TestCase
        setup do
          @provider = Anthropic.new(api_key: "sk-test-key", model: "claude-sonnet-4-20250514")
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
      end
    end
  end
end
