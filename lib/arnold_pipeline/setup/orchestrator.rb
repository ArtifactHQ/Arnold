require_relative "request"
require_relative "result"
require "yaml"
require "fileutils"
require "open3"

module ArnoldPipeline
  module Setup
    class Orchestrator
      ARNOLD_HOME = File.expand_path("~/.arnold_pipeline")
      CONFIG_PATH = File.join(ARNOLD_HOME, "config.yml")
      MIN_DESCRIPTION_LENGTH = 10
      GITHUB_REPO_PATTERN = /\A[\w.-]+\/[\w.-]+\z/

      def initialize(logger: nil)
        @logger = logger || Logger.new(File::NULL)
      end

      def call(request)
        missing = resolve_missing_fields(request)
        return Result.needs_input(missing) if missing.any?

        errors = validate(request)
        return Result.error(errors) if errors.any?

        project_path = File.expand_path(request.project_path)
        init_project!(project_path)

        config_path = write_config!(request)
        configure_arnold!(request)

        pipeline_run = run_preview!(request)
        spec_summary = extract_spec_summary(pipeline_run)
        task_summary = extract_task_summary(pipeline_run)

        Result.complete(
          project_path:,
          config_path:,
          spec_summary:,
          task_summary:,
          run_id: pipeline_run.id
        )
      rescue => e
        @logger.error { "[Setup] #{e.message}" }
        Result.error("Setup failed: #{e.message}")
      end

      private

      def resolve_missing_fields(request)
        missing = []
        missing << :project_path if request.project_path.nil? || request.project_path.strip.empty?
        missing << :description if request.description.nil? || request.description.strip.empty?

        if resolved_api_key(request).nil?
          missing << :llm_api_key
        end

        if request.execution_provider == "github"
          missing << :github_token if request.github_token.nil? || request.github_token.strip.empty?
          missing << :github_repo if request.github_repo.nil? || request.github_repo.strip.empty?
        end

        missing
      end

      def resolved_api_key(request)
        return request.llm_api_key if request.llm_api_key && !request.llm_api_key.strip.empty?

        # Check existing config
        if File.exist?(CONFIG_PATH)
          config = YAML.safe_load_file(CONFIG_PATH) || {}
          key = config["llm_api_key"]
          return key if key && !key.strip.empty?
        end

        # Check env vars
        provider = request.llm_provider || "anthropic"
        env_key = ArnoldPipeline::Configuration::PROVIDER_DEFAULTS.dig(provider.to_sym, :env_key)
        env_val = ENV[env_key.to_s] if env_key
        return env_val if env_val && !env_val.empty?

        nil
      end

      def validate(request)
        errors = []

        if request.description.strip.length < MIN_DESCRIPTION_LENGTH
          errors << "Description must be at least #{MIN_DESCRIPTION_LENGTH} characters"
        end

        project_path = File.expand_path(request.project_path)
        parent = File.dirname(project_path)
        unless File.directory?(parent)
          errors << "Parent directory does not exist: #{parent}"
        end

        if request.execution_provider == "github" && request.github_repo
          unless request.github_repo.match?(GITHUB_REPO_PATTERN)
            errors << "Invalid GitHub repo format: '#{request.github_repo}'. Expected 'owner/repo'"
          end
        end

        if request.llm_provider && !Request::VALID_LLM_PROVIDERS.include?(request.llm_provider)
          errors << "Invalid LLM provider: #{request.llm_provider}"
        end

        if request.execution_provider && !Request::VALID_EXECUTION_PROVIDERS.include?(request.execution_provider)
          errors << "Invalid execution provider: #{request.execution_provider}"
        end

        errors
      end

      def init_project!(project_path)
        FileUtils.mkdir_p(project_path)

        unless File.directory?(File.join(project_path, ".git"))
          _out, _err, status = Open3.capture3("git", "init", project_path)
          @logger.info { "[Setup] Initialized git repository at #{project_path}" } if status.success?
        end
      end

      def write_config!(request)
        FileUtils.mkdir_p(ARNOLD_HOME)

        existing = if File.exist?(CONFIG_PATH)
          YAML.safe_load_file(CONFIG_PATH) || {}
        else
          {}
        end

        new_config = build_config_hash(request)

        # Existing values win (don't overwrite user's previous config)
        merged = new_config.merge(existing)

        # config_overrides always win
        merged.merge!(request.config_overrides.transform_keys(&:to_s)) if request.config_overrides.any?

        File.write(CONFIG_PATH, YAML.dump(merged))
        CONFIG_PATH
      end

      def build_config_hash(request)
        config = {}
        config["llm_provider"] = request.llm_provider if request.llm_provider
        config["execution_provider"] = request.execution_provider if request.execution_provider

        api_key = resolved_api_key(request)
        config["llm_api_key"] = api_key if api_key && request.llm_api_key

        if request.execution_provider == "github"
          config["github_token"] = request.github_token if request.github_token
          config["github_repo"] = request.github_repo if request.github_repo
        end

        project_path = File.expand_path(request.project_path)
        if request.execution_provider == "claude_code"
          config["claude_code_repo_path"] = project_path
        end

        config["target_repo_path"] = project_path
        config
      end

      def configure_arnold!(request)
        api_key = resolved_api_key(request)
        provider = (request.llm_provider || "anthropic").to_sym

        ArnoldPipeline.configure do |c|
          c.llm_provider = provider
          c.llm_api_key = api_key
          c.execution_provider = :null
        end
      end

      def run_preview!(request)
        require "arnold_pipeline/orchestrator"

        orchestrator = ArnoldPipeline::Orchestrator.new(logger: @logger)
        orchestrator.call(nl_input: request.description, stop_after: :tasks)
      end

      def extract_spec_summary(pipeline_run)
        spec = pipeline_run.specification
        return nil unless spec

        {
          version: spec.version,
          content_length: spec.content&.length,
          product_name: extract_product_name(spec),
          has_structured_data: spec.structured_data.present?
        }
      end

      def extract_product_name(spec)
        data = spec.structured_data || {}
        name = data["product_name"] || data["name"] || data["title"]
        return name.to_s if name.present?

        heading = spec.content.to_s.lines.find { |l| l.match?(/^#\s/) }
        heading&.sub(/^#+\s*/, "")&.strip
      end

      def extract_task_summary(pipeline_run)
        tasks = pipeline_run.tasks
        return nil if tasks.empty?

        tasks_by_tier = tasks.group_by(&:tier)
        {
          total: tasks.count,
          tiers: tasks_by_tier.keys.size,
          breakdown: tasks_by_tier.sort.map { |tier, tier_tasks|
            { tier:, count: tier_tasks.size, titles: tier_tasks.map(&:title) }
          }
        }
      end
    end
  end
end
