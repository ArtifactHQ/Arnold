require "test_helper"
require "arnold_pipeline/brownfield/parallel_agent_runner"
require "arnold_pipeline/brownfield/analysis_context"
require "arnold_pipeline/brownfield/file_content_cache"
require "tmpdir"

module ArnoldPipeline
  module Brownfield
    class ParallelAgentRunnerTest < ActiveSupport::TestCase
      setup do
        @dir = Dir.mktmpdir("runner_test_")
        @logger = Logger.new(IO::NULL)
        @runner = ParallelAgentRunner.new(logger: @logger)
        @context = AnalysisContext.new(
          repo_path: @dir,
          stack_fingerprint: { language: "ruby", framework: "rails" },
          artifacts: [], overlay: {}, file_manifest: {},
          route_table: [], git_activity: {}, test_names: {},
          concerns: {}, reference_materials: [], change_request: nil
        )
        @file_cache = FileContentCache.new(repo_path: @dir)
      end

      teardown do
        FileUtils.rm_rf(@dir)
      end

      test "runs agents in parallel and returns results" do
        agent_a = mock_agent("agent_a", { entities: [] }, 100)
        agent_b = mock_agent("agent_b", { services: [] }, 200)

        results = @runner.run(
          agents: { infrastructure: agent_a, data_model: agent_b },
          context: @context,
          file_cache: @file_cache
        )

        assert_equal 2, results.size
        names = results.map(&:agent_name)
        assert_includes names, "infrastructure"
        assert_includes names, "data_model"

        infra = results.find { |r| r.agent_name == "infrastructure" }
        assert_equal({ entities: [] }, infra.output)
        assert_nil infra.error
        assert_equal 100, infra.tokens_used
      end

      test "captures errors from failed agents without crashing others" do
        good_agent = mock_agent("good", { data: "ok" }, 50)
        bad_agent = stub("bad_agent")
        bad_agent.stubs(:call).raises(RuntimeError, "LLM timeout")

        results = @runner.run(
          agents: { good: good_agent, bad: bad_agent },
          context: @context,
          file_cache: @file_cache
        )

        assert_equal 2, results.size
        good = results.find { |r| r.agent_name == "good" }
        bad = results.find { |r| r.agent_name == "bad" }

        assert_equal({ data: "ok" }, good.output)
        assert_nil good.error

        assert_nil bad.output
        assert_match(/RuntimeError.*LLM timeout/, bad.error)
        assert_equal 0, bad.tokens_used
      end

      test "handles all agents failing gracefully" do
        bad1 = stub("bad1")
        bad1.stubs(:call).raises(StandardError, "fail1")
        bad2 = stub("bad2")
        bad2.stubs(:call).raises(StandardError, "fail2")

        results = @runner.run(
          agents: { a: bad1, b: bad2 },
          context: @context,
          file_cache: @file_cache
        )

        assert_equal 2, results.size
        assert results.all? { |r| r.error.present? }
        assert results.all? { |r| r.output.nil? }
      end

      test "handles empty agents list" do
        results = @runner.run(agents: {}, context: @context, file_cache: @file_cache)
        assert_equal [], results
      end

      test "records duration_ms for each agent" do
        agent = mock_agent("slow", { data: 1 }, 10)

        results = @runner.run(
          agents: { slow: agent },
          context: @context,
          file_cache: @file_cache
        )

        assert results.first.duration_ms >= 0
      end

      test "AgentResult is immutable" do
        result = ParallelAgentRunner::AgentResult.new(
          agent_name: "test", output: {}, error: nil, duration_ms: 100, tokens_used: 50
        )
        assert result.frozen?
        assert_equal "test", result.agent_name
      end

      private

      def mock_agent(name, data, tokens)
        agent = stub(name)
        agent.stubs(:call).returns({ data:, tokens_used: tokens })
        agent
      end
    end
  end
end
