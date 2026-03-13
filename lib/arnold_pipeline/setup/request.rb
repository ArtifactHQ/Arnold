module ArnoldPipeline
  module Setup
    class Request
      VALID_LLM_PROVIDERS = %w[anthropic openai openrouter].freeze
      VALID_EXECUTION_PROVIDERS = %w[github claude_code null].freeze

      attr_accessor :project_path, :description, :llm_provider, :llm_api_key,
                    :execution_provider, :github_token, :github_repo,
                    :config_overrides

      def initialize(
        project_path: nil,
        description: nil,
        llm_provider: nil,
        llm_api_key: nil,
        execution_provider: nil,
        github_token: nil,
        github_repo: nil,
        config_overrides: {}
      )
        @project_path = project_path
        @description = description
        @llm_provider = llm_provider
        @llm_api_key = llm_api_key
        @execution_provider = execution_provider || "claude_code"
        @github_token = github_token
        @github_repo = github_repo
        @config_overrides = config_overrides || {}
      end
    end
  end
end
