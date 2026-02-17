# Color-Coded Log Output Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the flat `arnold log` output with a color-coded, structurally-grouped display that encodes status (pass/fail) via color and grouping (tier/analysis blocks) via layout.

**Architecture:** Extract a `LogFormatter` class from the CLI that takes events and produces the full formatted string. A small `AnsiColor` module provides composable ANSI styling methods. The CLI `log` command delegates to `LogFormatter` for human-readable output while keeping `--json` unchanged.

**Tech Stack:** Ruby, Thor CLI, ANSI escape codes (no gem dependencies)

---

### Task 1: Create AnsiColor Module

**Files:**
- Create: `lib/arnold_pipeline/ansi_color.rb`
- Test: `test/lib/arnold_pipeline/ansi_color_test.rb`

**Step 1: Write the failing test**

```ruby
# test/lib/arnold_pipeline/ansi_color_test.rb
require "test_helper"

module ArnoldPipeline
  class AnsiColorTest < ActiveSupport::TestCase
    include AnsiColor

    test "bold wraps text with bold codes" do
      assert_equal "\e[1mhello\e[0m", bold("hello")
    end

    test "dim wraps text with dim codes" do
      assert_equal "\e[2mhello\e[0m", dim("hello")
    end

    test "red wraps text with red codes" do
      assert_equal "\e[31mhello\e[0m", red("hello")
    end

    test "green wraps text with green codes" do
      assert_equal "\e[32mhello\e[0m", green("hello")
    end

    test "yellow wraps text with yellow codes" do
      assert_equal "\e[33mhello\e[0m", yellow("hello")
    end

    test "cyan wraps text with cyan codes" do
      assert_equal "\e[36mhello\e[0m", cyan("hello")
    end

    test "magenta wraps text with magenta codes" do
      assert_equal "\e[35mhello\e[0m", magenta("hello")
    end

    test "bg_green wraps with green background and black text" do
      assert_equal "\e[42;30m PASS \e[0m", bg_green(" PASS ")
    end

    test "bg_red wraps with red background and white text" do
      assert_equal "\e[41;37m FAIL \e[0m", bg_red(" FAIL ")
    end

    test "composing bold and red nests codes" do
      result = bold(red("error"))
      assert_includes result, "\e[1m"
      assert_includes result, "\e[31m"
      assert_includes result, "error"
    end

    test "strip_ansi removes all ANSI escape codes" do
      styled = bold(red("hello"))
      assert_equal "hello", strip_ansi(styled)
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rails test test/lib/arnold_pipeline/ansi_color_test.rb`
Expected: FAIL — cannot load AnsiColor

**Step 3: Write minimal implementation**

```ruby
# lib/arnold_pipeline/ansi_color.rb
module ArnoldPipeline
  module AnsiColor
    def bold(text)     = "\e[1m#{text}\e[0m"
    def dim(text)      = "\e[2m#{text}\e[0m"
    def red(text)      = "\e[31m#{text}\e[0m"
    def green(text)    = "\e[32m#{text}\e[0m"
    def yellow(text)   = "\e[33m#{text}\e[0m"
    def cyan(text)     = "\e[36m#{text}\e[0m"
    def magenta(text)  = "\e[35m#{text}\e[0m"
    def bg_green(text) = "\e[42;30m#{text}\e[0m"
    def bg_red(text)   = "\e[41;37m#{text}\e[0m"

    def strip_ansi(text)
      text.gsub(/\e\[[0-9;]*m/, "")
    end
  end
end
```

**Step 4: Run test to verify it passes**

Run: `bundle exec rails test test/lib/arnold_pipeline/ansi_color_test.rb`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/arnold_pipeline/ansi_color.rb test/lib/arnold_pipeline/ansi_color_test.rb
git commit -m "feat: add AnsiColor module for terminal styling"
```

---

### Task 2: Create LogFormatter — Skeleton and Preamble Events

**Files:**
- Create: `lib/arnold_pipeline/log_formatter.rb`
- Create: `test/lib/arnold_pipeline/log_formatter_test.rb`

This task covers the LogFormatter class skeleton, color gating, and rendering preamble events (library_selection, spec_generated, tasks_broken).

**Step 1: Write the failing test**

```ruby
# test/lib/arnold_pipeline/log_formatter_test.rb
require "test_helper"

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
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rails test test/lib/arnold_pipeline/log_formatter_test.rb`
Expected: FAIL — cannot load LogFormatter

**Step 3: Write minimal implementation**

```ruby
# lib/arnold_pipeline/log_formatter.rb
require_relative "ansi_color"

