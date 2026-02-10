require "anthropic"
require_relative "base"

module ArnoldPipeline
  module Providers
    module Llm
      class Anthropic < Base
        DEFAULT_MAX_TOKENS = 4096

        def initialize(api_key:, model:, logger: nil)
          super(logger:)
          @client = ::Anthropic::Client.new(access_token: api_key)
          @model = model
        end

        def chat(messages:, system: nil)
          params = {
            model: @model,
            max_tokens: DEFAULT_MAX_TOKENS,
            messages: normalize_messages(messages)
          }
          params[:system] = system if system

          response = @client.messages(parameters: params)
          extract_text(response)
        rescue Faraday::ClientError => e
          log_api_error("Anthropic", e)
          raise
        end

        private

        def normalize_messages(messages)
          messages.map do |msg|
            { role: msg[:role].to_s, content: msg[:content].to_s }
          end
        end

        def extract_text(response)
          response.dig("content", 0, "text") || ""
        end
      end
    end
  end
end
