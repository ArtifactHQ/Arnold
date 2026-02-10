require "openai"
require_relative "base"

module ArnoldPipeline
  module Providers
    module Llm
      class OpenAi < Base
        def initialize(api_key:, model:, logger: nil)
          super(logger:)
          @client = ::OpenAI::Client.new(access_token: api_key)
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
          log_api_error("OpenAI", e)
          raise
        end

        private

        def normalize_messages(messages)
          messages.map do |msg|
            { role: msg[:role].to_s, content: msg[:content].to_s }
          end
        end

        def extract_text(response)
          response.dig("choices", 0, "message", "content") || ""
        end
      end
    end
  end
end
