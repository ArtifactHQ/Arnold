require "openai"
require_relative "base"

module ArnoldPipeline
  module Providers
    module Llm
      class OpenRouter < Base
        def initialize(api_key:, model:, request_timeout: 600, logger: nil)
          super(logger:)
          @client = ::OpenAI::Client.new(
            access_token: api_key,
            uri_base: "https://openrouter.ai/api/v1",
            request_timeout: request_timeout,
            extra_headers: {
              "HTTP-Referer" => "https://github.com/ArtifactHQ/Arnold",
              "X-Title" => "Arnold Pipeline"
            }
          )
          @model = model
        end

        def chat(messages:, system: nil)
          all_messages = []
          all_messages << { role: "system", content: system } if system
          all_messages.concat(normalize_messages(messages))

          response = @client.chat(parameters: {
            model: @model,
            messages: all_messages
          })

          extract_text(response)
        rescue Faraday::ClientError => e
          log_api_error("OpenRouter", e)
          raise
        end

        def chat_json(messages:, system: nil, schema:)
          all_messages = []
          all_messages << { role: "system", content: system } if system
          all_messages.concat(normalize_messages(messages))

          response = @client.chat(parameters: {
            model: @model,
            messages: all_messages,
            response_format: {
              type: "json_schema",
              json_schema: { name: schema[:name], strict: true, schema: schema[:schema] }
            }
          })

          parse_json_content(response)
        rescue Faraday::ClientError => e
          log_api_error("OpenRouter", e)
          raise
        end

        private

        def normalize_messages(messages)
          messages.map do |msg|
            { role: msg[:role].to_s, content: msg[:content].to_s }
          end
        end

        def extract_text(response)
          if response.dig("choices", 0, "finish_reason") == "length"
            raise ArnoldPipeline::Error,
              "Response truncated (finish_reason: length). " \
              "The LLM response exceeded the token limit and was cut off."
          end

          response.dig("choices", 0, "message", "content") || ""
        end
      end
    end
  end
end