module ArnoldPipeline
  class LogFormatter
    include AnsiColor

    LABEL_WIDTH = 13

    def initialize(events, pipeline_run:, color: true, verbose: false)
      @events = events.to_a
      @pipeline_run = pipeline_run
      @color = color
      @verbose = verbose
    end

    def render
      lines = []
      lines << header
      lines << ""

      # Partition events into blocks: preamble, tier blocks, analysis blocks, terminal
      blocks = partition_events
      blocks.each { |block| render_block(block, lines) }

      lines.join("\n") + "\n"
    end

    private

    def header
      date = @events.first&.created_at&.strftime("%Y-%m-%d") || ""
      [
        "Pipeline Run ##{@pipeline_run.id}",
        date
      ].join("\n")
    end

    def partition_events
      blocks = []
      current_block = { type: :preamble, events: [] }

      @events.each do |event|
        case event.event_type
        when "tier_execution_started"
          blocks << current_block unless current_block[:events].empty?
          current_block = {
            type: :tier,
            tier_number: event.summary&.dig("tier_number") || event.tier_number,
            task_count: event.summary&.dig("task_count"),
            task_titles: event.summary&.dig("task_titles") || [],
            events: []
          }
        when "analysis_completed"
          blocks << current_block unless current_block[:events].empty?
          current_block = {
            type: :analysis,
            iteration: event.iteration_number,
            duration_ms: event.duration_ms,
            events: [event]
          }
          next
        when "pipeline_completed", "pipeline_failed", "pipeline_paused"
          blocks << current_block unless current_block[:events].empty?
          blocks << { type: :terminal, events: [event] }
          current_block = { type: :preamble, events: [] }
          next
        end
        current_block[:events] << event
      end

      blocks << current_block unless current_block[:events].empty?
      blocks
    end

    def render_block(block, lines)
      case block[:type]
      when :preamble
        block[:events].each { |e| lines << format_event(e) }
      when :tier
        lines << ""
        lines << horizontal_rule
        tier_num = block[:tier_number]
        task_count = block[:task_count]
        task_label = task_count == 1 ? "1 task" : "#{task_count} tasks"
        lines << c(bold("▶ TIER #{tier_num}"), :magenta) + "  (#{task_label})"
        (block[:task_titles] || []).each do |title|
          lines << "  • #{title}"
        end
        block[:events].each do |e|
          next if e.event_type == "tier_execution_started"
          lines << format_event(e)
        end
      when :analysis
        lines << ""
        lines << horizontal_rule
        iter = block[:iteration]
        dur = block[:duration_ms] ? " (#{format_duration(block[:duration_ms])})" : ""
        lines << c(bold("◆ ANALYSIS"), :cyan) + " (iteration #{iter})#{dur}"
        block[:events].each { |e| lines << format_event(e) }
      when :terminal
        block[:events].each { |e| lines << format_terminal(e) }
      end
    end

    def format_event(event)
      ts = timestamp(event)
      case event.event_type
      when "library_selection"
        s = event.summary || {}
        "  #{ts}  #{label('library')}  persona=#{s['persona']}  recipe=#{s['recipe']}  domain=#{s['domain_type']}"
      when "spec_generated"
        s = event.summary || {}
        chars = number_with_delimiter(s["content_length"])
        dur = event.duration_ms ? " (#{format_duration(event.duration_ms)})" : ""
        "  #{ts}  #{label('spec')}  #{c('✓', :green)} v#{s['spec_version']} generated (#{chars} chars)#{dur}"
      when "tasks_broken"
        s = event.summary || {}
        dur = event.duration_ms ? " (#{format_duration(event.duration_ms)})" : ""
        "  #{ts}  #{label('tasks')}  #{c('✓', :green)} #{s['task_count']} tasks → #{s['tier_count']} tiers (#{s['dependency_edge_count']} deps)#{dur}"
      when "tier_execution_completed"
        format_tier_completed(event)
      when "post_merge_hooks"
        format_hooks(event)
      when "verification_checks", "verification_execution"
        format_verification(event)
      when "criteria_check"
        format_criteria(event)
      when "repo_context_scanned"
        format_repo_scan(event)
      when "tier_gate_evaluated"
        format_gate(event)
      when "analysis_completed"
        format_analysis_decision(event)
      when "iteration_decision"
        format_iteration_outcome(event)
      when "spec_delta_merged"
        format_spec_delta(event)
      when "pipeline_paused"
        s = event.summary || {}
        "  #{ts}  #{label('paused')}  #{s['reason']}"
      else
        s = event.summary || {}
        "  #{ts}  #{label(event.event_type.to_s[0..11])}  #{s.inspect}"
      end
    end

    def format_tier_completed(event)
      s = event.summary || {}
      ts = timestamp(event)
      resolved = s["resolved_count"] || 0
      failed = s["failed_count"] || 0

      if failed > 0
        result = "#{c("✗ #{failed} failed", :red)}, #{resolved} ok"
      else
        result = c("✓ #{resolved} passed", :green)
      end

      line = "  #{ts}  #{label('tasks')}  #{result}"

      if @verbose && s["task_outcomes"]
        s["task_outcomes"].each do |outcome|
          status_str = outcome["status"] == "resolved" ? c("✓", :green) : c("✗", :red)
          reason = outcome["failure_reason"] ? " (#{outcome['failure_reason']})" : ""
          line += "\n    #{status_str} #{outcome['title']}#{reason}"
        end
      end

      line
    end

    def format_hooks(event)
      s = event.summary || {}
      ts = timestamp(event)
      triggered = s["triggered_count"] || 0
      total = s["hook_count"] || 0

      if triggered == 0
        "  #{ts}  #{label('hooks')}  #{c('no hooks triggered', :dim)}"
      else
        success = s["success_count"] || 0
        if success == triggered
          "  #{ts}  #{label('hooks')}  #{c("#{triggered}/#{total} triggered OK", :green)}"
        else
          "  #{ts}  #{label('hooks')}  #{c("#{success}/#{triggered} passed", :yellow)} (#{total} total)"
        end
      end
    end

    def format_verification(event)
      s = event.summary || {}
      ts = timestamp(event)
      all_passed = s["all_passed"]
      summary_text = s["summary"] || ""

      if all_passed
        "  #{ts}  #{label('verify')}  #{c(bg_green(' PASS '), :none)}  #{summary_text}"
      else
        "  #{ts}  #{label('verify')}  #{c(bg_red(' FAIL '), :none)}  #{summary_text}"
      end
    end

    def format_criteria(event)
      s = event.summary || {}
      ts = timestamp(event)
      v = s["verified_count"] || 0
      f = s["failed_count"] || 0
      u = s["unverified_count"] || 0
      total = v + f + u
      unmet = f + u
      mode = s["mode"]

      if mode == "advisory"
        text = "#{unmet}/#{total} unmet #{c('(advisory)', :dim)}"
        line = "  #{ts}  #{label('criteria')}  #{c(text, :yellow)}"
      elsif f > 0
        line = "  #{ts}  #{label('criteria')}  #{c("#{f} failed", :red)}, #{v} verified"
      else
        line = "  #{ts}  #{label('criteria')}  #{c("#{v}/#{total} verified", :green)}"
      end

      if @verbose && s["criteria"]
        s["criteria"].each do |cr|
          badge = case cr["result"]
          when "verified" then c("PASS", :green)
          when "failed" then c("FAIL", :red)
          else c("UNVERIFIED", :yellow)
          end
          line += "\n    #{badge}: #{cr['description']} (#{cr['type']})"
        end
      end

      line
    end

    def format_repo_scan(event)
      s = event.summary || {}
      ts = timestamp(event)
      "  #{ts}  #{label('scan')}  #{c("#{s['file_count']} files scanned", :dim)}"
    end

    def format_gate(event)
      s = event.summary || {}
      ts = timestamp(event)
      passed = s["pass"]
      decision_source = s["decision_source"]
      source_text = decision_source ? " via #{decision_source}" : ""

      if passed
        line = "  #{ts}  #{label('gate')}  #{bg_green(' PASS ')}#{source_text}"
      else
        line = "  #{ts}  #{label('gate')}  #{bg_red(' FAIL ')}#{source_text}"
        issues = s["issues"] || []
        issues.each do |issue|
          line += "\n           #{' ' * LABEL_WIDTH}#{c("↳ #{issue}", :red)}"
        end
      end

      if @verbose && s["corrective_tasks"]&.any?
        line += "\n           #{' ' * LABEL_WIDTH}Corrective tasks:"
        s["corrective_tasks"].each_with_index do |t, i|
          line += "\n           #{' ' * LABEL_WIDTH}  #{i + 1}. #{t['title']}"
        end
      end

      line
    end

    def format_analysis_decision(event)
      s = event.summary || {}
      ts = timestamp(event)
      decision = s["decision"]
      confidence = s["confidence"]

      marker, color_sym = case decision
      when "done" then ["✓", :green]
      when "iterate_tasks" then ["↻", :yellow]
      when "iterate_spec" then ["↻", :yellow]
      else ["?", :white]
      end

      line = "  #{ts}  #{label('decision')}  #{c("#{marker} #{decision}", color_sym)}  confidence=#{confidence}%"

      if s["reasoning_excerpt"].present?
        line += "\n           #{' ' * LABEL_WIDTH}#{c(s['reasoning_excerpt'], :dim)}"
      end

      line
    end

    def format_iteration_outcome(event)
      s = event.summary || {}
      ts = timestamp(event)
      decision = s["decision"]

      marker, color_sym = case decision
      when "done" then ["✓ DONE", :green]
      when "iterate_tasks" then ["↻ iterate_tasks", :yellow]
      when "iterate_spec" then ["↻ iterate_spec", :yellow]
      else [decision, :white]
      end

      details = []
      details << "#{s['corrective_task_count']} corrective tasks" if s["corrective_task_count"]&.> 0

      suffix = details.any? ? " → #{details.join(', ')}" : ""
      "  #{ts}  #{label('outcome')}  #{c("#{marker}#{suffix}", color_sym)}"
    end

    def format_spec_delta(event)
      s = event.summary || {}
      ts = timestamp(event)
      "  #{ts}  #{label('spec')}  #{s['merge_strategy']}, #{s['delta_count']} deltas → v#{s['new_version']}"
    end

    def format_terminal(event)
      s = event.summary || {}
      case event.event_type
      when "pipeline_completed"
        iterations = s["total_iterations"]
        tasks = s["total_tasks"]
        duration = s["total_duration_ms"] ? "  #{format_duration(s['total_duration_ms'])}" : ""
        confidence = s["final_confidence"] ? "  #{s['final_confidence']}% confidence" : ""
        task_detail = ""
        if s["tasks_succeeded"] || s["tasks_failed"]
          task_detail = "  (#{s['tasks_succeeded']} succeeded, #{s['tasks_failed']} failed)"
        end
        "\n #{bg_green(' ✓ PIPELINE COMPLETED ')}  #{iterations} iterations, #{tasks} tasks#{task_detail}#{duration}#{confidence}"
      when "pipeline_failed"
        error = "#{s['error_class']}: #{s['error_message']}"
        stage = s["failed_stage"] ? "  during #{s['failed_stage']}" : ""
        provider = s["llm_provider"] ? "\n  provider: #{s['llm_provider']}/#{s['llm_model']}" : ""
        exec = s["execution_provider"] ? "  execution: #{s['execution_provider']}" : ""
        task_info = ""
        if s["total_tasks"]
          task_info = "\n  #{s['total_tasks']} tasks: #{s['tasks_succeeded']} succeeded, #{s['tasks_failed']} failed"
        end
        duration = s["total_duration_ms"] ? "  #{format_duration(s['total_duration_ms'])}" : ""
        excerpt = ""
        if s["raw_response_excerpt"]
          excerpt = "\n  #{s['raw_response_excerpt'][0, 200]}..."
        end
        "\n #{bg_red(' ✗ PIPELINE FAILED ')}#{stage}\n  #{error}#{provider}#{exec}#{task_info}#{duration}#{excerpt}"
      when "pipeline_paused"
        "\n #{c(bold(' ⏸ PIPELINE PAUSED '), :yellow)}  #{s['reason']}"
      end
    end

    # --- Helpers ---

    def timestamp(event)
      ts = event.created_at.strftime("%H:%M:%S")
      @color ? dim(ts) : ts
    end

    def label(name)
      padded = name.ljust(LABEL_WIDTH)
      @color ? padded : padded
    end

    def horizontal_rule
      "─" * 70
    end

    # Colorize text, respecting @color flag
    def c(text, color_sym)
      return text unless @color
      case color_sym
      when :red then red(text)
      when :green then green(text)
      when :yellow then yellow(text)
      when :cyan then cyan(text)
      when :magenta then magenta(text)
      when :dim then dim(text)
      when :none then text
      else text
      end
    end

    # Override AnsiColor methods to be no-ops when color disabled
    def bold(text)
      @color ? super : text
    end

    def dim(text)
      @color ? super : text
    end

    def bg_green(text)
      @color ? super : text
    end

    def bg_red(text)
      @color ? super : text
    end

    def format_duration(ms)
      return "N/A" unless ms
      seconds = ms / 1000.0
      if seconds < 60
        "#{seconds.round(1)}s"
      elsif seconds < 3600
        "#{(seconds / 60).round(1)}m"
      else
        "#{(seconds / 3600).round(1)}h"
      end
    end

    def number_with_delimiter(num)
      return "0" unless num
      num.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
    end
  end
