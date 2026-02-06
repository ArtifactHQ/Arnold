module ArnoldPipeline
  class Configuration
    VALID_LLM_PROVIDERS = %i[anthropic openai].freeze
    VALID_EXECUTION_PROVIDERS = %i[github].freeze

    PROVIDER_DEFAULTS = {
      anthropic: { env_key: "ANTHROPIC_API_KEY", model: "claude-sonnet-4-20250514" },
      openai:    { env_key: "OPENAI_API_KEY",    model: "gpt-4o" }
    }.freeze

    attr_accessor :llm_provider,
                  :execution_provider, :github_token, :github_repo,
                  :github_issue_mention,
                  :max_iterations, :library_path,
                  :polling_interval, :polling_timeout, :polling_max_interval,
                  :tier_gate_enabled, :context_propagation_enabled, :max_tier_retries
    attr_writer   :llm_api_key, :llm_model

    def initialize
      @llm_provider       = :anthropic
      @llm_api_key        = nil
      @llm_model          = nil
      @execution_provider = :github
      @github_token       = ENV["GITHUB_TOKEN"]
      @github_repo        = nil
      @github_issue_mention = nil
      @max_iterations     = 3
      @library_path       = nil
      @polling_interval     = 30
      @polling_timeout      = 1800
      @polling_max_interval = 300
      @tier_gate_enabled          = true
      @context_propagation_enabled = true
      @max_tier_retries           = 2
    end

    def llm_api_key
      @llm_api_key || ENV[PROVIDER_DEFAULTS.dig(@llm_provider, :env_key).to_s]
    end

    def llm_model
      @llm_model || PROVIDER_DEFAULTS.dig(@llm_provider, :model)
    end

    def validate!
      validate_llm_provider!
      validate_llm_api_key!
      validate_execution_provider!
      validate_github_config!
      validate_max_iterations!
      validate_polling_config!
      validate_max_tier_retries!
      true
    end

    private

    def validate_llm_provider!
      return if VALID_LLM_PROVIDERS.include?(@llm_provider)

      raise ConfigurationError, "Invalid LLM provider: #{@llm_provider}. Must be one of: #{VALID_LLM_PROVIDERS.join(', ')}"
    end

    def validate_llm_api_key!
      key = llm_api_key
      return if key && !key.empty?

      env_var = PROVIDER_DEFAULTS.dig(@llm_provider, :env_key) || "ANTHROPIC_API_KEY"
      raise ConfigurationError, "LLM API key is required. Set llm_api_key or #{env_var} environment variable."
    end

    def validate_execution_provider!
      return if VALID_EXECUTION_PROVIDERS.include?(@execution_provider)

      raise ConfigurationError, "Invalid execution provider: #{@execution_provider}. Must be one of: #{VALID_EXECUTION_PROVIDERS.join(', ')}"
    end

    def validate_github_config!
      return unless @execution_provider == :github

      if @github_token.nil? || @github_token.empty?
        raise ConfigurationError, "GitHub token is required when using GitHub execution provider. Set github_token or GITHUB_TOKEN env var."
      end

      if @github_repo.nil? || @github_repo.empty?
        raise ConfigurationError, "GitHub repo is required when using GitHub execution provider (e.g., 'owner/repo')."
      end
    end

    def validate_max_iterations!
      return if @max_iterations.is_a?(Integer) && @max_iterations.between?(1, 10)

      raise ConfigurationError, "max_iterations must be an integer between 1 and 10."
    end

    def validate_max_tier_retries!
      return if @max_tier_retries.is_a?(Integer) && @max_tier_retries.between?(0, 5)

      raise ConfigurationError, "max_tier_retries must be an integer between 0 and 5."
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
