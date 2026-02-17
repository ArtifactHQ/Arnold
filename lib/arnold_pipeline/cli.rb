require "thor"
require "yaml"
require "json"
require "logger"
require "fileutils"
require_relative "log_formatter"

module ArnoldPipeline
  class Cli < Thor
    package_name "arnold"
    class_option :quiet, type: :boolean, default: false, desc: "Suppress informational output"
    def self.exit_on_failure? = true

    STANDALONE_DB_DIR = File.expand_path("~/.arnold_pipeline")
    STANDALONE_DB_PATH = File.join(STANDALONE_DB_DIR, "pipeline.sqlite3")

    desc "run DESCRIPTION", "Run the full pipeline from a natural language description"
    option :config, type: :string, desc: "Path to YAML config file"
    option :provider, type: :string, desc: "LLM provider (anthropic or openai)"
    option :model, type: :string, desc: "LLM model name"
    option :repo, type: :string, desc: "GitHub repo (owner/repo)"
    option :issue_mention, type: :string, desc: "Mention to include in issue body (e.g. @claude)"
    option :polling_interval, type: :numeric, desc: "Polling interval in seconds (default: 30)"
    option :polling_timeout, type: :numeric, desc: "Polling timeout in seconds (default: 1800)"
    option :execution_provider, type: :string, desc: "Execution provider (github, claude_code, null)"
    option :claude_code_repo_path, type: :string, desc: "Path to repo for Claude Code provider"
    option :claude_code_model, type: :string, desc: "Claude Code model (default: sonnet)"
    option :claude_code_max_turns, type: :numeric, desc: "Max turns for Claude Code execution"
    option :claude_code_permission_mode, type: :string, desc: "Claude Code permission mode (default: bypassPermissions)"
    option :stop_after, type: :string, desc: "Stop after stage: spec, tasks, executed"
    option :preview, type: :boolean, default: false, aliases: ["--dry-run"], desc: "Generate spec and tasks without publishing to execution provider. Note: makes LLM API calls and creates local database records."
    option :verbose, type: :boolean, default: false, desc: "Enable verbose logging"
    def run_pipeline(description)
      if description == "--help" || description == "-h"
        invoke :help, ["run"]
        return
      end
      if description.strip.empty?
        say_error "Description cannot be empty", :red
        raise SystemExit.new(1)
      end
      with_error_handling do
        setup_standalone!
        load_config!(options)
        require "arnold_pipeline/orchestrator"

        if options[:preview]
          logger = build_logger(options[:verbose])
          orchestrator = Orchestrator.new(logger:)

          result = orchestrator.call(nl_input: description, stop_after: :tasks)

          say "DRY RUN — spec and tasks generated locally (not published to execution provider)", :yellow
          say "  Execution provider: #{ArnoldPipeline.configuration.execution_provider}"
          case ArnoldPipeline.configuration.execution_provider
          when :github
            say "  Repository: #{ArnoldPipeline.configuration.github_repo || '(not configured)'}"
          when :claude_code
            say "  Repo path: #{ArnoldPipeline.configuration.claude_code_repo_path || '(not configured)'}"
          end
          say "  Description: \"#{description}\""
          say "  Tasks to create: #{result.tasks.count}"

          result.tasks.group_by(&:tier).sort.each do |tier, tasks|
            say "    Tier #{tier}: #{tasks.count} #{tasks.count == 1 ? 'task' : 'tasks'}"
          end

          say "\nRun without --preview to execute."
          return
        end

        stop_after = validate_stop_after(options[:stop_after])
        logger = build_logger(options[:verbose])
        ArnoldPipeline.configuration.verbose_event_logging = true if options[:verbose]
        orchestrator = Orchestrator.new(logger:)

        quiet_say "Starting pipeline for: #{description}", :green
        result = orchestrator.call(nl_input: description, stop_after:)

        quiet_say "\nPipeline #{result.status}!", status_color(result.status)
        quiet_say "  Run ID: #{result.id}"
        quiet_say "  Tasks: #{result.tasks.count}"
        quiet_say "  Iterations: #{result.iterations.count}"

        if result.iterations.any?
          last = result.iterations.order(:number).last
          quiet_say "  Final decision: #{last.decision} (confidence: #{last.confidence}%)"
        end
      end
    end
    map "run" => :run_pipeline
    map "--version" => :version, "-v" => :version

    desc "resume ID", "Resume a paused or failed pipeline run"
    option :config, type: :string, desc: "Path to YAML config file"
    option :provider, type: :string, desc: "LLM provider (anthropic or openai)"
    option :model, type: :string, desc: "LLM model name"
    option :repo, type: :string, desc: "GitHub repo (owner/repo)"
    option :issue_mention, type: :string, desc: "Mention to include in issue body (e.g. @claude)"
    option :polling_interval, type: :numeric, desc: "Polling interval in seconds (default: 30)"
    option :polling_timeout, type: :numeric, desc: "Polling timeout in seconds (default: 1800)"
    option :execution_provider, type: :string, desc: "Execution provider (github, claude_code, null)"
    option :claude_code_repo_path, type: :string, desc: "Path to repo for Claude Code provider"
    option :claude_code_model, type: :string, desc: "Claude Code model (default: sonnet)"
    option :claude_code_max_turns, type: :numeric, desc: "Max turns for Claude Code execution"
    option :claude_code_permission_mode, type: :string, desc: "Claude Code permission mode (default: bypassPermissions)"
    option :stop_after, type: :string, desc: "Stop after stage: spec, tasks, executed"
    option :verbose, type: :boolean, default: false, desc: "Enable verbose logging"
    def resume(id)
      if id == "--help" || id == "-h"
        invoke :help, ["resume"]
        return
      end
      with_error_handling do
        setup_standalone!
        load_config!(options)
        require "arnold_pipeline/orchestrator"

        run_record = PipelineRun.find_by(id:)
        unless run_record
          say_error "Pipeline run ##{id} not found", :red
          raise SystemExit.new(1)
        end

        unless run_record.paused? || run_record.failed?
          say_error "Pipeline run ##{id} is #{run_record.status} and cannot be resumed", :red
          raise SystemExit.new(1)
        end

        stop_after = validate_stop_after(options[:stop_after])
        logger = build_logger(options[:verbose])
        ArnoldPipeline.configuration.verbose_event_logging = true if options[:verbose]
        orchestrator = Orchestrator.new(logger:)

        quiet_say "Resuming pipeline run ##{id}...", :green
        result = orchestrator.resume(pipeline_run: run_record, stop_after:)

        quiet_say "\nPipeline #{result.status}!", status_color(result.status)
        quiet_say "  Run ID: #{result.id}"
        quiet_say "  Tasks: #{result.tasks.count}"
      end
    end

    desc "iterate ID CHANGE_REQUEST", "Iterate on a pipeline run's specification with a natural language change"
    option :config, type: :string, desc: "Path to YAML config file"
    option :provider, type: :string, desc: "LLM provider (anthropic or openai)"
    option :model, type: :string, desc: "LLM model name"
    option :dry_run, type: :boolean, default: false, desc: "Show proposed deltas without applying"
    option :json, type: :boolean, default: false, desc: "Output delta details as JSON"
    option :verbose, type: :boolean, default: false, desc: "Show full before/after for modified requirements"
    option :yes, type: :boolean, default: false, aliases: ["-y"], desc: "Skip confirmation prompt"
    def iterate(id, change_request)
      if id == "--help" || id == "-h"
        invoke :help, ["iterate"]
        return
      end
      with_error_handling do
        setup_standalone!
        load_config!(options)
        require "arnold_pipeline/orchestrator"
        require "arnold_pipeline/delta_presenter"

        run_record = PipelineRun.find_by(id:)
        unless run_record
          say_error "Pipeline run ##{id} not found", :red
          raise SystemExit.new(1)
        end

        if change_request.strip.empty?
          say_error "Change request cannot be empty", :red
          raise SystemExit.new(1)
        end

        logger = build_logger(options[:verbose])
        ArnoldPipeline.configuration.verbose_event_logging = true if options[:verbose]
        orchestrator = Orchestrator.new(logger:)

        if run_record.completed?
          handle_iterate_fork!(orchestrator, run_record, change_request)
          return
        end

        if options[:dry_run]
          handle_iterate_dry_run!(orchestrator, run_record, change_request)
          return
        end

        quiet_say "Iterating specification for pipeline run ##{id}...", :green
        result = orchestrator.iterate_spec!(pipeline_run: run_record, change_request:)

        quiet_say "\nSpecification updated to v#{result[:spec_version]}", :green
        quiet_say "  Deltas applied: #{result[:deltas][:delta_count]}"
        quiet_say "  Merge strategy: #{result[:deltas][:merge_strategy]}"

        superseded_count = run_record.tasks.where(status: :superseded).count
        if superseded_count > 0
          quiet_say "  Tasks superseded: #{superseded_count}"
        end

        quiet_say "\nRun 'arnold resume #{id}' to continue the pipeline with the updated spec.", :yellow
      end
    end

    desc "status ID", "Show the status of a pipeline run"
    option :json, type: :boolean, default: false, desc: "Output as JSON"
    def status(id)
      setup_standalone!

      run_record = PipelineRun.find_by(id:)
      unless run_record
        say_error "Pipeline run ##{id} not found", :red
        raise SystemExit.new(1)
      end

      if options[:json]
        data = {
          id: run_record.id,
          status: run_record.status,
          input: run_record.nl_input,
          task_count: run_record.tasks.count,
          iteration_count: run_record.iterations.count,
          created_at: run_record.created_at.iso8601,
          spec_version: run_record.specification&.version,
          iterations: run_record.iterations.order(:number).map { |iter|
            { number: iter.number, decision: iter.decision, confidence: iter.confidence, needs_human_review: iter.needs_human_review }
          }
        }
        say JSON.pretty_generate(data)
        return
      end

      say "Pipeline Run ##{run_record.id}", :green
      say "  Status: #{run_record.status}"
      say "  Input: #{run_record.nl_input.truncate(80)}"
      say "  Tasks: #{run_record.tasks.count}"
      say "  Iterations: #{run_record.iterations.count}"
      say "  Created: #{run_record.created_at}"

      if run_record.specification
        say "\n  Spec version: #{run_record.specification.version}"
      end

      run_record.iterations.order(:number).each do |iter|
        review = iter.needs_human_review ? " [NEEDS REVIEW]" : ""
        say "  Iteration #{iter.number}: #{iter.decision} (#{iter.confidence}%)#{review}"
      end
    end

    desc "list", "List all pipeline runs"
    option :limit, type: :numeric, default: 20, desc: "Number of runs to show"
    option :json, type: :boolean, default: false, desc: "Output as JSON"
    def list
      setup_standalone!

      runs = PipelineRun.order(created_at: :desc).limit(options[:limit])

      if options[:json]
        data = runs.map { |run_record|
          {
            id: run_record.id,
            status: run_record.status,
            description: run_record.nl_input,
            created_at: run_record.created_at.iso8601
          }
        }
        say JSON.pretty_generate(data)
        return
      end

      if runs.empty?
        say "No pipeline runs found", :yellow
        return
      end

      say "Pipeline Runs:", :green
      runs.each do |run_record|
        say "  ##{run_record.id} [#{run_record.status}] #{run_record.nl_input.truncate(60)} (#{run_record.created_at.strftime('%Y-%m-%d %H:%M')})"
      end
    end

    desc "spec ID", "Export the specification for a pipeline run"
    option :output, type: :string, aliases: "-o", desc: "Write to file instead of stdout"
    option :json, type: :boolean, default: false, desc: "Output structured JSON data instead of markdown"
    option :history, type: :boolean, default: false, desc: "Show revision history with delta summaries"
    option :version, type: :numeric, desc: "Show spec content at a specific version"
    def spec(id)
      setup_standalone!

      run_record = PipelineRun.find_by(id:)
      unless run_record
        say_error "Pipeline run ##{id} not found", :red
        raise SystemExit.new(1)
      end

      spec = run_record.specification
      unless spec
        say_error "No specification found for pipeline run ##{id}", :yellow
        raise SystemExit.new(1)
      end

      if options[:history]
        show_spec_lineage(run_record)
        return
      end

      if options[:version]
        show_spec_version(spec, options[:version])
        return
      end

      content = if options[:json]
        JSON.pretty_generate(spec.structured_data || {})
      else
        spec.content
      end

      if options[:output]
        File.write(options[:output], content)
        $stderr.puts "Specification (v#{spec.version}) written to #{options[:output]}"
      else
        say content
      end
    end

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

    desc "tasks ID", "Export the tasks for a pipeline run"
    option :output, type: :string, aliases: "-o", desc: "Write to file instead of stdout"
    option :json, type: :boolean, default: false, desc: "Output as JSON"
    def tasks(id)
      setup_standalone!

      run_record = PipelineRun.find_by(id:)
      unless run_record
        say_error "Pipeline run ##{id} not found", :red
        raise SystemExit.new(1)
      end

      task_records = run_record.tasks.ordered
      if task_records.empty?
        say_error "No tasks found for pipeline run ##{id}", :yellow
        raise SystemExit.new(1)
      end

      content = if options[:json]
        JSON.pretty_generate(task_records.map { |t| task_to_hash(t) })
      else
        task_records.map { |t| format_task(t) }.join("\n\n")
      end

      if options[:output]
        File.write(options[:output], content)
        $stderr.puts "#{task_records.size} tasks written to #{options[:output]}"
      else
        say content
      end
    end

    desc "version", "Show the version"
    def version
      say "arnold_pipeline #{ArnoldPipeline::VERSION}"
    end

    private

    def setup_standalone!
      return if defined?(Rails) && Rails.application

      require "active_record"

      FileUtils.mkdir_p(STANDALONE_DB_DIR)

      ActiveRecord::Base.establish_connection(
        adapter: "sqlite3",
        database: STANDALONE_DB_PATH
      )

      run_migrations!
      load_models!
    end

    def run_migrations!
      migration_path = File.expand_path("../../db/migrate", __dir__)
      if Dir.exist?(migration_path)
        ActiveRecord::MigrationContext.new(migration_path).migrate
      end
    end

    def load_models!
      require "arnold_pipeline"
      models_path = File.expand_path("../../app/models/arnold_pipeline", __dir__)
      Dir.glob(File.join(models_path, "*.rb")).sort.each { |f| require f }
    end

    def load_config!(options)
      if options[:config]
        yaml_config = YAML.safe_load_file(options[:config], symbolize_names: true)
        apply_config!(yaml_config)
      end

      ArnoldPipeline.configure do |c|
        c.llm_provider = options[:provider].to_sym if options[:provider]
        c.llm_model = options[:model] if options[:model]
        c.github_repo = options[:repo] if options[:repo]
        c.github_issue_mention = options[:issue_mention] if options[:issue_mention]
        c.polling_interval = options[:polling_interval] if options[:polling_interval]
        c.polling_timeout = options[:polling_timeout] if options[:polling_timeout]
        c.execution_provider = options[:execution_provider].to_sym if options[:execution_provider]
        c.claude_code_repo_path = options[:claude_code_repo_path] if options[:claude_code_repo_path]
        c.claude_code_model = options[:claude_code_model] if options[:claude_code_model]
        c.claude_code_max_turns = options[:claude_code_max_turns] if options[:claude_code_max_turns]
        c.claude_code_permission_mode = options[:claude_code_permission_mode] if options[:claude_code_permission_mode]
      end
    end

    def apply_config!(yaml_config)
      ArnoldPipeline.configure do |c|
        c.llm_provider = yaml_config[:llm_provider]&.to_sym if yaml_config[:llm_provider]
        c.llm_api_key = yaml_config[:llm_api_key] if yaml_config[:llm_api_key]
        c.llm_model = yaml_config[:llm_model] if yaml_config[:llm_model]
        c.execution_provider = yaml_config[:execution_provider]&.to_sym if yaml_config[:execution_provider]
        c.github_token = yaml_config[:github_token] if yaml_config[:github_token]
        c.github_repo = yaml_config[:github_repo] if yaml_config[:github_repo]
        c.github_issue_mention = yaml_config[:github_issue_mention] if yaml_config[:github_issue_mention]
        c.max_iterations = yaml_config[:max_iterations] if yaml_config[:max_iterations]
        c.library_path = yaml_config[:library_path] if yaml_config[:library_path]
        c.polling_interval = yaml_config[:polling_interval] if yaml_config[:polling_interval]
        c.polling_timeout = yaml_config[:polling_timeout] if yaml_config[:polling_timeout]
        c.polling_max_interval = yaml_config[:polling_max_interval] if yaml_config[:polling_max_interval]
        c.tier_gate_enabled = yaml_config[:tier_gate_enabled] unless yaml_config[:tier_gate_enabled].nil?
        c.context_propagation_enabled = yaml_config[:context_propagation_enabled] unless yaml_config[:context_propagation_enabled].nil?
        c.max_tier_retries = yaml_config[:max_tier_retries] if yaml_config[:max_tier_retries]
        c.workflow_status_enabled = yaml_config[:workflow_status_enabled] unless yaml_config[:workflow_status_enabled].nil?
        c.claude_code_repo_path = yaml_config[:claude_code_repo_path] if yaml_config[:claude_code_repo_path]
        c.claude_code_model = yaml_config[:claude_code_model] if yaml_config[:claude_code_model]
        c.claude_code_max_turns = yaml_config[:claude_code_max_turns] if yaml_config[:claude_code_max_turns]
        c.claude_code_permission_mode = yaml_config[:claude_code_permission_mode] if yaml_config[:claude_code_permission_mode]
        c.openspec_enabled = yaml_config[:openspec_enabled] unless yaml_config[:openspec_enabled].nil?
        c.openspec_cli_path = yaml_config[:openspec_cli_path] if yaml_config[:openspec_cli_path]
        c.claude_code_max_concurrency = yaml_config[:claude_code_max_concurrency] if yaml_config[:claude_code_max_concurrency]
        c.post_merge_hooks = yaml_config[:post_merge_hooks]&.map { |h| h.transform_keys(&:to_s) } || [] if yaml_config.key?(:post_merge_hooks)
        c.verification_checks = yaml_config[:verification_checks]&.map { |h| h.transform_keys(&:to_s) } || [] if yaml_config.key?(:verification_checks)
        c.spec_test_generation_enabled = yaml_config[:spec_test_generation_enabled] unless yaml_config[:spec_test_generation_enabled].nil?
        c.spec_test_directory = yaml_config[:spec_test_directory] if yaml_config[:spec_test_directory]
        c.spec_test_persona = yaml_config[:spec_test_persona] if yaml_config[:spec_test_persona]
        c.event_logging_enabled = yaml_config[:event_logging_enabled] unless yaml_config[:event_logging_enabled].nil?
        c.verbose_event_logging = yaml_config[:verbose_event_logging] unless yaml_config[:verbose_event_logging].nil?
        if yaml_config[:workflow_branch_pattern]
          begin
            c.workflow_branch_pattern = Regexp.new(yaml_config[:workflow_branch_pattern])
          rescue RegexpError => e
            raise ArnoldPipeline::ConfigurationError, "Invalid workflow_branch_pattern: #{e.message}"
          end
        end
      end
    end

    def build_logger(verbose)
      Logger.new($stdout, level: verbose ? Logger::DEBUG : Logger::INFO)
    end

    VALID_STOP_AFTER = %w[spec tasks executed].freeze

    def validate_stop_after(value)
      return nil if value.nil?

      unless VALID_STOP_AFTER.include?(value)
        say_error "Invalid --stop-after value '#{value}'. Must be one of: #{VALID_STOP_AFTER.join(', ')}", :red
        raise SystemExit.new(1)
      end

      value.to_sym
    end

    def with_error_handling
      yield
    rescue ArnoldPipeline::ConfigurationError => e
      say_error "Configuration error: #{e.message}", :red
      raise SystemExit.new(1)
    rescue Errno::ENOENT => e
      say_error "File not found: #{e.message.sub(/ @ rb_sysopen/, '')}", :red
      raise SystemExit.new(1)
    rescue Psych::SyntaxError => e
      say_error "Invalid YAML in config file: #{e.message}", :red
      raise SystemExit.new(1)
    rescue StandardError => e
      say_error "Error: #{e.message}", :red
      if options[:verbose]
        say_error e.backtrace&.first(10)&.join("\n"), :red
      end
      raise SystemExit.new(1)
    end

    def quiet_say(message, *args)
      say(message, *args) unless options[:quiet]
    end

    def handle_iterate_dry_run!(orchestrator, run_record, change_request)
      result = orchestrator.iterate_spec_dry_run!(pipeline_run: run_record, change_request:)

      presenter = DeltaPresenter.new(
        result[:deltas],
        from_version: result[:current_version],
        to_version: result[:current_version] + 1
      )

      if options[:json]
        say JSON.pretty_generate(presenter.to_json_data)
      else
        say presenter.to_s
        say "\nNo changes applied (dry run).", :yellow
      end
    end

    def handle_iterate_fork!(orchestrator, run_record, change_request)
      quiet_say "Pipeline run ##{run_record.id} is completed. Forking into new run...", :green
      result = orchestrator.fork!(pipeline_run: run_record, change_request:)
      new_run = result[:pipeline_run]

      quiet_say "\nNew pipeline run created!", :green
      quiet_say "  New run ID: #{new_run.id}"
      quiet_say "  Forked from: ##{run_record.id}"
      quiet_say "  Spec version: #{new_run.specification.version}"
      quiet_say "\nRun 'arnold resume #{new_run.id}' to continue.", :yellow
    end

    def task_to_hash(task)
      {
        id: task.id,
        title: task.title,
        description: task.description,
        position: task.position,
        tier: task.tier,
        priority: task.priority,
        status: task.status,
        labels: task.labels,
        depends_on: task.depends_on,
        external_id: task.external_id,
        external_url: task.external_url
      }
    end

    def format_task(task)
      lines = []
      label = task.superseded? ? " [superseded]" : ""
      lines << "## [#{task.position}] #{task.title}#{label}"
      lines << "Tier: #{task.tier} | Priority: #{task.priority} | Status: #{task.status}"
      lines << "Labels: #{task.labels.join(', ')}" if task.labels.any?
      lines << "Depends on: #{task.depends_on.join(', ')}" if task.depends_on.any?
      lines << "Link: #{task.external_url}" if task.external_url
      lines << ""
      lines << task.description if task.description.present?
      lines.join("\n")
    end

    def show_spec_lineage(pipeline_run)
      root = find_root_run(pipeline_run)
      tree = build_lineage_tree(root)
      say "Spec Lineage for Run ##{pipeline_run.id}:\n", :green
      render_lineage_tree(tree, pipeline_run.id)
    end

    def find_root_run(run)
      current = run
      while (parent_id = current.metadata&.dig("forked_from_run_id"))
        parent = PipelineRun.find_by(id: parent_id)
        break unless parent
        current = parent
      end
      current
    end

    def build_lineage_tree(root)
      children = PipelineRun.where("json_extract(metadata, '$.forked_from_run_id') = ?", root.id)
                            .order(:created_at)
                            .map { |child| build_lineage_tree(child) }
      { run: root, children: children }
    end

    def render_lineage_tree(node, current_run_id, prefix: "", is_last: true, is_root: true)
      run = node[:run]
      spec = run.specification

      # Build the connector prefix
      if is_root
        line_prefix = ""
        child_prefix = ""
      else
        connector = is_last ? "└── " : "├── "
        line_prefix = prefix + connector
        child_prefix = prefix + (is_last ? "    " : "│   ")
      end

      # Build the main node line
      current_marker = run.id == current_run_id ? "  ◄ current" : ""
      version_str = spec ? "v#{spec.version}" : ""
      timestamp = run.created_at.strftime("%Y-%m-%d %H:%M")
      header = format(
        "%s#%-4d [%s] %-6s%s  %s",
        line_prefix, run.id, run.status, version_str, current_marker, timestamp
      )
      say header, lineage_status_color(run, current_run_id)

      # Show change source for root (spec_generation) or change request for forks
      change_request = run.metadata&.dig("fork_change_request")
      if change_request
        truncated = change_request.length > 70 ? "#{change_request[0...70]}..." : change_request
        say "#{child_prefix}\"#{truncated}\""
      elsif is_root
        say "#{child_prefix}spec_generation"
      end

      # Show delta summaries from the fork's spec revision (user_iterate)
      if change_request && spec
        user_rev = spec.spec_revisions.where(change_source: "user_iterate").order(:version).last
        if user_rev&.delta_summary.present?
          user_rev.delta_summary.each { |s| say "#{child_prefix}  - #{s}" }
        end
      end

      # Render children
      node[:children].each_with_index do |child, i|
        is_last_child = (i == node[:children].length - 1)
        # Add a blank connector line before children if this node has content
        say "#{child_prefix}│" if i == 0
        render_lineage_tree(child, current_run_id, prefix: child_prefix, is_last: is_last_child, is_root: false)
      end
    end

    def lineage_status_color(run, current_run_id)
      return :cyan if run.id == current_run_id
      case run.status
      when "completed" then :green
      when "failed" then :red
      when "paused", "executing", "awaiting_results" then :yellow
      else :white
      end
    end

    def show_spec_history(spec)
      revisions = spec.spec_revisions.ordered
      if revisions.empty?
        say "No revision history available for this specification", :yellow
        say "  Current version: #{spec.version}"
        return
      end

      say "Specification Revision History:", :green
      revisions.each do |rev|
        say "  v#{rev.version} [#{rev.change_source || 'unknown'}] #{rev.created_at.strftime('%Y-%m-%d %H:%M')}"
        if rev.delta_summary.present?
          rev.delta_summary.each { |s| say "    - #{s}" }
        end
      end
    end

    def show_spec_version(spec, version_number)
      revision = spec.spec_revisions.find_by(version: version_number)
      unless revision
        say_error "Version #{version_number} not found. Current version: #{spec.version}", :red
        raise SystemExit.new(1)
      end

      if options[:output]
        File.write(options[:output], revision.content)
        $stderr.puts "Specification v#{version_number} written to #{options[:output]}"
      else
        say revision.content
      end
    end

    def event_to_hash(event, include_payload: false)
      hash = {
        pipeline_run_id: event.pipeline_run_id,
        event_type: event.event_type,
        stage: event.stage,
        summary: event.summary,
        duration_ms: event.duration_ms,
        iteration_number: event.iteration_number,
        tier_number: event.tier_number,
        created_at: event.created_at.iso8601
      }
      hash[:payload] = event.payload if include_payload && event.payload.present?
      hash
    end

    def status_color(status)
      case status
      when "completed" then :green
      when "failed" then :red
      when "max_iterations_reached" then :yellow
      else :white
      end
    end
  end
end