end
```

**Step 4: Run test to verify it passes**

Run: `bundle exec rails test test/lib/arnold_pipeline/log_formatter_test.rb`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/arnold_pipeline/log_formatter.rb test/lib/arnold_pipeline/log_formatter_test.rb
git commit -m "feat: add LogFormatter class with preamble event rendering"
```

---

### Task 3: LogFormatter — Tier Block Rendering

**Files:**
- Modify: `test/lib/arnold_pipeline/log_formatter_test.rb`
- Modify: `lib/arnold_pipeline/log_formatter.rb` (if needed)

Tests for tier execution events: tier_execution_started groups into blocks, tier_execution_completed shows pass/fail counts, post_merge_hooks, verification_checks, criteria_check, repo_context_scanned, tier_gate_evaluated.

**Step 1: Write the failing tests**

Add to `log_formatter_test.rb`:

```ruby
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
      assert_match(/↳ Test suite failed/, output)
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
```

**Step 2: Run test to verify failures**

Run: `bundle exec rails test test/lib/arnold_pipeline/log_formatter_test.rb`
Expected: Most should pass (implementation is in Task 2). Fix any edge cases.

**Step 3: Fix any failing assertions**

Review output and adjust `LogFormatter` if any rendering doesn't match expectations.

**Step 4: Run tests to verify all pass**

