require "thor"
require "yaml"
require "json"
require "logger"
require "fileutils"

module ArnoldPipeline
  class Cli < Thor
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
    option :stop_after, type: :string, desc: "Stop after stage: spec, tasks, executed"
    option :dry_run, type: :boolean, default: false, desc: "Generate spec and tasks without publishing to GitHub (still makes LLM API calls)"
    option :verbose, type: :boolean, default: false, desc: "Enable verbose logging"
    def run_pipeline(description)
      if description == "--help" || description == "-h"
        invoke :help, ["run"]
        return
      end
      with_error_handling do
        setup_standalone!
        load_config!(options)
        require "arnold_pipeline/orchestrator"

        if options[:dry_run]
          logger = build_logger(options[:verbose])
          orchestrator = Orchestrator.new(logger:)

          result = orchestrator.call(nl_input: description, stop_after: :tasks)

          say "DRY RUN — spec and tasks generated locally (no GitHub issues will be created)", :yellow
          say "  Repository: #{ArnoldPipeline.configuration.github_repo || '(not configured)'}"
          say "  Description: \"#{description}\""
          say "  Tasks to create: #{result.tasks.count}"

          result.tasks.group_by(&:tier).sort.each do |tier, tasks|
            say "    Tier #{tier}: #{tasks.count} #{tasks.count == 1 ? 'task' : 'tasks'}"
          end

          say "\nRun without --dry-run to execute."
          return
        end

        stop_after = validate_stop_after(options[:stop_after])
        logger = build_logger(options[:verbose])
        orchestrator = Orchestrator.new(logger:)

        say "Starting pipeline for: #{description}", :green
        result = orchestrator.call(nl_input: description, stop_after:)

        say "\nPipeline #{result.status}!", status_color(result.status)
        say "  Run ID: #{result.id}"
        say "  Tasks: #{result.tasks.count}"
        say "  Iterations: #{result.iterations.count}"

        if result.iterations.any?
          last = result.iterations.order(:number).last
          say "  Final decision: #{last.decision} (confidence: #{last.confidence}%)"
        end
      end
    end
    map "run" => :run_pipeline
    map "--version" => :version, "-v" => :version

    desc "resume ID", "Resume a paused or failed pipeline run"
    option :config, type: :string, desc: "Path to YAML config file"
    option :stop_after, type: :string, desc: "Stop after stage: spec, tasks, executed"
    option :verbose, type: :boolean, default: false, desc: "Enable verbose logging"
    def resume(id)
      if id == "--help" || id == "-h"
        invoke :help, ["resume"]
        return
      end
      with_error_handling do
        setup_standalone!
        load_config!(options) if options[:config]
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
        orchestrator = Orchestrator.new(logger:)

        say "Resuming pipeline run ##{id}...", :green
        result = orchestrator.resume(pipeline_run: run_record, stop_after:)

        say "\nPipeline #{result.status}!", status_color(result.status)
        say "  Run ID: #{result.id}"
        say "  Tasks: #{result.tasks.count}"
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

      content = if options[:json]
        JSON.pretty_generate(spec.structured_data || {})
      else
        spec.content
      end

      if options[:output]
        File.write(options[:output], content)
        say "Specification (v#{spec.version}) written to #{options[:output]}", :green
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
        c.workflow_branch_pattern = Regexp.new(yaml_config[:workflow_branch_pattern]) if yaml_config[:workflow_branch_pattern]
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
