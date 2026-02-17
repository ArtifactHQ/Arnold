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
  end
end
