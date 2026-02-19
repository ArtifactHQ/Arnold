require "test_helper"
require "arnold_pipeline/orchestrator"

module ArnoldPipeline
  class AnalysisLoopTest < ActiveSupport::TestCase
    cover "ArnoldPipeline::AnalysisLoop*"

    setup do
      @library_manager = Library::Manager.new
      @analyzer = stub("analyzer")
      @task_breaker = stub("task_breaker")
      @executor = stub("executor")
      @executor.stubs(:provider).returns(stub(recoverable_errors: [], async?: true))
      @tier_gate_check = stub("tier_gate_check")

      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      @tier_execution_engine = TierExecutionEngine.new(
        executor: @executor,
        tier_gate_check: @tier_gate_check,
        logger: Logger.new(File::NULL)
      )

      @analysis_loop = AnalysisLoop.new(
        analyzer: @analyzer,
        task_breaker: @task_breaker,
        library_manager: @library_manager,
        tier_execution_engine: @tier_execution_engine,
        logger: Logger.new(File::NULL)
      )

      ArnoldPipeline.configure do |c|
        c.max_iterations = 3
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.tier_gate_enabled = false
        c.context_propagation_enabled = false
        c.workflow_status_enabled = false
      end
    end

    teardown do
      ArnoldPipeline.reset_configuration!
    end

    test "completes on done decision" do
      pipeline_run = create_pipeline_run_with_spec_and_tasks!

      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      @analysis_loop.run!(pipeline_run)

      assert_equal "completed", pipeline_run.reload.status
      assert_equal 1, pipeline_run.iterations.count
      assert_equal "done", pipeline_run.iterations.first.decision
    end

    test "handles iterate_tasks decision" do
      pipeline_run = create_pipeline_run_with_spec_and_tasks!

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

      @analysis_loop.run!(pipeline_run)

      assert_equal "completed", pipeline_run.reload.status
      assert_equal 2, pipeline_run.iterations.count
    end

    test "handles iterate_spec decision" do
      pipeline_run = create_pipeline_run_with_spec_and_tasks!

      @task_breaker.stubs(:call).returns(sample_tasks)

      call_count = sequence("analysis_calls")
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("iterate_spec", 60, { "spec_changes" => "Clarify auth flow" }))
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("done", 90))

      @analysis_loop.run!(pipeline_run)

      assert_equal "completed", pipeline_run.reload.status
      assert_equal 2, pipeline_run.iterations.count
      assert_includes pipeline_run.specification.content, "Clarify auth flow"
    end

    test "stops after max iterations" do
      pipeline_run = create_pipeline_run_with_spec_and_tasks!

      corrective = {
        "tasks" => [{ "title" => "Fix", "description" => "Fix it", "position" => 0 }]
      }

      @analyzer.stubs(:call).returns(analysis_result("iterate_tasks", 75, corrective))

      @analysis_loop.run!(pipeline_run)

      assert_equal "max_iterations_reached", pipeline_run.reload.status
      assert_equal 3, pipeline_run.iterations.count
    end

    test "creates iteration records with correct data" do
      pipeline_run = create_pipeline_run_with_spec_and_tasks!

      @analyzer.expects(:call).once.returns(analysis_result("done", 88))

      @analysis_loop.run!(pipeline_run)

      iteration = pipeline_run.iterations.first
      assert_equal 1, iteration.number
      assert_equal "done", iteration.decision
      assert_equal 88, iteration.confidence
      assert_equal "Analysis reasoning for done", iteration.reasoning
    end

    test "flags low confidence iterations for human review" do
      pipeline_run = create_pipeline_run_with_spec_and_tasks!

      @analyzer.expects(:call).once.returns(analysis_result("done", 50))

      @analysis_loop.run!(pipeline_run)

      assert pipeline_run.iterations.first.needs_human_review
    end

    test "resumes from existing iteration count" do
      pipeline_run = create_pipeline_run_with_spec_and_tasks!
      # Simulate 2 existing iterations
      pipeline_run.iterations.create!(number: 1, decision: "iterate_tasks", confidence: 80, reasoning: "First pass")
      pipeline_run.iterations.create!(number: 2, decision: "iterate_tasks", confidence: 85, reasoning: "Second pass")

      ArnoldPipeline.configuration.max_iterations = 3

      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      @analysis_loop.run!(pipeline_run)

      assert_equal "completed", pipeline_run.reload.status
      assert_equal 3, pipeline_run.iterations.count
      assert_equal 3, pipeline_run.iterations.order(:number).last.number
    end

    test "iterate_spec passes recipe context to task_breaker" do
      pipeline_run = create_pipeline_run_with_spec_and_tasks!(
        structured_data: {
          "features" => ["auth"],
          "recipe_type" => "web_app",
          "supporting_recipe_types" => ["api_service"]
        }
      )

      @task_breaker.expects(:call).with { |kwargs|
        kwargs[:recipe]&.type == "web_app" &&
          kwargs[:supporting_recipes].any? { |r| r.type == "api_service" }
      }.returns(sample_tasks)

      call_count = sequence("analysis_calls")
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("iterate_spec", 60, { "spec_changes" => "Clarify auth flow" }))
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("done", 90))

      @analysis_loop.run!(pipeline_run)

      assert_equal "completed", pipeline_run.reload.status
    end

    test "iterate_spec works without recipe in structured_data" do
      pipeline_run = create_pipeline_run_with_spec_and_tasks!

      @task_breaker.expects(:call).with { |kwargs|
        kwargs[:recipe].nil? && kwargs[:supporting_recipes] == []
      }.returns(sample_tasks)

      call_count = sequence("analysis_calls")
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("iterate_spec", 60, { "spec_changes" => "Clarify auth" }))
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("done", 90))

      @analysis_loop.run!(pipeline_run)

      assert_equal "completed", pipeline_run.reload.status
    end

    # --- Convergence / threshold promotion tests ---

    test "promotes iterate_tasks to done when confidence >= threshold" do
      pipeline_run = create_pipeline_run_with_spec_and_tasks!

      ArnoldPipeline.configuration.analysis_done_threshold = 75

      @analyzer.expects(:call).once.returns(analysis_result("iterate_tasks", 80))

      @analysis_loop.run!(pipeline_run)

      assert_equal "completed", pipeline_run.reload.status
      assert_equal 1, pipeline_run.iterations.count
      # The DB iteration preserves the original LLM decision
      assert_equal "iterate_tasks", pipeline_run.iterations.first.decision
    end

    test "does not promote when confidence < threshold" do
      pipeline_run = create_pipeline_run_with_spec_and_tasks!

      ArnoldPipeline.configuration.analysis_done_threshold = 85

      corrective = {
        "tasks" => [{ "title" => "Fix", "description" => "Fix it", "position" => 0 }]
      }
      @analyzer.stubs(:call).returns(analysis_result("iterate_tasks", 80, corrective))

      @analysis_loop.run!(pipeline_run)

      assert_equal "max_iterations_reached", pipeline_run.reload.status
      assert_equal 3, pipeline_run.iterations.count
    end

    test "does not promote iterate_spec even at high confidence" do
      pipeline_run = create_pipeline_run_with_spec_and_tasks!

      ArnoldPipeline.configuration.analysis_done_threshold = 70

      @task_breaker.stubs(:call).returns(sample_tasks)

      call_count = sequence("analysis_calls")
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("iterate_spec", 90, { "spec_changes" => "Clarify auth" }))
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("done", 95))

      @analysis_loop.run!(pipeline_run)

      assert_equal "completed", pipeline_run.reload.status
      assert_equal 2, pipeline_run.iterations.count
    end

    test "threshold disabled when nil — high confidence still iterates" do
      pipeline_run = create_pipeline_run_with_spec_and_tasks!

      ArnoldPipeline.configuration.analysis_done_threshold = nil

      corrective = {
        "tasks" => [{ "title" => "Fix", "description" => "Fix it", "position" => 0 }]
      }
      @analyzer.stubs(:call).returns(analysis_result("iterate_tasks", 99, corrective))

      @analysis_loop.run!(pipeline_run)

      assert_equal "max_iterations_reached", pipeline_run.reload.status
      assert_equal 3, pipeline_run.iterations.count
    end

    test "passes max_iterations and previous_decisions to analyzer" do
      pipeline_run = create_pipeline_run_with_spec_and_tasks!
      pipeline_run.iterations.create!(number: 1, decision: "iterate_tasks", confidence: 75, reasoning: "Missing auth handler")

      ArnoldPipeline.configuration.max_iterations = 3

      @analyzer.expects(:call).with { |kwargs|
        kwargs[:max_iterations] == 3 &&
          kwargs[:previous_decisions].is_a?(Array) &&
          kwargs[:previous_decisions].size == 1 &&
          kwargs[:previous_decisions].first[:decision] == "iterate_tasks" &&
          kwargs[:previous_decisions].first[:confidence] == 75
      }.returns(analysis_result("done", 95))

      @analysis_loop.run!(pipeline_run)

      assert_equal "completed", pipeline_run.reload.status
    end

    # --- Delta-based iterate_spec tests ---

    test "handles iterate_spec with deltas format (legacy_append fallback)" do
      pipeline_run = create_pipeline_run_with_spec_and_tasks!

      ArnoldPipeline.configure { |c| c.openspec_enabled = false }

      deltas = [
        { "operation" => "added", "section" => "Auth", "content" => "### Requirement: Password Reset\nNew.", "rationale" => "Missing" },
        { "operation" => "modified", "section" => "Auth", "requirement" => "Login", "before_content" => "old", "after_content" => "### Requirement: Login\nUpdated.", "rationale" => "Ambiguous" }
      ]

      @task_breaker.stubs(:call).returns(sample_tasks)

      call_count = sequence("analysis_calls")
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("iterate_spec", 60, { "deltas" => deltas }))
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("done", 90))

      @analysis_loop.run!(pipeline_run)

      spec = pipeline_run.specification.reload
      assert_includes spec.content, "Spec Iteration"
      assert_includes spec.content, "Password Reset"
      assert_includes spec.content, "Updated"
    end

    test "persists spec_deltas when deltas format is used" do
      pipeline_run = create_pipeline_run_with_spec_and_tasks!

      ArnoldPipeline.configure { |c| c.openspec_enabled = false }

      deltas = [
        { "operation" => "added", "section" => "Auth", "content" => "### Requirement: New\nShall.", "rationale" => "Missing" }
      ]

      @task_breaker.stubs(:call).returns(sample_tasks)

      call_count = sequence("analysis_calls")
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("iterate_spec", 60, { "deltas" => deltas }))
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("done", 90))

      @analysis_loop.run!(pipeline_run)

      assert_equal 1, pipeline_run.specification.spec_deltas.count
      delta = pipeline_run.specification.spec_deltas.first
      assert_equal "added", delta.operation
      assert_equal "Auth", delta.section
    end

    test "creates spec_revision on delta-based iterate_spec" do
      pipeline_run = create_pipeline_run_with_spec_and_tasks!

      ArnoldPipeline.configure { |c| c.openspec_enabled = false }

      deltas = [
        { "operation" => "added", "section" => "Auth", "content" => "### Requirement: New\nShall.", "rationale" => "Missing" }
      ]

      @task_breaker.stubs(:call).returns(sample_tasks)

      call_count = sequence("analysis_calls")
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("iterate_spec", 60, { "deltas" => deltas }))
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("done", 90))

      @analysis_loop.run!(pipeline_run)

      revisions = pipeline_run.specification.spec_revisions
      assert_equal 1, revisions.count
      revision = revisions.first
      assert_equal "iterate_spec", revision.change_source
      assert_includes revision.delta_summary, "ADDED: Auth > new requirement"
    end

    test "legacy_append! still works with old spec_changes format" do
      pipeline_run = create_pipeline_run_with_spec_and_tasks!

      @task_breaker.stubs(:call).returns(sample_tasks)

      call_count = sequence("analysis_calls")
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("iterate_spec", 60, { "spec_changes" => "Add error handling for edge cases" }))
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("done", 90))

      @analysis_loop.run!(pipeline_run)

      spec = pipeline_run.specification.reload
      assert_includes spec.content, "Clarifications (Iteration)"
      assert_includes spec.content, "Add error handling for edge cases"

      # Legacy path should not create deltas or revisions
      assert_equal 0, spec.spec_deltas.count
      assert_equal 0, spec.spec_revisions.count
    end

    test "append_deltas! handles removed operations" do
      pipeline_run = create_pipeline_run_with_spec_and_tasks!

      ArnoldPipeline.configure { |c| c.openspec_enabled = false }

      deltas = [
        { "operation" => "removed", "section" => "Auth", "requirement" => "SMS Verify", "rationale" => "Out of scope" }
      ]

      @task_breaker.stubs(:call).returns(sample_tasks)

      call_count = sequence("analysis_calls")
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("iterate_spec", 60, { "deltas" => deltas }))
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("done", 90))

      @analysis_loop.run!(pipeline_run)

      spec = pipeline_run.specification.reload
      assert_includes spec.content, "REMOVED: SMS Verify"
    end

    # --- Version skew guard tests ---

    test "suppresses iterate_spec when spec version > tasks_generated_at_spec_version" do
      pipeline_run = create_pipeline_run_with_spec_and_tasks!
      # Simulate: tasks were generated at spec v1, but spec has been iterated to v3
      pipeline_run.update!(metadata: { "tasks_generated_at_spec_version" => 1 })
      pipeline_run.specification.update!(version: 3)

      @analyzer.expects(:call).once.returns(analysis_result("iterate_spec", 60, { "spec_changes" => "Some change" }))

      @analysis_loop.run!(pipeline_run)

      # Should complete (suppressed to done), not iterate spec
      assert_equal "completed", pipeline_run.reload.status
      assert_equal 1, pipeline_run.iterations.count
    end

    test "does not suppress iterate_tasks even with version skew" do
      pipeline_run = create_pipeline_run_with_spec_and_tasks!
      pipeline_run.update!(metadata: { "tasks_generated_at_spec_version" => 1 })
      pipeline_run.specification.update!(version: 3)

      corrective = {
        "tasks" => [{ "title" => "Fix", "description" => "Fix it", "position" => 0 }]
      }

      call_count = sequence("analysis_calls")
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("iterate_tasks", 80, corrective))
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("done", 92))

      @analysis_loop.run!(pipeline_run)

      assert_equal "completed", pipeline_run.reload.status
      assert_equal 2, pipeline_run.iterations.count
    end

    test "no suppression when tasks_generated_at_spec_version metadata is missing" do
      pipeline_run = create_pipeline_run_with_spec_and_tasks!
      # No metadata set — should behave normally

      @task_breaker.stubs(:call).returns(sample_tasks)

      call_count = sequence("analysis_calls")
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("iterate_spec", 60, { "spec_changes" => "Clarify something" }))
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("done", 90))

      @analysis_loop.run!(pipeline_run)

      assert_equal "completed", pipeline_run.reload.status
      assert_equal 2, pipeline_run.iterations.count
      assert_includes pipeline_run.specification.content, "Clarify something"
    end

    test "no suppression when spec version matches tasks_generated_at_spec_version" do
      pipeline_run = create_pipeline_run_with_spec_and_tasks!
      pipeline_run.update!(metadata: { "tasks_generated_at_spec_version" => 1 })
      # spec version is 1 (matches) — no skew

      @task_breaker.stubs(:call).returns(sample_tasks)

      call_count = sequence("analysis_calls")
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("iterate_spec", 60, { "spec_changes" => "Normal iteration" }))
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("done", 90))

      @analysis_loop.run!(pipeline_run)

      assert_equal "completed", pipeline_run.reload.status
      assert_equal 2, pipeline_run.iterations.count
      assert_includes pipeline_run.specification.content, "Normal iteration"
    end

    test "break_tasks! records tasks_generated_at_spec_version in metadata" do
      pipeline_run = create_pipeline_run_with_spec_and_tasks!
      pipeline_run.update!(status: :analyzing)

      @task_breaker.stubs(:call).returns(sample_tasks)

      @analysis_loop.send(:break_tasks!, pipeline_run)

      metadata = pipeline_run.reload.metadata
      assert_equal 1, metadata["tasks_generated_at_spec_version"]
    end

    # --- Corrective task dependency sanitization tests ---

    test "handle_iterate_tasks strips self-referential dependencies" do
      pipeline_run = create_pipeline_run_with_spec_and_tasks!

      corrective = {
        "tasks" => [
          { "title" => "Setup DB", "description" => "Create schema", "position" => 0, "depends_on" => [] },
          { "title" => "Add auth", "description" => "Auth system", "position" => 1, "depends_on" => [0, 1] },
          { "title" => "Add API", "description" => "API endpoints", "position" => 2, "depends_on" => [0, 2] }
        ]
      }

      call_count = sequence("analysis_calls")
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("iterate_tasks", 80, corrective))
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("done", 92))

      @analysis_loop.run!(pipeline_run)

      assert_equal "completed", pipeline_run.reload.status
      tasks = pipeline_run.tasks.reload.order(:position)
      # Self-refs stripped: task 1 keeps dep on 0 but not on 1; task 2 keeps dep on 0 but not on 2
      assert_equal [0], tasks[1].depends_on
      assert_equal [0], tasks[2].depends_on
    end

    test "handle_iterate_tasks strips mutual cycle dependencies" do
      pipeline_run = create_pipeline_run_with_spec_and_tasks!

      corrective = {
        "tasks" => [
          { "title" => "Task A", "description" => "First", "position" => 0, "depends_on" => [1] },
          { "title" => "Task B", "description" => "Second", "position" => 1, "depends_on" => [0] }
        ]
      }

      call_count = sequence("analysis_calls")
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("iterate_tasks", 80, corrective))
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("done", 92))

      @analysis_loop.run!(pipeline_run)

      assert_equal "completed", pipeline_run.reload.status
      tasks = pipeline_run.tasks.reload.order(:position)
      # Cycle stripped: all deps cleared
      assert_equal [], tasks[0].depends_on
      assert_equal [], tasks[1].depends_on
    end

    test "handle_iterate_tasks preserves valid dependencies" do
      pipeline_run = create_pipeline_run_with_spec_and_tasks!

      corrective = {
        "tasks" => [
          { "title" => "Setup DB", "description" => "Create schema", "position" => 0, "depends_on" => [] },
          { "title" => "Add models", "description" => "Define models", "position" => 1, "depends_on" => [0] },
          { "title" => "Add API", "description" => "API endpoints", "position" => 2, "depends_on" => [0, 1] }
        ]
      }

      call_count = sequence("analysis_calls")
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("iterate_tasks", 80, corrective))
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("done", 92))

      @analysis_loop.run!(pipeline_run)

      assert_equal "completed", pipeline_run.reload.status
      tasks = pipeline_run.tasks.reload.order(:position)
      # Valid deps preserved
      assert_equal [], tasks[0].depends_on
      assert_equal [0], tasks[1].depends_on
      assert_equal [0, 1], tasks[2].depends_on
    end

    private

    def create_pipeline_run_with_spec_and_tasks!(structured_data: nil)
      pipeline_run = PipelineRun.create!(nl_input: "Build a todo app", status: :pending)
      pipeline_run.update!(status: :generating_spec)
      pipeline_run.update!(status: :breaking_tasks)
      pipeline_run.update!(status: :executing)
      pipeline_run.update!(status: :awaiting_results)
      spec_attrs = { content: "# Todo App Spec\n\nA todo app with CRUD operations", version: 1 }
      spec_attrs[:structured_data] = structured_data if structured_data
      pipeline_run.create_specification!(**spec_attrs)
      pipeline_run.tasks.create!(title: "Setup database", description: "Create schema", position: 0, tier: 0)
      pipeline_run
    end

    def sample_tasks
      [
        { "title" => "Setup database", "description" => "Create schema", "priority" => 0, "labels" => ["database"], "position" => 0, "depends_on" => [] },
        { "title" => "Create models", "description" => "Define models", "priority" => 0, "labels" => ["backend"], "position" => 1, "depends_on" => [0] }
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
