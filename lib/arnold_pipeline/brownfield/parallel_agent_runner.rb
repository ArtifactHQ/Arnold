module ArnoldPipeline
  module Brownfield
    class ParallelAgentRunner
      AgentResult = Data.define(:agent_name, :output, :error, :duration_ms, :tokens_used)

      def initialize(logger: nil)
        @logger = logger || Logger.new($stdout, level: Logger::WARN)
      end

      def run(agents:, context:, file_cache:)
        threads = agents.map do |agent_name, agent|
          Thread.new do
            Thread.current[:agent_name] = agent_name
            run_agent(agent_name, agent, context, file_cache)
          end
        end

        threads.map(&:value)
      end

      private

      def run_agent(agent_name, agent, context, file_cache)
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        result = agent.call(context:, file_cache:)
        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round(1)

        @logger.info { "[ParallelAgentRunner] #{agent_name} completed in #{duration_ms}ms" }

        AgentResult.new(
          agent_name: agent_name.to_s,
          output: result[:data],
          error: nil,
          duration_ms:,
          tokens_used: result[:tokens_used] || 0
        )
      rescue => e
        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round(1)
        @logger.error { "[ParallelAgentRunner] #{agent_name} failed: #{e.class} — #{e.message}" }

        AgentResult.new(
          agent_name: agent_name.to_s,
          output: nil,
          error: "#{e.class}: #{e.message}",
          duration_ms:,
          tokens_used: 0
        )
      end
    end
  end
end
