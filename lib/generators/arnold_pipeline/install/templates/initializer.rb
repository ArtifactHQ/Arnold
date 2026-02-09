ArnoldPipeline.configure do |config|
  # LLM Provider: :anthropic or :openai
  # config.llm_provider = :anthropic

  # API key for the LLM provider (defaults to ENV["ANTHROPIC_API_KEY"])
  # config.llm_api_key = ENV["ANTHROPIC_API_KEY"]

  # Model to use for LLM calls
  # config.llm_model = "claude-sonnet-4-20250514"

  # Execution provider: :github (more providers coming soon)
  # config.execution_provider = :github

  # GitHub personal access token (defaults to ENV["GITHUB_TOKEN"])
  # config.github_token = ENV["GITHUB_TOKEN"]

  # GitHub repository in "owner/repo" format
  # config.github_repo = "owner/repo"

  # Maximum number of feedback iterations (1-10, default: 3)
  # config.max_iterations = 3

  # Custom library path for personas and recipes (optional)
  # config.library_path = Rails.root.join("lib", "arnold_library").to_s
end
