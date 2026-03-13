require "test_helper"
require "arnold_pipeline/setup/orchestrator"
require "arnold_pipeline/orchestrator"
require "tmpdir"

module ArnoldPipeline
  module Setup
    class OrchestratorTest < ActiveSupport::TestCase
      cover "ArnoldPipeline::Setup::Orchestrator*"

      setup do
        @tmp_dir = Dir.mktmpdir("arnold_setup_test")
        @project_path = File.join(@tmp_dir, "my_app")

        # Stub the config path so tests don't touch real ~/.arnold_pipeline
        @original_config_path = Orchestrator::CONFIG_PATH
        @test_arnold_home = File.join(@tmp_dir, ".arnold_pipeline")
        @test_config_path = File.join(@test_arnold_home, "config.yml")
        Orchestrator.send(:remove_const, :CONFIG_PATH)
        Orchestrator.const_set(:CONFIG_PATH, @test_config_path)
        Orchestrator.send(:remove_const, :ARNOLD_HOME)
        Orchestrator.const_set(:ARNOLD_HOME, @test_arnold_home)

        # Build a mock pipeline run
        @pipeline_run = PipelineRun.create!(
          nl_input: "a simple todo app with user authentication",
          status: :paused,
          metadata: { "paused_at" => "tasks" }
        )
        @spec = Specification.create!(
          pipeline_run: @pipeline_run,
          content: "# Todo App\n\n## Purpose\nA simple todo app.\n\n## Requirements\n- Auth\n- Tasks",
          version: 1,
          structured_data: { "product_name" => "Todo App" }
        )
        @pipeline_run.tasks.create!(
          title: "Setup database", description: "Create DB schema",
          priority: 1, position: 1, tier: 0, labels: [], depends_on: []
        )
        @pipeline_run.tasks.create!(
          title: "Add authentication", description: "User login",
          priority: 2, position: 2, tier: 1, labels: [], depends_on: [ 1 ]
        )

        # Stub the pipeline orchestrator
        @orchestrator_stub = stub("orchestrator")
        @orchestrator_stub.stubs(:call).returns(@pipeline_run)
        ArnoldPipeline::Orchestrator.stubs(:new).returns(@orchestrator_stub)

        @original_anthropic_key = ENV["ANTHROPIC_API_KEY"]
        @original_openai_key = ENV["OPENAI_API_KEY"]
      end

      teardown do
        FileUtils.rm_rf(@tmp_dir)
        Orchestrator.send(:remove_const, :CONFIG_PATH)
        Orchestrator.const_set(:CONFIG_PATH, @original_config_path)
        Orchestrator.send(:remove_const, :ARNOLD_HOME)
        Orchestrator.const_set(:ARNOLD_HOME, File.expand_path("~/.arnold_pipeline"))

        if @original_anthropic_key
          ENV["ANTHROPIC_API_KEY"] = @original_anthropic_key
        else
          ENV.delete("ANTHROPIC_API_KEY")
        end
        if @original_openai_key
          ENV["OPENAI_API_KEY"] = @original_openai_key
        else
          ENV.delete("OPENAI_API_KEY")
        end

        ArnoldPipeline.reset_configuration!
      end

      # --- needs_input tests ---

      test "missing project_path returns needs_input" do
        request = Request.new(
          description: "a todo app with user auth",
          llm_api_key: "sk-test"
        )
        result = Orchestrator.new.call(request)

        assert result.needs_input?
        assert_includes result.missing_fields, :project_path
      end

      test "missing description returns needs_input" do
        request = Request.new(
          project_path: @project_path,
          llm_api_key: "sk-test"
        )
        result = Orchestrator.new.call(request)

        assert result.needs_input?
        assert_includes result.missing_fields, :description
      end

      test "missing api key with no env and no config returns needs_input" do
        ENV.delete("ANTHROPIC_API_KEY")
        ENV.delete("OPENAI_API_KEY")

        request = Request.new(
          project_path: @project_path,
          description: "a todo app with user auth"
        )
        result = Orchestrator.new.call(request)

        assert result.needs_input?
        assert_includes result.missing_fields, :llm_api_key
      end

      test "api key from env var satisfies requirement" do
        ENV["ANTHROPIC_API_KEY"] = "sk-from-env"

        request = Request.new(
          project_path: @project_path,
          description: "a todo app with user auth"
        )
        result = Orchestrator.new.call(request)

        refute result.needs_input?
      end

      test "api key from existing config satisfies requirement" do
        ENV.delete("ANTHROPIC_API_KEY")
        ENV.delete("OPENAI_API_KEY")

        FileUtils.mkdir_p(@test_arnold_home)
        File.write(@test_config_path, YAML.dump("llm_api_key" => "sk-from-config"))

        request = Request.new(
          project_path: @project_path,
          description: "a todo app with user auth"
        )
        result = Orchestrator.new.call(request)

        refute result.needs_input?
      end

      test "github provider requires github_token" do
        request = Request.new(
          project_path: @project_path,
          description: "a todo app with user auth",
          llm_api_key: "sk-test",
          execution_provider: "github",
          github_repo: "owner/repo"
        )
        result = Orchestrator.new.call(request)

        assert result.needs_input?
        assert_includes result.missing_fields, :github_token
      end

      test "github provider requires github_repo" do
        request = Request.new(
          project_path: @project_path,
          description: "a todo app with user auth",
          llm_api_key: "sk-test",
          execution_provider: "github",
          github_token: "ghp_test"
        )
        result = Orchestrator.new.call(request)

        assert result.needs_input?
        assert_includes result.missing_fields, :github_repo
      end

      # --- validation error tests ---

      test "short description returns error" do
        request = Request.new(
          project_path: @project_path,
          description: "app",
          llm_api_key: "sk-test"
        )
        result = Orchestrator.new.call(request)

        assert result.error?
        assert result.errors.any? { |e| e.include?("at least") }
      end

      test "invalid parent directory returns error" do
        request = Request.new(
          project_path: "/nonexistent/parent/dir/my_app",
          description: "a todo app with user auth",
          llm_api_key: "sk-test"
        )
        result = Orchestrator.new.call(request)

        assert result.error?
        assert result.errors.any? { |e| e.include?("Parent directory") }
      end

      test "invalid github repo format returns error" do
        request = Request.new(
          project_path: @project_path,
          description: "a todo app with user auth",
          llm_api_key: "sk-test",
          execution_provider: "github",
          github_token: "ghp_test",
          github_repo: "invalid-no-slash"
        )
        result = Orchestrator.new.call(request)

        assert result.error?
        assert result.errors.any? { |e| e.include?("Invalid GitHub repo format") }
      end

      # --- success (complete) tests ---

      test "all fields present returns complete" do
        @orchestrator_stub.expects(:call).with(
          nl_input: "a todo app with user auth",
          stop_after: :tasks
        ).returns(@pipeline_run)

        request = Request.new(
          project_path: @project_path,
          description: "a todo app with user auth",
          llm_api_key: "sk-test"
        )
        result = Orchestrator.new.call(request)

        assert result.complete?
        assert_equal @project_path, result.project_path
        assert_equal @pipeline_run.id, result.run_id
      end

      test "project directory is created with .git" do
        request = Request.new(
          project_path: @project_path,
          description: "a todo app with user auth",
          llm_api_key: "sk-test"
        )
        Orchestrator.new.call(request)

        assert File.directory?(@project_path)
        assert File.directory?(File.join(@project_path, ".git"))
      end

      test "config.yml is written with correct keys" do
        request = Request.new(
          project_path: @project_path,
          description: "a todo app with user auth",
          llm_provider: "openai",
          llm_api_key: "sk-test",
          execution_provider: "claude_code"
        )
        Orchestrator.new.call(request)

        config = YAML.safe_load_file(@test_config_path)
        assert_equal "openai", config["llm_provider"]
        assert_equal "claude_code", config["execution_provider"]
        assert_equal "sk-test", config["llm_api_key"]
        assert_equal @project_path, config["claude_code_repo_path"]
        assert_equal @project_path, config["target_repo_path"]
      end

      test "existing config keys are preserved not overwritten" do
        FileUtils.mkdir_p(@test_arnold_home)
        File.write(@test_config_path, YAML.dump(
          "llm_provider" => "openai",
          "custom_key" => "preserved_value"
        ))

        request = Request.new(
          project_path: @project_path,
          description: "a todo app with user auth",
          llm_provider: "anthropic",
          llm_api_key: "sk-test"
        )
        Orchestrator.new.call(request)

        config = YAML.safe_load_file(@test_config_path)
        # Existing key wins over new request value
        assert_equal "openai", config["llm_provider"]
        # Custom key preserved
        assert_equal "preserved_value", config["custom_key"]
      end

      test "config_overrides always win over existing config" do
        FileUtils.mkdir_p(@test_arnold_home)
        File.write(@test_config_path, YAML.dump(
          "llm_provider" => "openai",
          "max_iterations" => 3
        ))

        request = Request.new(
          project_path: @project_path,
          description: "a todo app with user auth",
          llm_api_key: "sk-test",
          config_overrides: { "max_iterations" => 5, "llm_provider" => "anthropic" }
        )
        Orchestrator.new.call(request)

        config = YAML.safe_load_file(@test_config_path)
        assert_equal 5, config["max_iterations"]
        assert_equal "anthropic", config["llm_provider"]
      end

      test "claude_code provider writes claude_code_repo_path" do
        request = Request.new(
          project_path: @project_path,
          description: "a todo app with user auth",
          llm_api_key: "sk-test",
          execution_provider: "claude_code"
        )
        Orchestrator.new.call(request)

        config = YAML.safe_load_file(@test_config_path)
        assert_equal @project_path, config["claude_code_repo_path"]
      end

      test "github provider does not write claude_code_repo_path" do
        request = Request.new(
          project_path: @project_path,
          description: "a todo app with user auth",
          llm_api_key: "sk-test",
          execution_provider: "github",
          github_token: "ghp_test",
          github_repo: "owner/repo"
        )
        Orchestrator.new.call(request)

        config = YAML.safe_load_file(@test_config_path)
        assert_nil config["claude_code_repo_path"]
        assert_equal "ghp_test", config["github_token"]
        assert_equal "owner/repo", config["github_repo"]
      end

      test "spec_summary includes product name and version" do
        request = Request.new(
          project_path: @project_path,
          description: "a todo app with user auth",
          llm_api_key: "sk-test"
        )
        result = Orchestrator.new.call(request)

        assert_equal 1, result.spec_summary[:version]
        assert_equal "Todo App", result.spec_summary[:product_name]
      end

      test "task_summary includes total and tier breakdown" do
        request = Request.new(
          project_path: @project_path,
          description: "a todo app with user auth",
          llm_api_key: "sk-test"
        )
        result = Orchestrator.new.call(request)

        assert_equal 2, result.task_summary[:total]
        assert_equal 2, result.task_summary[:tiers]
        assert_equal 2, result.task_summary[:breakdown].size
      end

      test "error during pipeline returns Result.error" do
        @orchestrator_stub.stubs(:call).raises(StandardError.new("LLM unavailable"))

        request = Request.new(
          project_path: @project_path,
          description: "a todo app with user auth",
          llm_api_key: "sk-test"
        )
        result = Orchestrator.new.call(request)

        assert result.error?
        assert result.errors.any? { |e| e.include?("LLM unavailable") }
      end

      test "existing git repo is not re-initialized" do
        FileUtils.mkdir_p(@project_path)
        system("git", "init", @project_path, out: File::NULL, err: File::NULL)
        original_head = File.read(File.join(@project_path, ".git", "HEAD"))

        request = Request.new(
          project_path: @project_path,
          description: "a todo app with user auth",
          llm_api_key: "sk-test"
        )
        Orchestrator.new.call(request)

        # HEAD should be unchanged (no re-init)
        assert_equal original_head, File.read(File.join(@project_path, ".git", "HEAD"))
      end

      test "config_path in result points to config file" do
        request = Request.new(
          project_path: @project_path,
          description: "a todo app with user auth",
          llm_api_key: "sk-test"
        )
        result = Orchestrator.new.call(request)

        assert_equal @test_config_path, result.config_path
      end

      test "only writes llm_api_key to config when explicitly provided in request" do
        ENV["ANTHROPIC_API_KEY"] = "sk-from-env"

        request = Request.new(
          project_path: @project_path,
          description: "a todo app with user auth"
          # No llm_api_key — resolved from env
        )
        Orchestrator.new.call(request)

        config = YAML.safe_load_file(@test_config_path)
        # Should NOT persist the env var to config file
        assert_nil config["llm_api_key"]
      end

      test "openai env key resolves api key for openai provider" do
        ENV.delete("ANTHROPIC_API_KEY")
        ENV["OPENAI_API_KEY"] = "sk-openai-test"

        request = Request.new(
          project_path: @project_path,
          description: "a todo app with user auth",
          llm_provider: "openai"
        )
        result = Orchestrator.new.call(request)

        refute result.needs_input?
      end

      test "openai env key auto-detects provider when no provider specified" do
        ENV.delete("ANTHROPIC_API_KEY")
        ENV["OPENAI_API_KEY"] = "sk-openai-test"

        request = Request.new(
          project_path: @project_path,
          description: "a todo app with user auth"
        )
        result = Orchestrator.new.call(request)

        refute result.needs_input?
      end

      test "both env keys with no provider prefers anthropic" do
        ENV["ANTHROPIC_API_KEY"] = "sk-anthropic-test"
        ENV["OPENAI_API_KEY"] = "sk-openai-test"

        request = Request.new(
          project_path: @project_path,
          description: "a todo app with user auth"
        )
        result = Orchestrator.new.call(request)

        refute result.needs_input?
        # Verify anthropic was selected by checking the configured provider
        assert_equal :anthropic, ArnoldPipeline.configuration.llm_provider
      end
    end
  end
end