Run: `bundle exec rails test test/lib/arnold_pipeline/log_formatter_test.rb`
Expected: PASS

**Step 5: Commit**

```bash
git add test/lib/arnold_pipeline/log_formatter_test.rb lib/arnold_pipeline/log_formatter.rb
git commit -m "test: add tier block rendering tests for LogFormatter"
```

---

### Task 4: LogFormatter — Analysis and Terminal Blocks

**Files:**
- Modify: `test/lib/arnold_pipeline/log_formatter_test.rb`
- Modify: `lib/arnold_pipeline/log_formatter.rb` (if needed)

Tests for analysis_completed, iteration_decision, spec_delta_merged, pipeline_completed, pipeline_failed.

**Step 1: Write the failing tests**

Add to `log_formatter_test.rb`:

```ruby
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
```

**Step 2: Run tests**

Run: `bundle exec rails test test/lib/arnold_pipeline/log_formatter_test.rb`
Expected: Most should pass. Fix any edge cases.

**Step 3: Fix any issues, run again**

**Step 4: Commit**

```bash
git add test/lib/arnold_pipeline/log_formatter_test.rb lib/arnold_pipeline/log_formatter.rb
git commit -m "test: add analysis block and terminal banner tests for LogFormatter"
```

---

### Task 5: LogFormatter — Verbose Mode Tests

