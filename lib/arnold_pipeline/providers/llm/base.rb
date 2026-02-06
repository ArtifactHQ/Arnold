module ArnoldPipeline
  module Providers
    module Llm
      class Base
        def chat(messages:, system: nil)
          raise NotImplementedError, "#{self.class}#chat must be implemented"
        end
      end

      def self.build(provider: nil, api_key: nil, model: nil)
        config = ArnoldPipeline.configuration
        provider ||= config.llm_provider
        api_key  ||= config.llm_api_key
        model    ||= config.llm_model

        case provider
        when :anthropic
          require_relative "anthropic"
          Anthropic.new(api_key:, model:)
        when :openai
          require_relative "open_ai"
          OpenAi.new(api_key:, model:)
        else
          raise ConfigurationError, "Unknown LLM provider: #{provider}"
        end
      end
    end
  end
end
