require "anthropic"
require_relative "base"

module ArnoldPipeline
  module Providers
    module Llm
      class Anthropic < Base
        DEFAULT_MAX_TOKENS = 16_384

        def initialize(api_key:, model:, request_timeout: 600, logger: nil)
          super(logger:)
          @client = ::Anthropic::Client.new(access_token: api_key, request_timeout: request_timeout)
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

        def chat_json(messages:, system: nil, schema:)
          tool_name = schema[:name]
          params = {
            model: @model,
            max_tokens: DEFAULT_MAX_TOKENS,
            messages: normalize_messages(messages),
            tools: [ { name: tool_name, input_schema: schema[:schema] } ],
            tool_choice: { type: "tool", name: tool_name }
          }
          params[:system] = system if system

          response = @client.messages(parameters: params)
          extract_tool_input(response, tool_name)
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
          if response["stop_reason"] == "max_tokens"
            usage = response["usage"] || {}
            raise ArnoldPipeline::Error,
              "Response truncated (max_tokens: #{DEFAULT_MAX_TOKENS}, used: #{usage['output_tokens'] || '?'}). " \
              "The LLM response exceeded the token limit and was cut off."
          end

          response.dig("content", 0, "text") || ""
        end

        def extract_tool_input(response, tool_name)
          if response["stop_reason"] == "max_tokens"
            usage = response["usage"] || {}
            raise ArnoldPipeline::Error,
              "Response truncated (max_tokens: #{DEFAULT_MAX_TOKENS}, used: #{usage['output_tokens'] || '?'}). " \
              "The structured output for '#{tool_name}' exceeded the token limit."
          end

          blocks = response["content"] || []
          tool_block = blocks.find { |b| b["type"] == "tool_use" && b["name"] == tool_name }
          raise ArnoldPipeline::Error, "No tool_use block for '#{tool_name}' in response" unless tool_block

          tool_block["input"]
        end
      end
    end
  end
end
