require "test_helper"
require "arnold_pipeline/orchestrator"

module ArnoldPipeline
  class OrchestratorTierGateTest < ActiveSupport::TestCase
    setup do
      @library_manager = Library::Manager.new
      @spec_generator = stub("spec_generator")
      @task_breaker = stub("task_breaker")
      @executor = stub("executor")
      @executor.stubs(:provider).returns(stub(recoverable_errors: [], async?: true))
      @analyzer = stub("analyzer")
      @tier_gate_check = stub("tier_gate_check")

      @spec_iterator = stub("spec_iterator")

      @orchestrator = Orchestrator.new(
        library_manager: @library_manager,
        spec_generator: @spec_generator,
        task_breaker: @task_breaker,
        executor: @executor,
        analyzer: @analyzer,
        tier_gate_check: @tier_gate_check,
        spec_iterator: @spec_iterator,
        logger: Logger.new(File::NULL)
      )

      ArnoldPipeline.configure do |c|
        c.max_iterations = 3
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.tier_gate_enabled = true
        c.context_propagation_enabled = true
        c.max_tier_retries = 2
      end
    end

    teardown do
      ArnoldPipeline.reset_configuration!
    end

    test "gate passes — pipeline continues through all tiers" do
      stub_spec_generation!
      stub_task_breakdown!
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      @tier_gate_check.stubs(:call).returns(gate_result(pass: true))
      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      result = @orchestrator.call(nl_input: "Build a todo app")

      assert_equal "completed", result.status
    end

    test "gate fails then passes on retry — corrective tasks created and executed" do
      stub_spec_generation!
      stub_task_breakdown!
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      gate_seq = sequence("gate_calls")

      # Tier 0: fail first, pass on retry
      @tier_gate_check.expects(:call).in_sequence(gate_seq)
        .returns(gate_result(pass: false, corrective_tasks: [ { "title" => "Fix config", "description" => "Add config", "labels" => [ "bugfix" ] } ]))
      @tier_gate_check.expects(:call).in_sequence(gate_seq)
        .returns(gate_result(pass: true, context_summary: "Fixed config and setup complete."))

      # Tiers 1-3: pass
      @tier_gate_check.stubs(:call).with { |kwargs| kwargs[:tier_number] > 0 }
        .returns(gate_result(pass: true))

      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      result = @orchestrator.call(nl_input: "Build a todo app")

      assert_equal "completed", result.status
      # Check corrective task was created
      corrective = result.tasks.find_by(title: "Fix config")
      assert_not_nil corrective, "Corrective task should have been created"
      assert_equal 0, corrective.tier
    end

    test "gate fails max retries — pipeline pauses with metadata" do
      stub_spec_generation!
      stub_task_breakdown!
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      ArnoldPipeline.configuration.max_tier_retries = 1

      gate_seq = sequence("gate_calls")

      # First gate call: fail
      @tier_gate_check.expects(:call).in_sequence(gate_seq)
        .returns(gate_result(pass: false, corrective_tasks: [ { "title" => "Fix build", "description" => "Fix it", "labels" => [] } ]))
      # Re-gate after corrective: still fail
      @tier_gate_check.expects(:call).in_sequence(gate_seq)
        .returns(gate_result(pass: false, corrective_tasks: [ { "title" => "Fix again", "description" => "Fix more", "labels" => [] } ]))

      @analyzer.expects(:call).never

      result = @orchestrator.call(nl_input: "Build a todo app")

      assert_equal "paused", result.status
      assert_equal "tier_gate_failed", result.metadata["paused_at"]
      assert_equal 0, result.metadata["tier_gate_failure"]["tier"]
    end

    test "context propagation — executor.call receives prior_context for tier 1+" do
      stub_spec_generation!
      stub_task_breakdown!

      contexts_received = []
      @executor.stubs(:call).with { |kwargs|
        contexts_received << kwargs[:prior_context]
        true
      }.returns([])

      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      @tier_gate_check.stubs(:call).returns(gate_result(pass: true, context_summary: "Tier complete."))
      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      @orchestrator.call(nl_input: "Build a todo app")

      # Tier 0 should have nil prior_context (no prior tiers)
      assert_nil contexts_received[0]
      # Tier 1+ should have prior context
      assert_includes contexts_received[1].to_s, "Prior Implementation Context"
      assert_includes contexts_received[1].to_s, "Tier 0 completed"
    end

    test "gate disabled — tier_gate_check.call never called" do
      ArnoldPipeline.configuration.tier_gate_enabled = false
      ArnoldPipeline.configuration.context_propagation_enabled = false

      stub_spec_generation!
      stub_task_breakdown!
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      @tier_gate_check.expects(:call).never
      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      result = @orchestrator.call(nl_input: "Build a todo app")

      assert_equal "completed", result.status
    end

    test "context disabled — executor.call receives nil prior_context" do
      ArnoldPipeline.configuration.context_propagation_enabled = false

      stub_spec_generation!
      stub_task_breakdown!

      contexts_received = []
      @executor.stubs(:call).with { |kwargs|
        contexts_received << kwargs[:prior_context]
        true
      }.returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      @tier_gate_check.stubs(:call).returns(gate_result(pass: true))
      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      @orchestrator.call(nl_input: "Build a todo app")

      # All tiers should have nil prior_context since context propagation is off
      assert(contexts_received.all?(&:nil?), "All prior_context values should be nil when context propagation is disabled")
    end

    test "both disabled — no gate or context calls" do
      ArnoldPipeline.configuration.tier_gate_enabled = false
      ArnoldPipeline.configuration.context_propagation_enabled = false

      stub_spec_generation!
      stub_task_breakdown!

      contexts_received = []
      @executor.stubs(:call).with { |kwargs|
        contexts_received << kwargs[:prior_context]
        true
      }.returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      @tier_gate_check.expects(:call).never
      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      result = @orchestrator.call(nl_input: "Build a todo app")

      assert_equal "completed", result.status
      assert(contexts_received.all?(&:nil?))
    end

    test "gate check error is non-fatal — pipeline continues" do
      stub_spec_generation!
      stub_task_breakdown!
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      @tier_gate_check.stubs(:call).raises(StandardError, "LLM timeout")
      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      result = @orchestrator.call(nl_input: "Build a todo app")

      assert_equal "completed", result.status
    end

    private

    def stub_spec_generation!
      @spec_generator.stubs(:call).returns({
        content: "# Todo App Spec\n\nA todo app with CRUD operations",
        structured_data: { "features" => [ "create", "read", "update", "delete" ] }
      })
    end

    def stub_task_breakdown!
      @task_breaker.stubs(:call).returns(sample_tasks)
    end

    def sample_tasks
      [
        { "title" => "Setup database", "description" => "Create schema", "priority" => 0, "labels" => [ "database" ], "position" => 0, "depends_on" => [] },
        { "title" => "Create models", "description" => "Define models", "priority" => 0, "labels" => [ "backend" ], "position" => 1, "depends_on" => [ 0 ] },
        { "title" => "Build API", "description" => "REST endpoints", "priority" => 1, "labels" => [ "backend" ], "position" => 2, "depends_on" => [ 1 ] },
        { "title" => "Add auth", "description" => "Auth system", "priority" => 1, "labels" => [ "backend" ], "position" => 3, "depends_on" => [ 1 ] },
        { "title" => "Write tests", "description" => "Test suite", "priority" => 2, "labels" => [ "testing" ], "position" => 4, "depends_on" => [ 2, 3 ] }
      ]
    end

    def gate_result(pass:, context_summary: "Tier implementation complete.", issues: [], corrective_tasks: [])
      {
        "pass" => pass,
        "issues" => pass ? issues : (issues.any? ? issues : [ "Critical issue found" ]),
        "context_summary" => context_summary,
        "corrective_tasks" => corrective_tasks
      }
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
