require "arnold_pipeline/providers/execution/base"

module ArnoldPipeline
  class Configuration
    VALID_LLM_PROVIDERS = %i[anthropic openai].freeze
    VALID_EXECUTION_PROVIDERS = %i[github].freeze

    PROVIDER_DEFAULTS = {
      anthropic: { env_key: "ANTHROPIC_API_KEY", model: "claude-sonnet-4-20250514" },
      openai:    { env_key: "OPENAI_API_KEY",    model: "gpt-4o" }
    }.freeze

    attr_accessor :execution_provider, :github_token, :github_repo,
                  :github_issue_mention,
                  :claude_code_repo_path, :claude_code_model,
                  :claude_code_max_turns, :claude_code_permission_mode,
                  :max_iterations, :library_path,
                  :polling_interval, :polling_timeout, :polling_max_interval,
                  :tier_gate_enabled, :context_propagation_enabled, :max_tier_retries,
                  :workflow_status_enabled, :workflow_branch_pattern,
                  :openspec_enabled, :openspec_cli_path,
                  :max_diff_chars, :max_diff_per_file_chars,
                  :merge_conflict_resolution_enabled, :merge_conflict_max_files,
                  :event_logging_enabled, :verbose_event_logging
    attr_writer   :llm_provider, :llm_api_key, :llm_model

    def initialize
      @llm_provider       = nil
      @llm_api_key        = nil
      @llm_model          = nil
      @execution_provider = :github
      @github_token       = ENV["GITHUB_TOKEN"]
      @github_repo        = nil
      @github_issue_mention = nil
      @claude_code_repo_path      = nil
      @claude_code_model          = "sonnet"
      @claude_code_max_turns      = nil
      @claude_code_permission_mode = "bypassPermissions"
      @max_iterations     = 3
      @library_path       = nil
      @polling_interval     = 30
      @polling_timeout      = 1800
      @polling_max_interval = 300
      @tier_gate_enabled          = true
      @context_propagation_enabled = true
      @max_tier_retries           = 2
      @workflow_status_enabled     = true
      @workflow_branch_pattern     = /issue[-_]?\d+/i
      @openspec_enabled           = true
      @openspec_cli_path          = "openspec"
      @max_diff_chars             = 100_000
      @max_diff_per_file_chars    = 10_000
      @merge_conflict_resolution_enabled = true
      @merge_conflict_max_files          = 10
      @event_logging_enabled             = true
      @verbose_event_logging             = false
    end

    def llm_provider
      @llm_provider || detect_provider
    end

    def llm_api_key
      @llm_api_key || ENV[PROVIDER_DEFAULTS.dig(llm_provider, :env_key).to_s]
    end

    def llm_model
      @llm_model || PROVIDER_DEFAULTS.dig(llm_provider, :model)
    end

    def validate!(stop_after: nil)
      validate_llm_provider!
      validate_llm_api_key!
      validate_execution_provider!
      validate_execution_config! unless %i[spec tasks].include?(stop_after)
      validate_max_iterations!
      validate_polling_config!
      validate_max_tier_retries!
      validate_workflow_branch_pattern!
      true
    end

    private

    def detect_provider
      if ENV["ANTHROPIC_API_KEY"] && !ENV["ANTHROPIC_API_KEY"].empty?
        :anthropic
      elsif ENV["OPENAI_API_KEY"] && !ENV["OPENAI_API_KEY"].empty?
        :openai
      else
        :anthropic
      end
    end

    def validate_llm_provider!
      return if VALID_LLM_PROVIDERS.include?(llm_provider)

      raise ConfigurationError, "Invalid LLM provider: #{llm_provider}. Must be one of: #{VALID_LLM_PROVIDERS.join(', ')}"
    end

    def validate_llm_api_key!
      key = llm_api_key
      return if key && !key.empty?

      env_var = PROVIDER_DEFAULTS.dig(llm_provider, :env_key) || "ANTHROPIC_API_KEY"
      raise ConfigurationError, "LLM API key is required. Set llm_api_key or #{env_var} environment variable."
    end

    def validate_execution_provider!
      valid = VALID_EXECUTION_PROVIDERS | Providers::Execution.registered_providers
      return if valid.include?(@execution_provider)

      raise ConfigurationError, "Invalid execution provider: #{@execution_provider}. Must be one of: #{valid.join(', ')}"
    end

    def validate_execution_config!
      Providers::Execution.provider_class_for(@execution_provider).validate_configuration!(self)
    end

    def validate_max_iterations!
      return if @max_iterations.is_a?(Integer) && @max_iterations.between?(1, 10)

      raise ConfigurationError, "max_iterations must be an integer between 1 and 10."
    end

    def validate_max_tier_retries!
      return if @max_tier_retries.is_a?(Integer) && @max_tier_retries.between?(0, 5)

      raise ConfigurationError, "max_tier_retries must be an integer between 0 and 5."
    end

    def validate_workflow_branch_pattern!
      return if @workflow_branch_pattern.is_a?(Regexp)

      raise ConfigurationError, "workflow_branch_pattern must be a Regexp"
    end

    def validate_polling_config!
      unless @polling_interval.is_a?(Numeric) && @polling_interval > 0
        raise ConfigurationError, "polling_interval must be a positive number."
      end

      unless @polling_timeout.is_a?(Numeric) && @polling_timeout > 0
        raise ConfigurationError, "polling_timeout must be a positive number."
      end

      unless @polling_max_interval.is_a?(Numeric) && @polling_max_interval > 0
        raise ConfigurationError, "polling_max_interval must be a positive number."
      end
    end
  end
end