**Files:**
- Modify: `test/lib/arnold_pipeline/log_formatter_test.rb`

**Step 1: Write the failing tests**

```ruby
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
      assert_no_match(/Setup DB/, output)
    end
```

**Step 2: Run tests, fix any issues**

**Step 3: Commit**

```bash
git add test/lib/arnold_pipeline/log_formatter_test.rb lib/arnold_pipeline/log_formatter.rb
git commit -m "test: add verbose mode tests for LogFormatter"
```

---

### Task 6: Integrate LogFormatter into CLI

**Files:**
- Modify: `lib/arnold_pipeline/cli.rb` (lines 324-366, the `log` method)
- Modify: `test/lib/arnold_pipeline/cli_test.rb` (update existing log tests)

**Step 1: Add `--no-color` option and wire up LogFormatter in CLI**

In `lib/arnold_pipeline/cli.rb`, update the `log` command:

```ruby
    desc "log ID", "Show the event audit trail for a pipeline run"
    option :json, type: :boolean, default: false, desc: "Output as JSON"
    option :stage, type: :string, desc: "Filter events by stage"
    option :verbose, type: :boolean, default: false, desc: "Include full payloads"
    option :no_color, type: :boolean, default: false, desc: "Disable color output"
    def log(id)
      setup_standalone!

      run_record = PipelineRun.find_by(id:)
      unless run_record
        say_error "Pipeline run ##{id} not found", :red
        raise SystemExit.new(1)
      end

      events = run_record.pipeline_events.chronological
      events = events.for_stage(options[:stage]) if options[:stage]

      if events.empty?
        say "No events found for pipeline run ##{id}", :yellow
        return
      end

      if options[:json]
        data = events.map { |e| event_to_hash(e, include_payload: options[:verbose]) }
        say JSON.pretty_generate(data)
        return
      end

      color = !options[:no_color] && $stdout.tty? && !ENV["NO_COLOR"]
      formatter = LogFormatter.new(
        events,
        pipeline_run: run_record,
        color: color,
        verbose: options[:verbose]
      )
      say formatter.render
    end
```

