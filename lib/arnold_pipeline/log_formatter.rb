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
            events: [ event ]
          }
          next
        when "pipeline_completed", "pipeline_failed", "pipeline_paused", "pipeline_resumed"
          blocks << current_block unless current_block[:events].empty?
          blocks << { type: :terminal, events: [ event ] }
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
      line = case event.event_type
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

      if @verbose && event.payload.present?
        line += "\n  Payload: #{JSON.pretty_generate(event.payload).gsub("\n", "\n  ")}"
      end

      line
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
        "  #{ts}  #{label('verify')}  #{bg_green(' PASS ')}  #{summary_text}"
      else
        "  #{ts}  #{label('verify')}  #{bg_red(' FAIL ')}  #{summary_text}"
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
      when "done" then [ "✓", :green ]
      when "iterate_tasks" then [ "↻", :yellow ]
      when "iterate_spec" then [ "↻", :yellow ]
      else [ "?", :white ]
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
      when "done" then [ "✓ DONE", :green ]
      when "iterate_tasks" then [ "↻ iterate_tasks", :yellow ]
      when "iterate_spec" then [ "↻ iterate_spec", :yellow ]
      else [ decision, :white ]
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
      when "pipeline_resumed"
        stage = s["resumed_from_stage"] ? "from #{s['resumed_from_stage']}" : ""
        prev = s["previous_status"] ? " (was #{s['previous_status']})" : ""
        "\n #{c(bold(' ▶ PIPELINE RESUMED '), :cyan)}  #{stage}#{prev}"
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
