require "test_helper"
require "arnold_pipeline/setup/request"

module ArnoldPipeline
  module Setup
    class RequestTest < ActiveSupport::TestCase
      cover "ArnoldPipeline::Setup::Request*"

      test "defaults execution_provider to claude_code" do
        request = Request.new
        assert_equal "claude_code", request.execution_provider
      end

      test "defaults config_overrides to empty hash" do
        request = Request.new
        assert_equal({}, request.config_overrides)
      end

      test "defaults all optional fields to nil" do
        request = Request.new
        assert_nil request.project_path
        assert_nil request.description
        assert_nil request.llm_provider
        assert_nil request.llm_api_key
        assert_nil request.github_token
        assert_nil request.github_repo
      end

      test "accepts all keyword arguments" do
        request = Request.new(
          project_path: "/tmp/my_app",
          description: "A todo app",
          llm_provider: "openai",
          llm_api_key: "sk-test",
          execution_provider: "github",
          github_token: "ghp_test",
          github_repo: "owner/repo",
          config_overrides: { "max_iterations" => 5 }
        )

        assert_equal "/tmp/my_app", request.project_path
        assert_equal "A todo app", request.description
        assert_equal "openai", request.llm_provider
        assert_equal "sk-test", request.llm_api_key
        assert_equal "github", request.execution_provider
        assert_equal "ghp_test", request.github_token
        assert_equal "owner/repo", request.github_repo
        assert_equal({ "max_iterations" => 5 }, request.config_overrides)
      end

      test "attributes are mutable via accessors" do
        request = Request.new
        request.project_path = "/tmp/updated"
        assert_equal "/tmp/updated", request.project_path
      end

      test "VALID_LLM_PROVIDERS includes anthropic, openai, and openrouter" do
        assert_includes Request::VALID_LLM_PROVIDERS, "anthropic"
        assert_includes Request::VALID_LLM_PROVIDERS, "openai"
        assert_includes Request::VALID_LLM_PROVIDERS, "openrouter"
      end

      test "VALID_EXECUTION_PROVIDERS includes github claude_code and null" do
        assert_includes Request::VALID_EXECUTION_PROVIDERS, "github"
        assert_includes Request::VALID_EXECUTION_PROVIDERS, "claude_code"
        assert_includes Request::VALID_EXECUTION_PROVIDERS, "null"
      end

      test "nil config_overrides becomes empty hash" do
        request = Request.new(config_overrides: nil)
        assert_equal({}, request.config_overrides)
      end
    end
  end
end
