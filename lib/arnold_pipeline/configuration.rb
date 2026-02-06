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
                  :max_iterations, :library_path
    attr_writer   :llm_api_key, :llm_model

    def initialize
      @llm_provider       = :anthropic
      @llm_api_key        = nil
      @llm_model          = nil
      @execution_provider = :github
      @github_token       = ENV["GITHUB_TOKEN"]
      @github_repo        = nil
      @max_iterations     = 3
      @library_path       = nil
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
  end
end
