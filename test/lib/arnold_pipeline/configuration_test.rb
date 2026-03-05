require "test_helper"

module ArnoldPipeline
  class ConfigurationTest < ActiveSupport::TestCase
    cover "ArnoldPipeline::Configuration*"

    setup do
      @config = Configuration.new
    end

    test "has sensible defaults" do
      assert_includes Configuration::VALID_LLM_PROVIDERS, @config.llm_provider
      assert_includes [ "claude-sonnet-4-6", "gpt-5-mini-2025-08-07" ], @config.llm_model
      assert_equal :github, @config.execution_provider
      assert_equal 3, @config.max_iterations
      assert_nil @config.github_issue_mention
      assert_nil @config.library_path
      assert_equal 30, @config.polling_interval
      assert_equal 1800, @config.polling_timeout
      assert_equal 300, @config.polling_max_interval
      assert_equal true, @config.tier_gate_enabled
      assert_equal true, @config.context_propagation_enabled
      assert_equal 2, @config.max_tier_retries
      assert_equal true, @config.workflow_status_enabled
      assert_kind_of Regexp, @config.workflow_branch_pattern
      assert_equal true, @config.openspec_enabled
      assert_equal "openspec", @config.openspec_cli_path
      assert_equal 600, @config.llm_request_timeout
    end

    test "validate! passes with valid config" do
      @config.llm_api_key = "sk-test-key"
      @config.github_token = "ghp_test"
      @config.github_repo = "owner/repo"

      assert @config.validate!
    end

    test "validate! raises on invalid llm_provider" do
      @config.llm_provider = :invalid
      @config.llm_api_key = "sk-test"
      @config.github_token = "ghp_test"
      @config.github_repo = "owner/repo"

      error = assert_raises(ConfigurationError) { @config.validate! }
      assert_match(/Invalid LLM provider/, error.message)
    end

    test "validate! raises on missing llm_api_key" do
      original_anthropic = ENV["ANTHROPIC_API_KEY"]
      original_openai = ENV["OPENAI_API_KEY"]
      ENV.delete("ANTHROPIC_API_KEY")
      ENV.delete("OPENAI_API_KEY")

      config = Configuration.new
      config.llm_api_key = nil
      config.github_token = "ghp_test"
      config.github_repo = "owner/repo"

      error = assert_raises(ConfigurationError) { config.validate! }
      assert_match(/LLM API key is required/, error.message)
    ensure
      original_anthropic ? ENV["ANTHROPIC_API_KEY"] = original_anthropic : ENV.delete("ANTHROPIC_API_KEY")
      original_openai ? ENV["OPENAI_API_KEY"] = original_openai : ENV.delete("OPENAI_API_KEY")
    end

    test "validate! raises on empty llm_api_key" do
      @config.llm_api_key = ""
      @config.github_token = "ghp_test"
      @config.github_repo = "owner/repo"

      error = assert_raises(ConfigurationError) { @config.validate! }
      assert_match(/LLM API key is required/, error.message)
    end

    test "validate! raises on missing github_token" do
      @config.llm_api_key = "sk-test"
      @config.github_token = nil
      @config.github_repo = "owner/repo"

      error = assert_raises(ConfigurationError) { @config.validate! }
      assert_match(/GitHub token is required/, error.message)
    end

    test "validate! raises on missing github_repo" do
      @config.llm_api_key = "sk-test"
      @config.github_token = "ghp_test"
      @config.github_repo = nil

      error = assert_raises(ConfigurationError) { @config.validate! }
      assert_match(/GitHub repo is required/, error.message)
    end

    test "validate! raises on invalid max_iterations" do
      @config.llm_api_key = "sk-test"
      @config.github_token = "ghp_test"
      @config.github_repo = "owner/repo"
      @config.max_iterations = 0

      error = assert_raises(ConfigurationError) { @config.validate! }
      assert_match(/max_iterations must be an integer/, error.message)
    end

    test "validate! accepts openai provider" do
      @config.llm_provider = :openai
      @config.llm_api_key = "sk-test"
      @config.github_token = "ghp_test"
      @config.github_repo = "owner/repo"

      assert @config.validate!
    end

    test "llm_api_key resolves from env based on provider" do
      @config.llm_provider = :openai
      original = ENV["OPENAI_API_KEY"]
      ENV["OPENAI_API_KEY"] = "sk-openai-test"

      assert_equal "sk-openai-test", @config.llm_api_key
    ensure
      ENV["OPENAI_API_KEY"] = original
    end

    test "llm_model defaults based on provider" do
      @config.llm_provider = :anthropic
      assert_equal "claude-sonnet-4-6", @config.llm_model

      @config.llm_provider = :openai
      assert_equal "gpt-5-mini-2025-08-07", @config.llm_model
    end

    test "explicit llm_api_key takes precedence over env" do
      @config.llm_api_key = "explicit-key"
      assert_equal "explicit-key", @config.llm_api_key
    end

    test "explicit llm_model takes precedence over provider default" do
      @config.llm_model = "custom-model"
      assert_equal "custom-model", @config.llm_model
    end

    test "configure block works on module" do
      ArnoldPipeline.configure do |config|
        config.llm_provider = :openai
        config.llm_model = "gpt-4"
      end

      assert_equal :openai, ArnoldPipeline.configuration.llm_provider
      assert_equal "gpt-4", ArnoldPipeline.configuration.llm_model
    ensure
      ArnoldPipeline.reset_configuration!
    end

    test "reset_configuration! restores defaults" do
      ArnoldPipeline.configure { |c| c.llm_model = "custom-model" }
      ArnoldPipeline.reset_configuration!

      assert_includes [ "claude-sonnet-4-6", "gpt-4o" ], ArnoldPipeline.configuration.llm_model
    end

    test "validate! raises on invalid polling_interval" do
      @config.llm_api_key = "sk-test"
      @config.github_token = "ghp_test"
      @config.github_repo = "owner/repo"
      @config.polling_interval = 0

      error = assert_raises(ConfigurationError) { @config.validate! }
      assert_match(/polling_interval must be a positive number/, error.message)
    end

    test "validate! raises on invalid polling_timeout" do
      @config.llm_api_key = "sk-test"
      @config.github_token = "ghp_test"
      @config.github_repo = "owner/repo"
      @config.polling_timeout = -1

      error = assert_raises(ConfigurationError) { @config.validate! }
      assert_match(/polling_timeout must be a positive number/, error.message)
    end

    test "validate! raises on invalid polling_max_interval" do
      @config.llm_api_key = "sk-test"
      @config.github_token = "ghp_test"
      @config.github_repo = "owner/repo"
      @config.polling_max_interval = 0

      error = assert_raises(ConfigurationError) { @config.validate! }
      assert_match(/polling_max_interval must be a positive number/, error.message)
    end

    test "validate! accepts custom polling values" do
      @config.llm_api_key = "sk-test"
      @config.github_token = "ghp_test"
      @config.github_repo = "owner/repo"
      @config.polling_interval = 10
      @config.polling_timeout = 600
      @config.polling_max_interval = 120

      assert @config.validate!
    end

    test "validate! raises on invalid max_tier_retries (negative)" do
      @config.llm_api_key = "sk-test"
      @config.github_token = "ghp_test"
      @config.github_repo = "owner/repo"
      @config.max_tier_retries = -1

      error = assert_raises(ConfigurationError) { @config.validate! }
      assert_match(/max_tier_retries must be an integer between 0 and 5/, error.message)
    end

    test "validate! raises on invalid max_tier_retries (too high)" do
      @config.llm_api_key = "sk-test"
      @config.github_token = "ghp_test"
      @config.github_repo = "owner/repo"
      @config.max_tier_retries = 6

      error = assert_raises(ConfigurationError) { @config.validate! }
      assert_match(/max_tier_retries must be an integer between 0 and 5/, error.message)
    end

    test "validate! raises on non-integer max_tier_retries" do
      @config.llm_api_key = "sk-test"
      @config.github_token = "ghp_test"
      @config.github_repo = "owner/repo"
      @config.max_tier_retries = 1.5

      error = assert_raises(ConfigurationError) { @config.validate! }
      assert_match(/max_tier_retries must be an integer between 0 and 5/, error.message)
    end

    test "validate! accepts max_tier_retries of 0" do
      @config.llm_api_key = "sk-test"
      @config.github_token = "ghp_test"
      @config.github_repo = "owner/repo"
      @config.max_tier_retries = 0

      assert @config.validate!
    end

    test "validate! accepts max_tier_retries of 5" do
      @config.llm_api_key = "sk-test"
      @config.github_token = "ghp_test"
      @config.github_repo = "owner/repo"
      @config.max_tier_retries = 5

      assert @config.validate!
    end

    test "validate! raises on non-Regexp workflow_branch_pattern" do
      @config.llm_api_key = "sk-test"
      @config.github_token = "ghp_test"
      @config.github_repo = "owner/repo"
      @config.workflow_branch_pattern = "not-a-regexp"

      error = assert_raises(ConfigurationError) { @config.validate! }
      assert_match(/workflow_branch_pattern must be a Regexp/, error.message)
    end

    # --- analysis_done_threshold tests ---

    test "analysis_done_threshold defaults to nil" do
      assert_nil @config.analysis_done_threshold
    end

    test "validate! accepts analysis_done_threshold of nil" do
      @config.llm_api_key = "sk-test"
      @config.github_token = "ghp_test"
      @config.github_repo = "owner/repo"
      @config.analysis_done_threshold = nil

      assert @config.validate!
    end

    test "validate! accepts analysis_done_threshold of 50" do
      @config.llm_api_key = "sk-test"
      @config.github_token = "ghp_test"
      @config.github_repo = "owner/repo"
      @config.analysis_done_threshold = 50

      assert @config.validate!
    end

    test "validate! accepts analysis_done_threshold of 80" do
      @config.llm_api_key = "sk-test"
      @config.github_token = "ghp_test"
      @config.github_repo = "owner/repo"
      @config.analysis_done_threshold = 80

      assert @config.validate!
    end

    test "validate! accepts analysis_done_threshold of 100" do
      @config.llm_api_key = "sk-test"
      @config.github_token = "ghp_test"
      @config.github_repo = "owner/repo"
      @config.analysis_done_threshold = 100

      assert @config.validate!
    end

    test "validate! raises on analysis_done_threshold below 50" do
      @config.llm_api_key = "sk-test"
      @config.github_token = "ghp_test"
      @config.github_repo = "owner/repo"
      @config.analysis_done_threshold = 49

      error = assert_raises(ConfigurationError) { @config.validate! }
      assert_match(/analysis_done_threshold must be nil or an integer between 50 and 100/, error.message)
    end

    test "validate! raises on analysis_done_threshold above 100" do
      @config.llm_api_key = "sk-test"
      @config.github_token = "ghp_test"
      @config.github_repo = "owner/repo"
      @config.analysis_done_threshold = 101

      error = assert_raises(ConfigurationError) { @config.validate! }
      assert_match(/analysis_done_threshold must be nil or an integer between 50 and 100/, error.message)
    end

    test "validate! raises on non-integer analysis_done_threshold" do
      @config.llm_api_key = "sk-test"
      @config.github_token = "ghp_test"
      @config.github_repo = "owner/repo"
      @config.analysis_done_threshold = 75.5

      error = assert_raises(ConfigurationError) { @config.validate! }
      assert_match(/analysis_done_threshold must be nil or an integer between 50 and 100/, error.message)
    end

    # --- criteria_check_mode tests ---

    test "defaults criteria_check_mode to :advisory" do
      assert_equal :advisory, @config.criteria_check_mode
    end

    test "accepts :gating criteria_check_mode" do
      @config.llm_api_key = "sk-test"
      @config.github_token = "ghp_test"
      @config.github_repo = "owner/repo"
      @config.criteria_check_mode = :gating

      assert @config.validate!
    end

    test "accepts :disabled criteria_check_mode" do
      @config.llm_api_key = "sk-test"
      @config.github_token = "ghp_test"
      @config.github_repo = "owner/repo"
      @config.criteria_check_mode = :disabled

      assert @config.validate!
    end

    test "rejects invalid criteria_check_mode" do
      @config.llm_api_key = "sk-test"
      @config.github_token = "ghp_test"
      @config.github_repo = "owner/repo"
      @config.criteria_check_mode = :invalid

      error = assert_raises(ConfigurationError) { @config.validate! }
      assert_match(/criteria_check_mode must be one of/, error.message)
    end

    # --- claude_code config defaults ---

    test "claude_code_max_turns defaults to 25" do
      assert_equal 25, @config.claude_code_max_turns
    end

    test "claude_code_max_budget_usd defaults to nil" do
      assert_nil @config.claude_code_max_budget_usd
    end

    test "claude_code_tools defaults to nil" do
      assert_nil @config.claude_code_tools
    end

    test "claude_code_allowed_tools defaults to nil" do
      assert_nil @config.claude_code_allowed_tools
    end

    test "claude_code_disallowed_tools defaults to nil" do
      assert_nil @config.claude_code_disallowed_tools
    end

    # --- claude_code_max_budget_usd validation ---

    test "validate! rejects invalid claude_code_max_budget_usd" do
      @config.llm_api_key = "sk-test"
      @config.github_token = "ghp_test"
      @config.github_repo = "owner/repo"

      [ 0, -5, "30" ].each do |bad|
        @config.claude_code_max_budget_usd = bad
        error = assert_raises(ConfigurationError, "Expected ConfigurationError for #{bad.inspect}") { @config.validate! }
        assert_match(/claude_code_max_budget_usd must be nil or a positive number/, error.message)
      end
    end

    test "validate! accepts valid claude_code_max_budget_usd" do
      @config.llm_api_key = "sk-test"
      @config.github_token = "ghp_test"
      @config.github_repo = "owner/repo"

      [ nil, 1.0, 5, 0.5 ].each do |good|
        @config.claude_code_max_budget_usd = good
        assert @config.validate!, "Expected validate! to pass for #{good.inspect}"
      end
    end

    test "validate! rejects invalid claude_code_tool_restrictions" do
      @config.llm_api_key = "sk-test"
      @config.github_token = "ghp_test"
      @config.github_repo = "owner/repo"

      %i[claude_code_tools claude_code_allowed_tools claude_code_disallowed_tools].each do |attr|
        @config.send(:"#{attr}=", "not_an_array")
        assert_raises(ConfigurationError) { @config.validate! }
        @config.send(:"#{attr}=", [ 123 ])
        assert_raises(ConfigurationError) { @config.validate! }
        @config.send(:"#{attr}=", nil)
      end
    end

    test "validate! accepts valid claude_code_tool_restrictions" do
      @config.llm_api_key = "sk-test"
      @config.github_token = "ghp_test"
      @config.github_repo = "owner/repo"

      @config.claude_code_tools = [ "Bash", "Edit" ]
      @config.claude_code_allowed_tools = [ "Bash(git *)" ]
      @config.claude_code_disallowed_tools = nil
      assert @config.validate!
    end

    # --- Auto-detection tests ---

    test "auto-detects anthropic when ANTHROPIC_API_KEY is set" do
      original_anthropic = ENV["ANTHROPIC_API_KEY"]
      original_openai = ENV["OPENAI_API_KEY"]
      ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"
      ENV.delete("OPENAI_API_KEY")

      config = Configuration.new
      assert_equal :anthropic, config.llm_provider
    ensure
      ENV["ANTHROPIC_API_KEY"] = original_anthropic
      ENV["OPENAI_API_KEY"] = original_openai
    end

    test "auto-detects openai when only OPENAI_API_KEY is set" do
      original_anthropic = ENV["ANTHROPIC_API_KEY"]
      original_openai = ENV["OPENAI_API_KEY"]
      ENV.delete("ANTHROPIC_API_KEY")
      ENV["OPENAI_API_KEY"] = "sk-openai-test"

      config = Configuration.new
      assert_equal :openai, config.llm_provider
    ensure
      ENV["ANTHROPIC_API_KEY"] = original_anthropic
      ENV["OPENAI_API_KEY"] = original_openai
    end

    test "auto-detects anthropic when neither key is set" do
      original_anthropic = ENV["ANTHROPIC_API_KEY"]
      original_openai = ENV["OPENAI_API_KEY"]
      ENV.delete("ANTHROPIC_API_KEY")
      ENV.delete("OPENAI_API_KEY")

      config = Configuration.new
      assert_equal :anthropic, config.llm_provider
    ensure
      ENV["ANTHROPIC_API_KEY"] = original_anthropic
      ENV["OPENAI_API_KEY"] = original_openai
    end

    test "auto-detects anthropic when both keys are set" do
      original_anthropic = ENV["ANTHROPIC_API_KEY"]
      original_openai = ENV["OPENAI_API_KEY"]
      ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"
      ENV["OPENAI_API_KEY"] = "sk-openai-test"

      config = Configuration.new
      assert_equal :anthropic, config.llm_provider
    ensure
      ENV["ANTHROPIC_API_KEY"] = original_anthropic
      ENV["OPENAI_API_KEY"] = original_openai
    end

    test "explicit llm_provider overrides auto-detection" do
      original_openai = ENV["OPENAI_API_KEY"]
      ENV["OPENAI_API_KEY"] = "sk-openai-test"

      config = Configuration.new
      config.llm_provider = :openai
      assert_equal :openai, config.llm_provider
    ensure
      ENV["OPENAI_API_KEY"] = original_openai
    end

    # --- provider delegation tests ---

    test "validate! delegates execution validation to provider class" do
      require "arnold_pipeline/providers/execution/null"
      @config.llm_api_key = "sk-test"
      @config.execution_provider = :null

      # Null provider has no-op validation, so this should pass without github config
      assert @config.validate!
    end

    # --- stop_after validation tests ---

    test "validate! with stop_after: :spec skips GitHub validation" do
      @config.llm_api_key = "sk-test"
      # No github_token or github_repo set
      assert @config.validate!(stop_after: :spec)
    end

    test "validate! with stop_after: :tasks skips GitHub validation" do
      @config.llm_api_key = "sk-test"
      # No github_token or github_repo set
      assert @config.validate!(stop_after: :tasks)
    end

    test "validate! with stop_after: :executed requires GitHub config" do
      @config.llm_api_key = "sk-test"
      @config.github_token = nil
      @config.github_repo = nil

      error = assert_raises(ConfigurationError) { @config.validate!(stop_after: :executed) }
      assert_match(/GitHub token is required/, error.message)
    end

    test "validate! with stop_after: nil requires GitHub config" do
      @config.llm_api_key = "sk-test"
      @config.github_token = nil
      @config.github_repo = nil

      error = assert_raises(ConfigurationError) { @config.validate! }
      assert_match(/GitHub token is required/, error.message)
    end

    # -- Brownfield model defaults --

    test "brownfield_model_for returns gpt-5-mini for parallel agents" do
      assert_equal "gpt-5-mini-2025-08-07", @config.brownfield_model_for(:data_model)
      assert_equal "gpt-5-mini-2025-08-07", @config.brownfield_model_for(:business_logic)
      assert_equal "gpt-5-mini-2025-08-07", @config.brownfield_model_for(:infrastructure)
    end

    test "brownfield_model_for returns provider-specific model for synthesis" do
      @config.llm_provider = :openai
      assert_equal "gpt-5-mini-2025-08-07", @config.brownfield_model_for(:synthesis)

      @config.llm_provider = :anthropic
      assert_equal "claude-sonnet-4-6", @config.brownfield_model_for(:synthesis)
    end

    test "brownfield_model_for respects explicit overrides" do
      @config.brownfield_agent_models = { data_model: "gpt-4o", synthesis: "o3" }
      assert_equal "gpt-4o", @config.brownfield_model_for(:data_model)
      assert_equal "o3", @config.brownfield_model_for(:synthesis)
    end
  end
end
