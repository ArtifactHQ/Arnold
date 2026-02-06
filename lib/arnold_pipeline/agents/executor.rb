require "arnold_pipeline/providers/execution/base"

module ArnoldPipeline
  module Agents
    class Executor
      attr_reader :provider, :logger

      def initialize(provider: nil, logger: nil)
        @provider = provider || Providers::Execution.build
        @logger = logger || Logger.new($stdout, level: Logger::WARN)
      end

      def call(tasks:, pipeline_run:)
        logger.info { "Executing #{tasks.size} tasks via #{provider.class.name}" }

        results = provider.create_tasks(tasks:, pipeline_run:)

        results.each do |result|
          task = pipeline_run.tasks.find_by(title: result[:title])
          next unless task

          task.update!(
            external_id: result[:external_id],
            external_url: result[:external_url],
            status: :in_progress
          )
        end

        results
      end

      def fetch_results(pipeline_run:)
        logger.info { "Fetching results for pipeline run ##{pipeline_run.id}" }
        results = provider.fetch_results(pipeline_run:)

        results.each do |result|
          task = pipeline_run.tasks.find(result[:task_id])
          task.update!(result_diff: result[:diffs].to_json)
        end

        results
      end

      def merge_results(pipeline_run:)
        logger.info { "Merging results for pipeline run ##{pipeline_run.id}" }
        provider.merge_results(pipeline_run:)
      end
    end
  end
end