Add `require_relative "log_formatter"` near the top of the CLI file (after existing requires).

**Step 2: Update existing CLI log tests to match new output format**

The existing CLI log tests assert on the old format (`spec_generation / library_selection`, `Event Timeline`, etc.). Update them to match the new LogFormatter output. Key changes:

- `"Event Timeline (2 events)"` → `"Pipeline Run #"` (header changed)
- `"spec_generation / library_selection"` → `"library"` (compact labels)
- `"spec_generation / spec_generated"` → `"spec"` + `"v1"`
- `"3413ms"` → `"3.4s"` (duration format changed)
- Verbose payload assertions stay but the payload display needs updating (LogFormatter doesn't render raw payloads — need to add that or adjust tests)

For each existing test, update the assertion patterns to match LogFormatter output. Some tests may need adjustment because LogFormatter doesn't render raw `Payload:` output — consider adding verbose payload support to LogFormatter or dropping that from the non-JSON output (verbose payloads are really for `--json --verbose`).

**Decision:** Add verbose payload support to LogFormatter. When `verbose: true` and `event.payload.present?`, append indented payload JSON after the event line.

**Step 3: Run full test suite**

Run: `bundle exec rails test`
Expected: All tests pass including updated CLI tests

**Step 4: Commit**

```bash
git add lib/arnold_pipeline/cli.rb test/lib/arnold_pipeline/cli_test.rb
git commit -m "feat: integrate LogFormatter into CLI log command [SPEC-EVENT-008]"
```

---

### Task 7: Clean Up Old Code

**Files:**
- Modify: `lib/arnold_pipeline/cli.rb`

**Step 1: Remove the old `format_event_summary` method**

The old method at lines 644-728 is no longer called by the `log` command. Check if any other command uses it.

Run: `grep -n "format_event_summary" lib/arnold_pipeline/cli.rb`

If only the old `log` method called it, remove it. Also remove `status_color` if unused.

Keep `format_duration` and `event_to_hash` — they're still used by `--json` output.

**Step 2: Run full test suite**

Run: `bundle exec rails test`
Expected: PASS (no other code depends on removed methods)

**Step 3: Commit**

```bash
git add lib/arnold_pipeline/cli.rb
git commit -m "refactor: remove old format_event_summary from CLI"
```

---

### Task 8: Full Integration Test — End-to-End Log Output

**Files:**
- Modify: `test/lib/arnold_pipeline/log_formatter_test.rb`

**Step 1: Write end-to-end test simulating a real pipeline run's events**

```ruby
    test "full pipeline run renders complete structured output" do
      # Preamble
      @run.pipeline_events.create!(event_type: :library_selection, stage: "spec_generation",
        summary: { "persona" => "General Analyst", "recipe" => "Generic", "domain_type" => "PRODUCTIVITY" })
      @run.pipeline_events.create!(event_type: :spec_generated, stage: "spec_generation",
        summary: { "spec_version" => 1, "content_length" => 29296 }, duration_ms: 57000.0)
      @run.pipeline_events.create!(event_type: :tasks_broken, stage: "task_breakdown",
        summary: { "task_count" => 12, "tier_count" => 9, "dependency_edge_count" => 18 }, duration_ms: 55100.0)

      # Tier 0
      @run.pipeline_events.create!(event_type: :tier_execution_started, stage: "execution", tier_number: 0,
        summary: { "tier_number" => 0, "task_count" => 1, "task_titles" => ["Project bootstrap"] })
      @run.pipeline_events.create!(event_type: :tier_execution_completed, stage: "execution", tier_number: 0,
        summary: { "tier_number" => 0, "resolved_count" => 1, "failed_count" => 0 })
      @run.pipeline_events.create!(event_type: :post_merge_hooks, stage: "execution", tier_number: 0,
        summary: { "hook_count" => 2, "triggered_count" => 2, "success_count" => 2 })
      @run.pipeline_events.create!(event_type: :verification_checks, stage: "execution", tier_number: 0,
        summary: { "all_passed" => true, "summary" => "4 passed, 0 failed" })
      @run.pipeline_events.create!(event_type: :criteria_check, stage: "tier_gate", tier_number: 0,
        summary: { "mode" => "advisory", "verified_count" => 1, "failed_count" => 4, "unverified_count" => 2 })
      @run.pipeline_events.create!(event_type: :tier_gate_evaluated, stage: "tier_gate", tier_number: 0,
        summary: { "pass" => true, "decision_source" => "verification_tests_passed" })

      # Analysis
      @run.pipeline_events.create!(event_type: :analysis_completed, stage: "analysis", iteration_number: 1,
        summary: { "decision" => "done", "confidence" => 85 }, duration_ms: 54600.0)
      @run.pipeline_events.create!(event_type: :iteration_decision, stage: "iteration", iteration_number: 1,
        summary: { "decision" => "done" })

      # Terminal
      @run.pipeline_events.create!(event_type: :pipeline_completed, stage: "lifecycle",
        summary: { "total_iterations" => 1, "total_tasks" => 12, "tasks_succeeded" => 12, "tasks_failed" => 0, "total_duration_ms" => 600000.0, "final_confidence" => 85 })

      formatter = LogFormatter.new(@run.pipeline_events.chronological, pipeline_run: @run, color: false)
      output = formatter.render

      # Verify structure
      assert_match(/Pipeline Run ##{@run.id}/, output)
      assert_match(/library.*persona=General Analyst/, output)
      assert_match(/spec.*v1 generated/, output)
      assert_match(/tasks.*12 tasks/, output)
      assert_match(/TIER 0/, output)
      assert_match(/Project bootstrap/, output)
      assert_match(/PASS/, output)
      assert_match(/ANALYSIS.*iteration 1/, output)
      assert_match(/DONE/, output)
      assert_match(/PIPELINE COMPLETED/, output)
      assert_match(/85% confidence/, output)

      # Verify ordering: preamble before tier, tier before analysis, analysis before terminal
      preamble_pos = output.index("library")
      tier_pos = output.index("TIER 0")
      analysis_pos = output.index("ANALYSIS")
      terminal_pos = output.index("PIPELINE COMPLETED")
      assert preamble_pos < tier_pos, "preamble should come before tier"
      assert tier_pos < analysis_pos, "tier should come before analysis"
      assert analysis_pos < terminal_pos, "analysis should come before terminal"
    end
```

**Step 2: Run tests**

Run: `bundle exec rails test test/lib/arnold_pipeline/log_formatter_test.rb`
Expected: PASS

**Step 3: Run full suite**

Run: `bundle exec rails test`
Expected: PASS

**Step 4: Commit**

```bash
git add test/lib/arnold_pipeline/log_formatter_test.rb
git commit -m "test: add end-to-end integration test for LogFormatter"
```

---

### Task 9: Final Verification and Full Suite

**Step 1: Run full test suite**

Run: `bundle exec rails test`
Expected: All tests pass (990+ tests)

**Step 2: Manual verification with real data (if available)**

If a pipeline run exists in the local DB:
```bash
bundle exec arnold log 67
bundle exec arnold log 67 --no-color
bundle exec arnold log 67 --verbose
bundle exec arnold log 67 --json
```

**Step 3: Commit any final fixes**

If anything needs adjustment, fix and commit.
