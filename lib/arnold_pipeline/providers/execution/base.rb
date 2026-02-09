module ArnoldPipeline
  module Providers
    module Execution
      class Base
        def create_tasks(tasks:, pipeline_run:, prior_context: nil)
          raise NotImplementedError, "#{self.class}#create_tasks must be implemented"
        end

        def fetch_results(pipeline_run:, tasks: nil)
          raise NotImplementedError, "#{self.class}#fetch_results must be implemented"
        end

        def merge_results(pipeline_run:, tasks: nil)
          raise NotImplementedError, "#{self.class}#merge_results must be implemented"
        end

        def async?
          true
        end

        def recoverable_errors
          []
        end

        def self.validate_configuration!(config)
          # no-op by default; providers override
        end

        def self.build_from_config(config, **options)
          new(**options)
        end
      end

      REGISTRY = {}

      def self.register(name, klass)
        REGISTRY[name.to_sym] = klass
      end

      def self.registered_providers
        REGISTRY.keys
      end

      def self.provider_class_for(provider)
        provider = provider.to_sym

        # Built-in providers loaded on demand
        if provider == :github && !REGISTRY.key?(:github)
          require_relative "github"
        end
        if provider == :null && !REGISTRY.key?(:null)
          require_relative "null"
        end

        REGISTRY[provider] || raise(ConfigurationError, "Unknown execution provider: #{provider}")
      end

      def self.build(provider: nil, **options)
        config = ArnoldPipeline.configuration
        provider ||= config.execution_provider

        klass = provider_class_for(provider)
        klass.build_from_config(config, **options)
      end
    end
  end
end
