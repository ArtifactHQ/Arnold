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
                  :claude_code_max_concurrency,
                  :max_iterations, :library_path,
                  :polling_interval, :polling_timeout, :polling_max_interval,
                  :tier_gate_enabled, :context_propagation_enabled, :max_tier_retries,
                  :workflow_status_enabled, :workflow_branch_pattern,
                  :openspec_enabled, :openspec_cli_path,
                  :max_diff_chars, :max_diff_per_file_chars,
                  :merge_conflict_resolution_enabled, :merge_conflict_max_files,
                  :event_logging_enabled, :verbose_event_logging,
                  :llm_request_timeout,
                  :repo_context_scan_patterns, :repo_context_scan_files,
                  :verification_enabled, :verification_timeout,
                  :verification_health_check_retries, :verification_health_check_interval,
                  :test_execution_enabled, :test_command, :test_timeout,
                  :test_boot_command, :test_boot_timeout,
                  :spec_test_generation_enabled, :spec_test_directory, :spec_test_persona
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
      @claude_code_max_concurrency = 4
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
      @llm_request_timeout               = 600
      @repo_context_scan_patterns        = nil
      @repo_context_scan_files           = nil
      @verification_enabled                    = false
      @verification_timeout                    = 120
      @verification_health_check_retries       = 10
      @verification_health_check_interval      = 3
      @test_execution_enabled                  = false
      @test_command                            = nil
      @test_timeout                            = 120
      @test_boot_command                       = nil
      @test_boot_timeout                       = 60
      @spec_test_generation_enabled             = false
      @spec_test_directory                       = "test/spec_integration"
      @spec_test_persona                         = "testing_specialist"
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
      validate_verification_config!
      validate_test_execution_config!
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

    def validate_verification_config!
      unless @verification_timeout.is_a?(Integer) && @verification_timeout > 0
        raise ConfigurationError, "verification_timeout must be a positive integer."
      end

      unless @verification_health_check_retries.is_a?(Integer) && @verification_health_check_retries > 0
        raise ConfigurationError, "verification_health_check_retries must be a positive integer."
      end

      unless @verification_health_check_interval.is_a?(Integer) && @verification_health_check_interval > 0
        raise ConfigurationError, "verification_health_check_interval must be a positive integer."
      end
    end

    def validate_test_execution_config!
      unless @test_timeout.is_a?(Integer) && @test_timeout > 0
        raise ConfigurationError, "test_timeout must be a positive integer."
      end

      unless @test_boot_timeout.is_a?(Integer) && @test_boot_timeout > 0
        raise ConfigurationError, "test_boot_timeout must be a positive integer."
      end
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
