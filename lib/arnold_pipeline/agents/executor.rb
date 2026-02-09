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

      def call(tasks:, pipeline_run:, prior_context: nil)
        unpublished = tasks.reject do |t|
          t.respond_to?(:external_id) ? t.external_id.present? : t["external_id"].present?
        end

        logger.info { "[Arnold] Publishing #{unpublished.size} tasks to GitHub..." }
        return [] if unpublished.empty?

        results = provider.create_tasks(tasks: unpublished, pipeline_run:, prior_context:)

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

      def fetch_results(pipeline_run:, tasks: nil)
        logger.info { "[Arnold] Fetching results for pipeline run ##{pipeline_run.id}" }
        results = provider.fetch_results(pipeline_run:, tasks:)

        results.each do |result|
          task = pipeline_run.tasks.find(result[:task_id])
          updates = { result_diff: result[:diffs].to_json }
          updates[:result_comments] = result[:comments] if result[:comments]
          updates[:status] = :failed if result[:status] == :failed
          updates[:workflow_active] = result[:workflow_active] if result.key?(:workflow_active)
          task.update!(updates)

          logger.debug {
            "Task ##{result[:external_id]}: diffs=#{result[:diffs].size}, " \
            "comments=#{(result[:comments] || []).size}, " \
            "status=#{result[:status]}, workflow_active=#{result[:workflow_active]}" \
            "#{result[:workflow_details] ? " (#{result[:workflow_details]})" : ""}"
          }
        end

        results
      end

      def await_results(pipeline_run:, tasks: nil)
        config = ArnoldPipeline.configuration
        interval = config.polling_interval
        timeout = config.polling_timeout
        max_interval = config.polling_max_interval
        elapsed = 0

        loop do
          fetch_results(pipeline_run:, tasks:)

          trackable = if tasks
            tasks.map(&:reload).select { |t| t.external_id.present? }
          else
            pipeline_run.tasks.reload.select { |t| t.external_id.present? }
          end

          resolved = trackable.count { |t| task_resolved?(t) }
          total = trackable.size

          logger.debug {
            trackable.map { |t| "  #{t.resolution_summary}" }.join("\n")
          }

          if resolved >= total
            logger.info { "[Arnold] All #{total} tasks resolved." }
            break
          end

          if elapsed >= timeout
            logger.warn { "[Arnold] Polling timed out after #{elapsed}s. #{resolved}/#{total} tasks resolved." }
            break
          end

          remaining = timeout - elapsed
          sleep_time = [interval, remaining].min

          logger.info { "[Arnold] Polling... elapsed: #{elapsed}s, resolved: #{resolved}/#{total} tasks. Next check in #{sleep_time}s" }

          sleep_func.call(sleep_time)
          elapsed += sleep_time
          interval = [interval * 2, max_interval].min
        end
      end

      def merge_results(pipeline_run:, tasks: nil)
        logger.info { "[Arnold] Merging results for pipeline run ##{pipeline_run.id}" }
        provider.merge_results(pipeline_run:, tasks:)
      end

      private

      def task_resolved?(task)
        if task.workflow_active?
          logger.debug { "  #{task.resolution_summary} → NOT RESOLVED (workflow active)" }
          return false
        end

        resolved = (task.result_diff.present? && task.result_diff != "[]") ||
          task.failed? ||
          task.has_substantive_comments?

        logger.debug { "  #{task.resolution_summary} → #{resolved ? 'RESOLVED' : 'NOT RESOLVED'}" }
        resolved
      end
    end
  end
end
