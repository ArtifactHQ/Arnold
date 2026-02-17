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
  end
end
