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
        unpublished = tasks.reject do |t|
          t.respond_to?(:external_id) ? t.external_id.present? : t["external_id"].present?
        end

        logger.info { "Executing #{unpublished.size} tasks via #{provider.class.name}" }
        return [] if unpublished.empty?

        results = provider.create_tasks(tasks: unpublished, pipeline_run:)

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
          updates = { result_diff: result[:diffs].to_json }
          updates[:result_comments] = result[:comments] if result[:comments]
          updates[:status] = :failed if result[:status] == :failed
          task.update!(updates)
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
          resolved = trackable.count { |t| task_resolved?(t) }
          total = trackable.size

          if resolved >= total
            logger.info { "All #{total} tasks resolved." }
            break
          end

          if elapsed >= timeout
            logger.warn { "Polling timed out after #{elapsed}s. #{resolved}/#{total} tasks resolved." }
            break
          end

          remaining = timeout - elapsed
          sleep_time = [interval, remaining].min

          logger.info { "Waiting for results... #{resolved}/#{total} tasks resolved. Next check in #{sleep_time}s" }

          sleep_func.call(sleep_time)
          elapsed += sleep_time
          interval = [interval * 2, max_interval].min
        end
      end

      def merge_results(pipeline_run:)
        logger.info { "Merging results for pipeline run ##{pipeline_run.id}" }
        provider.merge_results(pipeline_run:)
      end

      private

      def task_resolved?(task)
        (task.result_diff.present? && task.result_diff != "[]") ||
          task.failed? ||
          task.result_comments.present?
      end
    end
  end
end
