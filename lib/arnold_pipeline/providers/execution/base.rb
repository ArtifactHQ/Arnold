module ArnoldPipeline
  module Providers
    module Execution
      class Base
        def create_tasks(tasks:, pipeline_run:)
          raise NotImplementedError, "#{self.class}#create_tasks must be implemented"
        end

        def fetch_results(pipeline_run:, tasks: nil)
          raise NotImplementedError, "#{self.class}#fetch_results must be implemented"
        end

        def merge_results(pipeline_run:, tasks: nil)
          raise NotImplementedError, "#{self.class}#merge_results must be implemented"
        end
      end

      def self.build(provider: nil, **options)
        config = ArnoldPipeline.configuration
        provider ||= config.execution_provider

        case provider
        when :github
          require_relative "github"
          Github.new(
            token: options[:token] || config.github_token,
            repo: options[:repo] || config.github_repo,
            issue_mention: options[:issue_mention] || config.github_issue_mention
          )
        else
          raise ConfigurationError, "Unknown execution provider: #{provider}"
        end
      end
    end
  end
end
