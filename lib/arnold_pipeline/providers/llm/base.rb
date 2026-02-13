require "logger"

module ArnoldPipeline
  module Providers
    module Llm
      class Base
        attr_reader :logger

        def initialize(logger: nil)
          @logger = logger || default_logger
        end

        def chat(messages:, system: nil)
          raise NotImplementedError, "#{self.class}#chat must be implemented"
        end

        def chat_json(messages:, system: nil, schema:)
          raise NotImplementedError, "#{self.class}#chat_json must be implemented"
        end

        private

        def log_api_error(provider_name, error)
          body = error.response_body
          detail = body.is_a?(Hash) ? body.dig("error", "message") : body.to_s
          logger.error { "#{provider_name} API #{error.response_status}: #{detail}" }
        rescue => _log_err
          logger.error { "#{provider_name} API error (could not parse body): #{error.message}" }
        end

        def default_logger
          Logger.new($stdout, level: Logger::WARN)
        end
      end

      def self.build(provider: nil, api_key: nil, model: nil)
        config = ArnoldPipeline.configuration
        provider ||= config.llm_provider
        api_key  ||= config.llm_api_key
        model    ||= config.llm_model
        request_timeout = config.llm_request_timeout

        if api_key.nil? || api_key.to_s.empty?
          env_var = Configuration::PROVIDER_DEFAULTS.dig(provider, :env_key)
          raise ConfigurationError,
            "LLM API key is required. Set #{env_var} environment variable or use --provider to select a different provider."
        end

        case provider
        when :anthropic
          require_relative "anthropic"
          Anthropic.new(api_key:, model:, request_timeout:)
        when :openai
          require_relative "open_ai"
          OpenAi.new(api_key:, model:, request_timeout:)
        else
          raise ConfigurationError, "Unknown LLM provider: #{provider}"
        end
      end
    end
  end
end
