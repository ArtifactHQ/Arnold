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

        if api_key.nil? || api_key.to_s.empty?
          env_var = Configuration::PROVIDER_DEFAULTS.dig(provider, :env_key)
          raise ConfigurationError,
            "LLM API key is required. Set #{env_var} environment variable or use --provider to select a different provider."
        end

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
