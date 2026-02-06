require "test_helper"
require "arnold_pipeline/orchestrator"

module ArnoldPipeline
  class OrchestratorTest < ActiveSupport::TestCase
    setup do
      @library_manager = Library::Manager.new
      @spec_generator = stub("spec_generator")
      @task_breaker = stub("task_breaker")
      @executor = stub("executor")
      @analyzer = stub("analyzer")

      @orchestrator = Orchestrator.new(
        library_manager: @library_manager,
        spec_generator: @spec_generator,
        task_breaker: @task_breaker,
        executor: @executor,
        analyzer: @analyzer,
        logger: Logger.new(File::NULL)
      )

      ArnoldPipeline.configure do |c|
        c.max_iterations = 3
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
      end
    end

    teardown do
      ArnoldPipeline.reset_configuration!
    end

    test "completes pipeline on first iteration with done decision" do
      stub_spec_generation!
      stub_task_breakdown!(times: 1)
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      result = @orchestrator.call(nl_input: "Build a todo app")

      assert_equal "completed", result.status
      assert_equal 1, result.iterations.count
      assert_equal "done", result.iterations.first.decision
    end

    test "iterates tasks when iterate_tasks decision" do
      stub_spec_generation!
      stub_task_breakdown!(times: 1)
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      corrective = {
        "tasks" => [
          { "title" => "Fix error handling", "description" => "Add try/catch", "position" => 0 }
        ]
      }

      call_count = sequence("analysis_calls")
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("iterate_tasks", 80, corrective))
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("done", 92))

      result = @orchestrator.call(nl_input: "Build a todo app")

      assert_equal "completed", result.status
      assert_equal 2, result.iterations.count
    end

    test "iterates spec when iterate_spec decision" do
      stub_spec_generation!
      @task_breaker.stubs(:call).returns(sample_tasks)
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      call_count = sequence("analysis_calls")
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("iterate_spec", 60, { "spec_changes" => "Clarify auth flow" }))
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("done", 90))

      result = @orchestrator.call(nl_input: "Build a todo app")

      assert_equal "completed", result.status
      assert_equal 2, result.iterations.count
      assert result.iterations.order(:number).first.needs_human_review, "Low confidence should flag for review"
    end

    test "stops after max iterations" do
      stub_spec_generation!
      @task_breaker.stubs(:call).returns(sample_tasks)
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      corrective = {
        "tasks" => [{ "title" => "Fix", "description" => "Fix it", "position" => 0 }]
      }

      @analyzer.stubs(:call).returns(analysis_result("iterate_tasks", 75, corrective))

      result = @orchestrator.call(nl_input: "Build a todo app")

      assert_equal "max_iterations_reached", result.status
      assert_equal 3, result.iterations.count
    end

    test "marks as failed on error" do
      @spec_generator.expects(:call).raises(StandardError, "LLM is down")

      assert_raises(StandardError) do
        @orchestrator.call(nl_input: "Build a todo app")
      end

      run_record = PipelineRun.last
      assert_equal "failed", run_record.status
      assert_equal "LLM is down", run_record.metadata["error"]
    end

    test "flags low confidence iterations for human review" do
      stub_spec_generation!
      stub_task_breakdown!(times: 1)
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      @analyzer.expects(:call).once.returns(analysis_result("done", 50))

      result = @orchestrator.call(nl_input: "Build a todo app")

      assert result.iterations.first.needs_human_review
    end

    private

    def stub_spec_generation!
      @spec_generator.stubs(:call).returns({
        content: "# Todo App Spec\n\nA todo app with CRUD operations",
        structured_data: { "features" => ["create", "read", "update", "delete"] }
      })
    end

    def stub_task_breakdown!(times: 1)
      @task_breaker.stubs(:call).returns(sample_tasks)
    end

    def sample_tasks
      [
        { "title" => "Setup database", "description" => "Create schema", "priority" => 0, "labels" => ["database"], "position" => 0, "depends_on" => [] },
        { "title" => "Create models", "description" => "Define models", "priority" => 0, "labels" => ["backend"], "position" => 1, "depends_on" => [0] },
        { "title" => "Build API", "description" => "REST endpoints", "priority" => 1, "labels" => ["backend"], "position" => 2, "depends_on" => [1] },
        { "title" => "Add auth", "description" => "Auth system", "priority" => 1, "labels" => ["backend"], "position" => 3, "depends_on" => [1] },
        { "title" => "Write tests", "description" => "Test suite", "priority" => 2, "labels" => ["testing"], "position" => 4, "depends_on" => [2, 3] }
      ]
    end

    def analysis_result(decision, confidence, corrective_data = {})
      {
        "decision" => decision,
        "confidence" => confidence,
        "reasoning" => "Analysis reasoning for #{decision}",
        "corrective_data" => corrective_data
      }
    end
  end
end
