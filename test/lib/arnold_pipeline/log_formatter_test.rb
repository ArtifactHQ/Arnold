require "test_helper"
require "arnold_pipeline/log_formatter"

module ArnoldPipeline
  class LogFormatterTest < ActiveSupport::TestCase
    setup do
      @run = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
    end

    # --- Color gating ---

    test "render with color: false produces no ANSI codes" do
      @run.pipeline_events.create!(
        event_type: :library_selection, stage: "spec_generation",
        summary: { "persona" => "Software Architect", "recipe" => "Web App", "domain_type" => "PRODUCTIVITY" }
      )
      formatter = LogFormatter.new(@run.pipeline_events.chronological, pipeline_run: @run, color: false)
      output = formatter.render
      assert_no_match(/\e\[/, output)
    end

    test "render with color: true produces ANSI codes" do
      @run.pipeline_events.create!(
        event_type: :library_selection, stage: "spec_generation",
        summary: { "persona" => "Software Architect", "recipe" => "Web App", "domain_type" => "PRODUCTIVITY" }
      )
      formatter = LogFormatter.new(@run.pipeline_events.chronological, pipeline_run: @run, color: true)
      output = formatter.render
      assert_match(/\e\[/, output)
    end

    # --- Header ---

    test "render starts with Pipeline Run header and date" do
      @run.pipeline_events.create!(
        event_type: :library_selection, stage: "spec_generation",
        summary: { "persona" => "Arch", "recipe" => "Web", "domain_type" => "GAME" }
      )
      formatter = LogFormatter.new(@run.pipeline_events.chronological, pipeline_run: @run, color: false)
      output = formatter.render
      assert_match(/Pipeline Run ##{@run.id}/, output)
    end

    # --- Preamble events ---

    test "library_selection renders with persona, recipe, domain" do
      @run.pipeline_events.create!(
        event_type: :library_selection, stage: "spec_generation",
        summary: { "persona" => "General Analyst", "recipe" => "Generic", "domain_type" => "PRODUCTIVITY" }
      )
      formatter = LogFormatter.new(@run.pipeline_events.chronological, pipeline_run: @run, color: false)
      output = formatter.render
      assert_match(/library/, output)
      assert_match(/persona=General Analyst/, output)
      assert_match(/recipe=Generic/, output)
      assert_match(/domain=PRODUCTIVITY/, output)
    end

    test "spec_generated renders with version, size, and duration" do
      @run.pipeline_events.create!(
        event_type: :spec_generated, stage: "spec_generation",
        summary: { "spec_version" => 1, "content_length" => 29296 },
        duration_ms: 57000.0
      )
      formatter = LogFormatter.new(@run.pipeline_events.chronological, pipeline_run: @run, color: false)
      output = formatter.render
      lines = output.lines.map(&:strip).reject(&:empty?)
      spec_line = lines.find { |l| l.include?("spec") && l.include?("v1") }
      assert spec_line, "Expected a line with 'spec' and 'v1', got:\n#{output}"
      assert_match(/29,296 chars/, spec_line)
      assert_match(/57\.0s/, spec_line)
    end

    test "tasks_broken renders with task count, tiers, deps" do
      @run.pipeline_events.create!(
        event_type: :tasks_broken, stage: "task_breakdown",
        summary: { "task_count" => 12, "tier_count" => 9, "dependency_edge_count" => 18 },
        duration_ms: 55100.0
      )
      formatter = LogFormatter.new(@run.pipeline_events.chronological, pipeline_run: @run, color: false)
      output = formatter.render
      lines = output.lines.map(&:strip).reject(&:empty?)
      tasks_line = lines.find { |l| l.include?("tasks") && l.include?("12") }
      assert tasks_line, "Expected a line with 'tasks' and '12'"
      assert_match(/9 tiers/, tasks_line)
      assert_match(/18 deps/, tasks_line)
    end

    # --- Tier block rendering ---

    test "tier_execution_started creates a tier header block" do
      @run.pipeline_events.create!(
        event_type: :tier_execution_started, stage: "execution", tier_number: 0,
        summary: { "tier_number" => 0, "task_count" => 2, "task_titles" => ["Setup DB", "Add routes"] }
      )
      @run.pipeline_events.create!(
        event_type: :tier_execution_completed, stage: "execution", tier_number: 0,
        summary: { "tier_number" => 0, "resolved_count" => 2, "failed_count" => 0 }
      )
      formatter = LogFormatter.new(@run.pipeline_events.chronological, pipeline_run: @run, color: false)
      output = formatter.render

      assert_match(/TIER 0/, output)
      assert_match(/2 tasks/, output)
      assert_match(/Setup DB/, output)
      assert_match(/Add routes/, output)
      assert_match(/2 passed/, output)
    end

    test "tier_execution_completed with failures shows red failure count" do
      @run.pipeline_events.create!(
        event_type: :tier_execution_started, stage: "execution", tier_number: 1,
        summary: { "tier_number" => 1, "task_count" => 3, "task_titles" => ["A", "B", "C"] }
      )
      @run.pipeline_events.create!(
        event_type: :tier_execution_completed, stage: "execution", tier_number: 1,
        summary: { "tier_number" => 1, "resolved_count" => 1, "failed_count" => 2 }
      )
      formatter = LogFormatter.new(@run.pipeline_events.chronological, pipeline_run: @run, color: false)
      output = formatter.render

      assert_match(/2 failed/, output)
      assert_match(/1 ok/, output)
    end

    test "post_merge_hooks shows triggered count" do
      @run.pipeline_events.create!(
        event_type: :tier_execution_started, stage: "execution", tier_number: 0,
        summary: { "tier_number" => 0, "task_count" => 1, "task_titles" => ["X"] }
      )
      @run.pipeline_events.create!(
        event_type: :post_merge_hooks, stage: "execution", tier_number: 0,
        summary: { "hook_count" => 2, "triggered_count" => 2, "success_count" => 2 }
      )
      formatter = LogFormatter.new(@run.pipeline_events.chronological, pipeline_run: @run, color: false)
      output = formatter.render
      assert_match(/2\/2 triggered OK/, output)
    end

    test "post_merge_hooks shows dim when none triggered" do
      @run.pipeline_events.create!(
        event_type: :tier_execution_started, stage: "execution", tier_number: 0,
        summary: { "tier_number" => 0, "task_count" => 1, "task_titles" => ["X"] }
      )
      @run.pipeline_events.create!(
        event_type: :post_merge_hooks, stage: "execution", tier_number: 0,
        summary: { "hook_count" => 2, "triggered_count" => 0, "success_count" => 0 }
      )
      formatter = LogFormatter.new(@run.pipeline_events.chronological, pipeline_run: @run, color: false)
      output = formatter.render
      assert_match(/no hooks triggered/, output)
    end

    test "verification_checks PASS renders pass badge" do
      @run.pipeline_events.create!(
        event_type: :tier_execution_started, stage: "execution", tier_number: 0,
        summary: { "tier_number" => 0, "task_count" => 1, "task_titles" => ["X"] }
      )
      @run.pipeline_events.create!(
        event_type: :verification_checks, stage: "execution", tier_number: 0,
        summary: { "all_passed" => true, "summary" => "4 passed, 0 failed" }
      )
      formatter = LogFormatter.new(@run.pipeline_events.chronological, pipeline_run: @run, color: false)
      output = formatter.render
      assert_match(/PASS/, output)
      assert_match(/4 passed, 0 failed/, output)
    end

    test "verification_checks FAIL renders fail badge" do
      @run.pipeline_events.create!(
        event_type: :tier_execution_started, stage: "execution", tier_number: 0,
        summary: { "tier_number" => 0, "task_count" => 1, "task_titles" => ["X"] }
      )
      @run.pipeline_events.create!(
        event_type: :verification_checks, stage: "execution", tier_number: 0,
        summary: { "all_passed" => false, "summary" => "Test suite=FAIL" }
      )
      formatter = LogFormatter.new(@run.pipeline_events.chronological, pipeline_run: @run, color: false)
      output = formatter.render
      assert_match(/FAIL/, output)
    end

    test "tier_gate_evaluated PASS shows pass badge with decision source" do
      @run.pipeline_events.create!(
        event_type: :tier_execution_started, stage: "execution", tier_number: 0,
        summary: { "tier_number" => 0, "task_count" => 1, "task_titles" => ["X"] }
      )
      @run.pipeline_events.create!(
        event_type: :tier_gate_evaluated, stage: "tier_gate", tier_number: 0,
        summary: { "pass" => true, "decision_source" => "verification_tests_passed" }
      )
      formatter = LogFormatter.new(@run.pipeline_events.chronological, pipeline_run: @run, color: false)
      output = formatter.render
      assert_match(/PASS/, output)
      assert_match(/verification_tests_passed/, output)
    end

    test "tier_gate_evaluated FAIL shows fail badge with issues" do
      @run.pipeline_events.create!(
        event_type: :tier_execution_started, stage: "execution", tier_number: 0,
        summary: { "tier_number" => 0, "task_count" => 1, "task_titles" => ["X"] }
      )
      @run.pipeline_events.create!(
        event_type: :tier_gate_evaluated, stage: "tier_gate", tier_number: 0,
        summary: {
          "pass" => false,
          "decision_source" => "verification_tests_failed",
          "issues" => ["Test suite failed: 67 runs, 1 failure"]
        }
      )
      formatter = LogFormatter.new(@run.pipeline_events.chronological, pipeline_run: @run, color: false)
      output = formatter.render
      assert_match(/FAIL/, output)
      assert_match(/Test suite failed/, output)
    end

    test "criteria_check advisory shows unmet count" do
      @run.pipeline_events.create!(
        event_type: :tier_execution_started, stage: "execution", tier_number: 0,
        summary: { "tier_number" => 0, "task_count" => 1, "task_titles" => ["X"] }
      )
      @run.pipeline_events.create!(
        event_type: :criteria_check, stage: "tier_gate", tier_number: 0,
        summary: { "mode" => "advisory", "verified_count" => 1, "failed_count" => 4, "unverified_count" => 2 }
      )
      formatter = LogFormatter.new(@run.pipeline_events.chronological, pipeline_run: @run, color: false)
      output = formatter.render
      assert_match(/6\/7 unmet/, output)
      assert_match(/advisory/, output)
    end

    test "repo_context_scanned shows file count" do
      @run.pipeline_events.create!(
        event_type: :tier_execution_started, stage: "execution", tier_number: 0,
        summary: { "tier_number" => 0, "task_count" => 1, "task_titles" => ["X"] }
      )
      @run.pipeline_events.create!(
        event_type: :repo_context_scanned, stage: "tier_gate", tier_number: 0,
        summary: { "file_count" => 42, "directories" => ["/app"] }
      )
      formatter = LogFormatter.new(@run.pipeline_events.chronological, pipeline_run: @run, color: false)
      output = formatter.render
      assert_match(/42 files scanned/, output)
    end

    test "horizontal rule separates tier blocks" do
      @run.pipeline_events.create!(
        event_type: :tier_execution_started, stage: "execution", tier_number: 0,
        summary: { "tier_number" => 0, "task_count" => 1, "task_titles" => ["A"] }
      )
      @run.pipeline_events.create!(
        event_type: :tier_execution_completed, stage: "execution", tier_number: 0,
        summary: { "tier_number" => 0, "resolved_count" => 1, "failed_count" => 0 }
      )
      @run.pipeline_events.create!(
        event_type: :tier_execution_started, stage: "execution", tier_number: 1,
        summary: { "tier_number" => 1, "task_count" => 1, "task_titles" => ["B"] }
      )
      @run.pipeline_events.create!(
        event_type: :tier_execution_completed, stage: "execution", tier_number: 1,
        summary: { "tier_number" => 1, "resolved_count" => 1, "failed_count" => 0 }
      )
      formatter = LogFormatter.new(@run.pipeline_events.chronological, pipeline_run: @run, color: false)
      output = formatter.render
      assert output.scan(/─{10,}/).size >= 2, "Expected at least 2 horizontal rules"
    end

    # --- Analysis block ---

    test "analysis_completed creates analysis header with iteration" do
      @run.pipeline_events.create!(
        event_type: :analysis_completed, stage: "analysis", iteration_number: 1,
        summary: { "decision" => "iterate_tasks", "confidence" => 80, "reasoning_excerpt" => "needs fixes" },
        duration_ms: 54600.0
      )
      formatter = LogFormatter.new(@run.pipeline_events.chronological, pipeline_run: @run, color: false)
      output = formatter.render
      assert_match(/ANALYSIS/, output)
      assert_match(/iteration 1/, output)
      assert_match(/54\.6s/, output)
      assert_match(/iterate_tasks/, output)
      assert_match(/confidence=80%/, output)
    end

    test "iteration_decision done shows green checkmark" do
      @run.pipeline_events.create!(
        event_type: :analysis_completed, stage: "analysis", iteration_number: 2,
        summary: { "decision" => "done", "confidence" => 85 }
      )
      @run.pipeline_events.create!(
        event_type: :iteration_decision, stage: "iteration", iteration_number: 2,
        summary: { "decision" => "done" }
      )
      formatter = LogFormatter.new(@run.pipeline_events.chronological, pipeline_run: @run, color: false)
      output = formatter.render
      assert_match(/DONE/, output)
    end

    test "iteration_decision iterate_tasks shows corrective task count" do
      @run.pipeline_events.create!(
        event_type: :analysis_completed, stage: "analysis", iteration_number: 1,
        summary: { "decision" => "iterate_tasks", "confidence" => 80 }
      )
      @run.pipeline_events.create!(
        event_type: :iteration_decision, stage: "iteration", iteration_number: 1,
        summary: { "decision" => "iterate_tasks", "corrective_task_count" => 8 }
      )
      formatter = LogFormatter.new(@run.pipeline_events.chronological, pipeline_run: @run, color: false)
      output = formatter.render
      assert_match(/iterate_tasks/, output)
      assert_match(/8 corrective tasks/, output)
    end

    # --- Terminal banner ---

    test "pipeline_completed renders green banner with summary" do
      @run.pipeline_events.create!(
        event_type: :pipeline_completed, stage: "lifecycle",
        summary: {
          "total_iterations" => 2, "total_tasks" => 8,
          "tasks_succeeded" => 6, "tasks_failed" => 2,
          "total_duration_ms" => 3600000.0, "final_confidence" => 85
        }
      )
      formatter = LogFormatter.new(@run.pipeline_events.chronological, pipeline_run: @run, color: false)
      output = formatter.render
      assert_match(/PIPELINE COMPLETED/, output)
      assert_match(/2 iterations, 8 tasks/, output)
      assert_match(/6 succeeded, 2 failed/, output)
      assert_match(/1\.0h/, output)
      assert_match(/85% confidence/, output)
    end

    test "pipeline_failed renders red banner with error" do
      @run.pipeline_events.create!(
        event_type: :pipeline_failed, stage: "lifecycle",
        summary: {
          "error_class" => "JSON::ParserError",
          "error_message" => "unexpected token",
          "failed_stage" => "break_tasks",
          "llm_provider" => "openai", "llm_model" => "gpt-5-mini",
          "execution_provider" => "claude_code"
        }
      )
      formatter = LogFormatter.new(@run.pipeline_events.chronological, pipeline_run: @run, color: false)
      output = formatter.render
      assert_match(/PIPELINE FAILED/, output)
      assert_match(/break_tasks/, output)
      assert_match(/JSON::ParserError: unexpected token/, output)
      assert_match(/openai/, output)
    end

    test "pipeline_failed with task counts and duration" do
      @run.pipeline_events.create!(
        event_type: :pipeline_failed, stage: "lifecycle",
        summary: {
          "error_class" => "RuntimeError", "error_message" => "Something broke",
          "total_tasks" => 5, "tasks_succeeded" => 3, "tasks_failed" => 2,
          "total_duration_ms" => 125000.0
        }
      )
      formatter = LogFormatter.new(@run.pipeline_events.chronological, pipeline_run: @run, color: false)
      output = formatter.render
      assert_match(/5 tasks.*3 succeeded.*2 failed/, output)
      assert_match(/2\.1m/, output)
    end

    test "pipeline_failed with raw_response_excerpt truncates to 200 chars" do
      @run.pipeline_events.create!(
        event_type: :pipeline_failed, stage: "lifecycle",
        summary: {
          "error_class" => "RuntimeError", "error_message" => "parse error",
          "raw_response_excerpt" => "x" * 300
        }
      )
      formatter = LogFormatter.new(@run.pipeline_events.chronological, pipeline_run: @run, color: false)
      output = formatter.render
      assert_match(/x{200}\.\.\./, output)
    end

    # --- Verbose mode ---

    test "verbose mode shows per-task outcomes for tier_execution_completed" do
      @run.pipeline_events.create!(
        event_type: :tier_execution_started, stage: "execution", tier_number: 0,
        summary: { "tier_number" => 0, "task_count" => 2, "task_titles" => ["Setup DB", "Add API"] }
      )
      @run.pipeline_events.create!(
        event_type: :tier_execution_completed, stage: "execution", tier_number: 0,
        summary: {
          "tier_number" => 0, "resolved_count" => 1, "failed_count" => 1,
          "task_outcomes" => [
            { "title" => "Setup DB", "status" => "resolved" },
            { "title" => "Add API", "status" => "failed", "failure_reason" => "empty_diff" }
          ]
        }
      )
      formatter = LogFormatter.new(@run.pipeline_events.chronological, pipeline_run: @run, color: false, verbose: true)
      output = formatter.render
      assert_match(/Setup DB/, output)
      assert_match(/Add API.*empty_diff/, output)
    end

    test "verbose mode shows per-criterion results" do
      @run.pipeline_events.create!(
        event_type: :tier_execution_started, stage: "execution", tier_number: 0,
        summary: { "tier_number" => 0, "task_count" => 1, "task_titles" => ["X"] }
      )
      @run.pipeline_events.create!(
        event_type: :criteria_check, stage: "tier_gate", tier_number: 0,
        summary: {
          "verified_count" => 1, "failed_count" => 1, "unverified_count" => 0,
          "criteria" => [
            { "type" => "file_exists", "description" => "Gemfile exists", "result" => "verified" },
            { "type" => "route_exists", "description" => "Health check route", "result" => "failed" }
          ]
        }
      )
      formatter = LogFormatter.new(@run.pipeline_events.chronological, pipeline_run: @run, color: false, verbose: true)
      output = formatter.render
      assert_match(/PASS: Gemfile exists/, output)
      assert_match(/FAIL: Health check route/, output)
    end

    test "verbose mode shows corrective tasks for failed gate" do
      @run.pipeline_events.create!(
        event_type: :tier_execution_started, stage: "execution", tier_number: 0,
        summary: { "tier_number" => 0, "task_count" => 1, "task_titles" => ["X"] }
      )
      @run.pipeline_events.create!(
        event_type: :tier_gate_evaluated, stage: "tier_gate", tier_number: 0,
        summary: {
          "pass" => false, "issues" => ["Missing route"],
          "corrective_tasks" => [
            { "title" => "Add route", "description" => "Add GET /up" }
          ]
        }
      )
      formatter = LogFormatter.new(@run.pipeline_events.chronological, pipeline_run: @run, color: false, verbose: true)
      output = formatter.render
      assert_match(/Corrective tasks/, output)
      assert_match(/1\. Add route/, output)
    end

    test "non-verbose mode hides per-task outcomes" do
      @run.pipeline_events.create!(
        event_type: :tier_execution_started, stage: "execution", tier_number: 0,
        summary: { "tier_number" => 0, "task_count" => 2, "task_titles" => ["Setup DB", "Add API"] }
      )
      @run.pipeline_events.create!(
        event_type: :tier_execution_completed, stage: "execution", tier_number: 0,
        summary: {
          "tier_number" => 0, "resolved_count" => 2, "failed_count" => 0,
          "task_outcomes" => [
            { "title" => "Setup DB", "status" => "resolved" },
            { "title" => "Add API", "status" => "resolved" }
          ]
        }
      )
      formatter = LogFormatter.new(@run.pipeline_events.chronological, pipeline_run: @run, color: false, verbose: false)
      output = formatter.render
      # Task titles appear in the tier header bullets, but per-task outcome lines
      # (with checkmark + status) should NOT appear in non-verbose mode
      assert_no_match(/Setup DB.*resolved/, output)
      assert_no_match(/Add API.*resolved/, output)
    end
  end
end
