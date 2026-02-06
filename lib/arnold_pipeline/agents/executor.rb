require "arnold_pipeline/providers/execution/base"

module ArnoldPipeline
  module Agents
    class Executor
      attr_reader :provider, :logger, :sleep_func

      def initialize(provider: nil, logger: nil, sleep_func: Kernel.method(:sleep))
        @provider = provider || Providers::Execution.build
        @logger = logger || Logger.new($stdout, level: Logger::WARN)
        @sleep_func = sleep_func
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

      def await_results(pipeline_run:)
        config = ArnoldPipeline.configuration
        interval = config.polling_interval
        timeout = config.polling_timeout
        max_interval = config.polling_max_interval
        elapsed = 0

        loop do
          fetch_results(pipeline_run:)

          tasks = pipeline_run.tasks.reload
          trackable = tasks.select { |t| t.external_id.present? }
          completed = trackable.count { |t| t.result_diff.present? && t.result_diff != "[]" }
          total = trackable.size

          if completed >= total
            logger.info { "All #{total} tasks have results." }
            break
          end

          if elapsed >= timeout
            logger.warn { "Polling timed out after #{elapsed}s. #{completed}/#{total} tasks have results." }
            break
          end

          remaining = timeout - elapsed
          sleep_time = [interval, remaining].min

          logger.info { "Waiting for PRs... #{completed}/#{total} tasks have results. Next check in #{sleep_time}s" }

          sleep_func.call(sleep_time)
          elapsed += sleep_time
          interval = [interval * 2, max_interval].min
        end
      end

      def merge_results(pipeline_run:)
        logger.info { "Merging results for pipeline run ##{pipeline_run.id}" }
        provider.merge_results(pipeline_run:)
      end
    end
  end
end
