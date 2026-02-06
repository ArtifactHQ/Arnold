require "thor"
require "yaml"
require "json"
require "logger"
require "fileutils"

module ArnoldPipeline
  class Cli < Thor
    STANDALONE_DB_DIR = File.expand_path("~/.arnold_pipeline")
    STANDALONE_DB_PATH = File.join(STANDALONE_DB_DIR, "pipeline.sqlite3")

    desc "run DESCRIPTION", "Run the full pipeline from a natural language description"
    option :config, type: :string, desc: "Path to YAML config file"
    option :provider, type: :string, desc: "LLM provider (anthropic or openai)"
    option :model, type: :string, desc: "LLM model name"
    option :repo, type: :string, desc: "GitHub repo (owner/repo)"
    option :verbose, type: :boolean, default: false, desc: "Enable verbose logging"
    def run_pipeline(description)
      setup_standalone!
      load_config!(options)
      require "arnold_pipeline/orchestrator"

      logger = build_logger(options[:verbose])
      orchestrator = Orchestrator.new(logger:)

      say "Starting pipeline for: #{description}", :green
      result = orchestrator.call(nl_input: description)

      say "\nPipeline #{result.status}!", status_color(result.status)
      say "  Run ID: #{result.id}"
      say "  Tasks: #{result.tasks.count}"
      say "  Iterations: #{result.iterations.count}"

      if result.iterations.any?
        last = result.iterations.order(:number).last
        say "  Final decision: #{last.decision} (confidence: #{last.confidence}%)"
      end
    end
    map "run" => :run_pipeline

    desc "status ID", "Show the status of a pipeline run"
    def status(id)
      setup_standalone!

      run_record = PipelineRun.find_by(id:)
      unless run_record
        say "Pipeline run ##{id} not found", :red
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
    def list
      setup_standalone!

      runs = PipelineRun.order(created_at: :desc).limit(options[:limit])

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
        say "Pipeline run ##{id} not found", :red
        return
      end

      spec = run_record.specification
      unless spec
        say "No specification found for pipeline run ##{id}", :yellow
        return
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
        c.max_iterations = yaml_config[:max_iterations] if yaml_config[:max_iterations]
        c.library_path = yaml_config[:library_path] if yaml_config[:library_path]
      end
    end

    def build_logger(verbose)
      Logger.new($stdout, level: verbose ? Logger::DEBUG : Logger::INFO)
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
