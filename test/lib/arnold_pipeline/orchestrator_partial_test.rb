require "test_helper"
require "arnold_pipeline/orchestrator"

module ArnoldPipeline
  class OrchestratorPartialTest < ActiveSupport::TestCase
    setup do
      @library_manager = Library::Manager.new
      @spec_generator = stub("spec_generator")
      @task_breaker = stub("task_breaker")
      @executor = stub("executor")
      @analyzer = stub("analyzer")

      @tier_gate_check = stub("tier_gate_check")
      @tier_gate_check.stubs(:call).returns({
        "pass" => true,
        "issues" => [],
        "context_summary" => "Tier complete.",
        "corrective_tasks" => []
      })

      @orchestrator = Orchestrator.new(
        library_manager: @library_manager,
        spec_generator: @spec_generator,
        task_breaker: @task_breaker,
        executor: @executor,
        analyzer: @analyzer,
        tier_gate_check: @tier_gate_check,
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

    # --- Partial Execution Tests ---

    test "stop_after :spec generates spec only" do
      stub_spec_generation!
      @task_breaker.expects(:call).never
      @executor.expects(:call).never

      result = @orchestrator.call(nl_input: "Build a todo app", stop_after: :spec)

      assert_equal "paused", result.status
      assert_equal "spec", result.metadata["paused_at"]
      assert result.specification.present?
      assert result.tasks.empty?
    end

    test "stop_after :tasks generates spec and tasks with tiers" do
      stub_spec_generation!
      stub_task_breakdown!
      @executor.expects(:call).never

      result = @orchestrator.call(nl_input: "Build a todo app", stop_after: :tasks)

      assert_equal "paused", result.status
      assert_equal "tasks", result.metadata["paused_at"]
      assert result.specification.present?
      assert_equal 5, result.tasks.count
      assert result.tasks.none? { |t| t.external_id.present? }
      # Verify tiers were computed
      assert result.tasks.all? { |t| t.tier.present? }
    end

    test "stop_after :executed runs tiered execution but does not analyze" do
      stub_spec_generation!
      stub_task_breakdown!
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])
      @analyzer.expects(:call).never

      result = @orchestrator.call(nl_input: "Build a todo app", stop_after: :executed)

      assert_equal "paused", result.status
      assert_equal "executed", result.metadata["paused_at"]
    end

    test "nil stop_after runs full pipeline" do
      stub_spec_generation!
      stub_task_breakdown!
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])
      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      result = @orchestrator.call(nl_input: "Build a todo app")

      assert_equal "completed", result.status
    end

    # --- Resume Tests ---

    test "resume from paused :spec continues full pipeline" do
      stub_spec_generation!
      stub_task_breakdown!
      @executor.expects(:call).never

      run = @orchestrator.call(nl_input: "Build a todo app", stop_after: :tasks)
      assert_equal "paused", run.status

      # Now resume — needs to pick up from execute
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])
      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      result = @orchestrator.resume(pipeline_run: run)
      assert_equal "completed", result.status
    end

    test "resume from paused :executed continues from analyze" do
      stub_spec_generation!
      stub_task_breakdown!
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      run = @orchestrator.call(nl_input: "Build a todo app", stop_after: :executed)
      assert_equal "paused", run.status

      # Add result_diffs so infer_resume_stage sees resolved tasks
      run.tasks.each { |t| t.update!(external_id: t.position.to_s, result_diff: '[{"filename":"a.rb"}]') }

      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      result = @orchestrator.resume(pipeline_run: run)
      assert_equal "completed", result.status
    end

    test "resume raises for completed pipeline" do
      stub_spec_generation!
      stub_task_breakdown!
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])
      @analyzer.stubs(:call).returns(analysis_result("done", 95))

      run = @orchestrator.call(nl_input: "Build a todo app")
      assert_equal "completed", run.status

      assert_raises(ArgumentError, /Cannot resume/) do
        @orchestrator.resume(pipeline_run: run)
      end
    end

    test "resume from failed pipeline retries from failed stage" do
      @spec_generator.stubs(:call).raises(StandardError, "LLM down")

      assert_raises(StandardError) do
        @orchestrator.call(nl_input: "Build a todo app")
      end

      run = PipelineRun.last
      assert_equal "failed", run.status

      # Fix the spec generator and resume
      stub_spec_generation!
      stub_task_breakdown!
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])
      @analyzer.stubs(:call).returns(analysis_result("done", 95))

      result = @orchestrator.resume(pipeline_run: run)
      assert_equal "completed", result.status
    end

    test "resume with stop_after pauses at new checkpoint" do
      stub_spec_generation!
      @task_breaker.expects(:call).never

      run = @orchestrator.call(nl_input: "Build a todo app", stop_after: :spec)
      assert_equal "paused", run.status

      # Resume but stop after tasks
      stub_task_breakdown!
      @executor.expects(:call).never

      result = @orchestrator.resume(pipeline_run: run, stop_after: :tasks)
      assert_equal "paused", result.status
      assert_equal "tasks", result.metadata["paused_at"]
      assert_equal 5, result.tasks.count
    end

    # --- Infer Resume Stage Tests ---

    test "infer_resume_stage returns generate_spec when no spec exists" do
      run = PipelineRun.create!(nl_input: "test", status: :paused)

      stage = ResumeInferrer.call(run)
      assert_equal :generate_spec, stage
    end

    test "infer_resume_stage returns break_tasks when spec exists but no tasks" do
      run = PipelineRun.create!(nl_input: "test", status: :paused)
      run.create_specification!(content: "spec", structured_data: {}, version: 1)

      stage = ResumeInferrer.call(run)
      assert_equal :break_tasks, stage
    end

    test "infer_resume_stage returns execute when tasks have no tiers" do
      run = PipelineRun.create!(nl_input: "test", status: :paused)
      run.create_specification!(content: "spec", structured_data: {}, version: 1)
      run.tasks.create!(title: "Task 1", position: 0)

      stage = ResumeInferrer.call(run)
      assert_equal :execute, stage
    end

    test "infer_resume_stage returns execute when tasks exist without external_ids" do
      run = PipelineRun.create!(nl_input: "test", status: :paused)
      run.create_specification!(content: "spec", structured_data: {}, version: 1)
      run.tasks.create!(title: "Task 1", position: 0, tier: 0)

      stage = ResumeInferrer.call(run)
      assert_equal :execute, stage
    end

    test "infer_resume_stage returns execute when tasks have external_ids but no results" do
      run = PipelineRun.create!(nl_input: "test", status: :paused)
      run.create_specification!(content: "spec", structured_data: {}, version: 1)
      run.tasks.create!(title: "Task 1", position: 0, tier: 0, external_id: "1")

      stage = ResumeInferrer.call(run)
      assert_equal :execute, stage
    end

    test "infer_resume_stage returns analyze when all tasks have results" do
      run = PipelineRun.create!(nl_input: "test", status: :paused)
      run.create_specification!(content: "spec", structured_data: {}, version: 1)
      run.tasks.create!(title: "Task 1", position: 0, tier: 0, external_id: "1", result_diff: '[{"filename":"a.rb"}]')

      stage = ResumeInferrer.call(run)
      assert_equal :analyze, stage
    end

    # --- Tiered Execution Tests ---

    test "tiered execution calls executor per-tier with correct task subsets" do
      stub_spec_generation!
      stub_task_breakdown!

      tiers_published = []
      tiers_awaited = []
      tiers_merged = []

      @executor.stubs(:call).with { |kwargs|
        tiers_published << kwargs[:tasks].map(&:tier).uniq
        true
      }.returns([])

      @executor.stubs(:await_results).with { |kwargs|
        tiers_awaited << kwargs[:tasks].map(&:tier).uniq if kwargs[:tasks]
        true
      }.returns(nil)

      @executor.stubs(:merge_results).with { |kwargs|
        tiers_merged << kwargs[:tasks].map(&:tier).uniq if kwargs[:tasks]
        true
      }.returns([])

      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      result = @orchestrator.call(nl_input: "Build a todo app")

      assert_equal "completed", result.status
      # sample_tasks has 4 tiers (0,1,2,3)
      assert_equal [[0], [1], [2], [3]], tiers_published
      assert_equal [[0], [1], [2], [3]], tiers_awaited
      assert_equal [[0], [1], [2], [3]], tiers_merged
    end

    test "resume skips completed tiers" do
      stub_spec_generation!
      stub_task_breakdown!

      # Stop after tasks so we can manipulate tier state
      @executor.expects(:call).never
      run = @orchestrator.call(nl_input: "Build a todo app", stop_after: :tasks)

      # Mark tier 0 task as fully resolved
      tier0_task = run.tasks.find_by(position: 0)
      tier0_task.update!(external_id: "1", result_diff: '[{"filename":"setup.rb"}]')

      tiers_published = []
      @executor.stubs(:call).with { |kwargs|
        tiers_published << kwargs[:tasks].map(&:tier).uniq
        true
      }.returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])
      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      result = @orchestrator.resume(pipeline_run: run)

      assert_equal "completed", result.status
      # Tier 0 should be skipped since it's resolved
      assert_not_includes tiers_published, [0]
      assert_includes tiers_published, [1]
    end

    # --- Analysis Loop Continues From Prior Iterations ---

    test "analysis_loop continues iteration numbering from existing iterations" do
      stub_spec_generation!
      stub_task_breakdown!
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      # First run: stop after executed
      run = @orchestrator.call(nl_input: "Build a todo app", stop_after: :executed)

      # Manually add an iteration to simulate prior analysis
      run.iterations.create!(
        number: 1,
        decision: "iterate_tasks",
        confidence: 80,
        reasoning: "Needs fixes",
        corrective_data: {}
      )

      # Add results so infer_resume_stage goes to :analyze
      run.tasks.each { |t| t.update!(external_id: t.position.to_s, result_diff: '[{"filename":"a.rb"}]') }

      # Resume — analyzer should receive iteration_number 2
      @analyzer.expects(:call).with { |kwargs|
        kwargs[:iteration_number] == 2
      }.returns(analysis_result("done", 95))

      result = @orchestrator.resume(pipeline_run: run)
      assert_equal "completed", result.status
      assert_equal 2, result.iterations.count
    end

    private

    def stub_spec_generation!
      @spec_generator.stubs(:call).returns({
        content: "# Todo App Spec\n\nA todo app with CRUD operations",
        structured_data: { "features" => ["create", "read", "update", "delete"] }
      })
    end

    def stub_task_breakdown!
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
