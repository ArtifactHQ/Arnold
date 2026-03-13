require "test_helper"
require "arnold_pipeline/cli/setup_wizard"

module ArnoldPipeline
  module CliModule
    class SetupWizardTest < ActiveSupport::TestCase
      setup do
        ArnoldPipeline.reset_configuration!
        @original_anthropic = ENV["ANTHROPIC_API_KEY"]
        @original_openai = ENV["OPENAI_API_KEY"]
        @original_openrouter = ENV["OPENROUTER_API_KEY"]
        @original_shell = ENV["SHELL"]
        ENV.delete("ANTHROPIC_API_KEY")
        ENV.delete("OPENAI_API_KEY")
        ENV.delete("OPENROUTER_API_KEY")
      end

      teardown do
        ENV["ANTHROPIC_API_KEY"] = @original_anthropic if @original_anthropic
        ENV["OPENAI_API_KEY"] = @original_openai if @original_openai
        @original_openrouter ? ENV["OPENROUTER_API_KEY"] = @original_openrouter : ENV.delete("OPENROUTER_API_KEY")
        ENV["SHELL"] = @original_shell if @original_shell
        ArnoldPipeline.reset_configuration!
      end

      # --- api_key_available? (legacy interface) ---

      test "api_key_available? returns true when ANTHROPIC_API_KEY is set" do
        ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"
        assert SetupWizard.api_key_available?
      end

      test "api_key_available? returns true when OPENAI_API_KEY is set" do
        ENV["OPENAI_API_KEY"] = "sk-test"
        assert SetupWizard.api_key_available?
      end

      test "api_key_available? returns true when llm_api_key is configured" do
        ArnoldPipeline.configure { |c| c.llm_api_key = "some-key" }
        assert SetupWizard.api_key_available?
      end

      test "api_key_available? returns true when OPENROUTER_API_KEY is set" do
        ENV["OPENROUTER_API_KEY"] = "sk-or-test"
        assert SetupWizard.api_key_available?
      end

      test "api_key_available? returns false when no key is available" do
        refute SetupWizard.api_key_available?
      end

      test "prompt_and_configure! sets api key on configuration" do
        mock_prompt = mock("prompt")
        mock_prompt.expects(:select).with("Which LLM provider?", %w[Anthropic OpenAI OpenRouter]).returns("Anthropic")
        mock_prompt.expects(:mask).with("Enter your Anthropic API key:").returns("sk-ant-test123")
        mock_prompt.expects(:yes?).with("Save to ~/.arnold_pipeline/config.yml for future use?").returns(false)

        TTY::Prompt.stubs(:new).returns(mock_prompt)

        SetupWizard.prompt_and_configure!

        assert_equal :anthropic, ArnoldPipeline.configuration.llm_provider
        assert_equal "sk-ant-test123", ArnoldPipeline.configuration.llm_api_key
      end

      test "prompt_and_configure! saves config file when user agrees" do
        config_dir = File.join(Dir.tmpdir, "arnold_wizard_test_#{SecureRandom.hex(4)}")
        config_path = File.join(config_dir, "config.yml")

        mock_prompt = mock("prompt")
        mock_prompt.expects(:select).returns("OpenAI")
        mock_prompt.expects(:mask).returns("sk-openai-test")
        mock_prompt.expects(:yes?).returns(true)

        TTY::Prompt.stubs(:new).returns(mock_prompt)
        SetupWizard.stubs(:config_path).returns(config_path)

        SetupWizard.prompt_and_configure!

        assert File.exist?(config_path)
        saved = YAML.safe_load_file(config_path, symbolize_names: true)
        assert_equal "openai", saved[:llm_provider]
        assert_equal "sk-openai-test", saved[:llm_api_key]
      ensure
        FileUtils.rm_rf(config_dir)
      end

      test "prompt_and_configure! does not save when user declines" do
        config_dir = File.join(Dir.tmpdir, "arnold_wizard_nosave_#{SecureRandom.hex(4)}")
        config_path = File.join(config_dir, "config.yml")

        mock_prompt = mock("prompt")
        mock_prompt.expects(:select).returns("Anthropic")
        mock_prompt.expects(:mask).returns("sk-ant-xyz")
        mock_prompt.expects(:yes?).returns(false)

        TTY::Prompt.stubs(:new).returns(mock_prompt)
        SetupWizard.stubs(:config_path).returns(config_path)

        SetupWizard.prompt_and_configure!

        refute File.exist?(config_path)
      ensure
        FileUtils.rm_rf(config_dir)
      end

      # --- Setting data object ---

      test "Setting#detected? returns true for non-missing sources" do
        setting = SetupWizard::Setting.new(key: :llm_provider, label: "Provider", value: "anthropic", source: :env_detected)
        assert setting.detected?
      end

      test "Setting#detected? returns false for missing source" do
        setting = SetupWizard::Setting.new(key: :llm_provider, label: "Provider", value: nil, source: :missing)
        refute setting.detected?
      end

      test "Setting#mask_value shows not set for nil" do
        setting = SetupWizard::Setting.new(key: :llm_provider, label: "Provider", value: nil, source: :missing)
        assert_equal "(not set)", setting.mask_value
      end

      test "Setting#mask_value shows value directly" do
        setting = SetupWizard::Setting.new(key: :llm_provider, label: "Provider", value: "anthropic", source: :default)
        assert_equal "anthropic", setting.mask_value
      end

      # --- Detection ---

      test "detect_settings detects anthropic provider when only ANTHROPIC_API_KEY is set" do
        ENV["ANTHROPIC_API_KEY"] = "sk-ant-test123456789012345"
        SetupWizard.stubs(:config_path).returns("/tmp/nonexistent_#{SecureRandom.hex(4)}/config.yml")
        wizard = SetupWizard.new(output: StringIO.new)
        settings = wizard.detect_settings

        provider = settings.find { |s| s.key == :llm_provider }
        assert_equal "anthropic", provider.value
        assert_equal :env_detected, provider.source
      end

      test "detect_settings detects openai provider when only OPENAI_API_KEY is set" do
        ENV["OPENAI_API_KEY"] = "sk-test123456789012345"
        SetupWizard.stubs(:config_path).returns("/tmp/nonexistent_#{SecureRandom.hex(4)}/config.yml")
        wizard = SetupWizard.new(output: StringIO.new)
        settings = wizard.detect_settings

        provider = settings.find { |s| s.key == :llm_provider }
        assert_equal "openai", provider.value
        assert_equal :env_detected, provider.source
      end

      test "detect_settings marks provider as missing when both env vars are set" do
        ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"
        ENV["OPENAI_API_KEY"] = "sk-test"
        wizard = SetupWizard.new(output: StringIO.new)
        SetupWizard.stubs(:config_path).returns("/tmp/nonexistent_#{SecureRandom.hex(4)}/config.yml")
        settings = wizard.detect_settings

        provider = settings.find { |s| s.key == :llm_provider }
        refute provider.detected?, "Provider should be missing when both env vars are set (user must choose)"
      end

      test "detect_settings marks provider as missing when no env vars" do
        wizard = SetupWizard.new(output: StringIO.new)
        SetupWizard.stubs(:config_path).returns("/tmp/nonexistent_#{SecureRandom.hex(4)}/config.yml")
        settings = wizard.detect_settings

        provider = settings.find { |s| s.key == :llm_provider }
        refute provider.detected?
      end

      test "detect_settings does not include llm_api_key" do
        ENV["ANTHROPIC_API_KEY"] = "sk-ant-test123456789012345"
        wizard = SetupWizard.new(output: StringIO.new)
        settings = wizard.detect_settings

        api_key = settings.find { |s| s.key == :llm_api_key }
        assert_nil api_key, "API key should not be a detected setting"
      end

      test "detect_settings reads provider from existing config file" do
        config_dir = File.join(Dir.tmpdir, "arnold_detect_test_#{SecureRandom.hex(4)}")
        config_path = File.join(config_dir, "config.yml")
        FileUtils.mkdir_p(config_dir)
        File.write(config_path, YAML.dump("llm_provider" => "openai"))

        SetupWizard.stubs(:config_path).returns(config_path)
        wizard = SetupWizard.new(output: StringIO.new)
        settings = wizard.detect_settings

        provider = settings.find { |s| s.key == :llm_provider }
        assert_equal "openai", provider.value
        assert_equal :config_file, provider.source
      ensure
        FileUtils.rm_rf(config_dir)
      end

      test "detect_settings sets default model based on provider" do
        ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"
        SetupWizard.stubs(:config_path).returns("/tmp/nonexistent_#{SecureRandom.hex(4)}/config.yml")
        wizard = SetupWizard.new(output: StringIO.new)
        settings = wizard.detect_settings

        model = settings.find { |s| s.key == :llm_model }
        assert_equal "claude-sonnet-4-6", model.value
        assert_equal :default, model.source
      end

      test "detect_settings sets default max_iterations" do
        wizard = SetupWizard.new(output: StringIO.new)
        SetupWizard.stubs(:config_path).returns("/tmp/nonexistent_#{SecureRandom.hex(4)}/config.yml")
        settings = wizard.detect_settings

        iterations = settings.find { |s| s.key == :max_iterations }
        assert_equal "3", iterations.value
        assert_equal :default, iterations.source
      end

      test "detect_settings detects claude code cli" do
        wizard = SetupWizard.new(output: StringIO.new)
        wizard.stubs(:claude_code_installed?).returns(true)
        wizard.stubs(:detect_git_root).returns("/some/repo")
        wizard.expects(:`).with("claude --version 2>/dev/null").returns("1.0.0")

        SetupWizard.stubs(:config_path).returns("/tmp/nonexistent_#{SecureRandom.hex(4)}/config.yml")
        settings = wizard.detect_settings

        cli = settings.find { |s| s.key == :claude_code_cli }
        assert cli.detected?
        assert_equal :detected, cli.source
      end

      # --- API key instructions ---

      test "display_api_key_instructions shows env var is set when present" do
        ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"
        output = StringIO.new
        wizard = SetupWizard.new(output: output)

        wizard.display_api_key_instructions("anthropic")
        text = output.string

        assert_match(/ANTHROPIC_API_KEY is set/, text)
        refute_match(/export/, text)
      end

      test "display_api_key_instructions shows export instructions when env var missing" do
        output = StringIO.new
        wizard = SetupWizard.new(output: output)
        ENV["SHELL"] = "/bin/zsh"

        wizard.display_api_key_instructions("anthropic")
        text = output.string

        assert_match(/ANTHROPIC_API_KEY is not set/, text)
        assert_match(/export ANTHROPIC_API_KEY/, text)
        assert_match(/~\/\.zshrc/, text)
        assert_match(/source/, text)
      end

      test "display_api_key_instructions shows openai env var for openai provider" do
        output = StringIO.new
        wizard = SetupWizard.new(output: output)

        wizard.display_api_key_instructions("openai")
        text = output.string

        assert_match(/OPENAI_API_KEY is not set/, text)
        assert_match(/export OPENAI_API_KEY/, text)
      end

      test "display_api_key_instructions shows openrouter env var for openrouter provider" do
        output = StringIO.new
        wizard = SetupWizard.new(output: output)

        wizard.display_api_key_instructions("openrouter")
        text = output.string

        assert_match(/OPENROUTER_API_KEY is not set/, text)
        assert_match(/export OPENROUTER_API_KEY/, text)
      end

      test "display_api_key_instructions detects bash profile" do
        ENV["SHELL"] = "/bin/bash"
        output = StringIO.new
        wizard = SetupWizard.new(output: output)

        wizard.display_api_key_instructions("anthropic")
        text = output.string

        assert_match(/\.bash/, text)
      end

      test "display_api_key_instructions does nothing for nil provider" do
        output = StringIO.new
        wizard = SetupWizard.new(output: output)

        wizard.display_api_key_instructions(nil)
        assert_empty output.string
      end

      # --- Display ---

      test "display_header shows first-time message when no config exists" do
        output = StringIO.new
        wizard = SetupWizard.new(output: output)

        SetupWizard.stubs(:config_path).returns("/tmp/nonexistent_#{SecureRandom.hex(4)}/config.yml")
        settings = [
          SetupWizard::Setting.new(key: :llm_provider, label: "Provider", value: nil, source: :missing)
        ]

        wizard.display_header(settings)
        text = output.string

        assert_match(/Arnold Pipeline Setup/, text)
        assert_match(/0 settings, 1 need your input/, text)
        refute_match(/Existing config/, text)
      end

      test "display_header shows reconfigure message when config exists" do
        config_dir = File.join(Dir.tmpdir, "arnold_header_test_#{SecureRandom.hex(4)}")
        config_path = File.join(config_dir, "config.yml")
        FileUtils.mkdir_p(config_dir)
        File.write(config_path, YAML.dump("llm_provider" => "anthropic"))

        SetupWizard.stubs(:config_path).returns(config_path)

        output = StringIO.new
        wizard = SetupWizard.new(output: output)
        settings = [
          SetupWizard::Setting.new(key: :llm_provider, label: "Provider", value: "anthropic", source: :config_file)
        ]

        wizard.display_header(settings)
        text = output.string

        assert_match(/Existing config found/, text)
        assert_match(/All settings detected automatically/, text)
      ensure
        FileUtils.rm_rf(config_dir)
      end

      test "display_summary shows friendly labels with config keys and sources" do
        output = StringIO.new
        wizard = SetupWizard.new(output: output)

        settings = [
          SetupWizard::Setting.new(key: :llm_provider, label: "Planning AI (llm_provider)", value: "anthropic", source: :env_detected),
          SetupWizard::Setting.new(key: :max_iterations, label: "Feedback rounds (max_iterations)", value: "3", source: :default)
        ]

        wizard.display_summary(settings)
        text = output.string

        assert_match(/Planning AI/, text)
        assert_match(/llm_provider/, text)
        assert_match(/anthropic/, text)
        assert_match(/from environment/, text)
        assert_match(/Feedback rounds/, text)
        assert_match(/max_iterations/, text)
        assert_match(/\(default\)/, text)
      end

      # --- Config writing ---

      test "write_config! saves settings to yaml file without api key" do
        config_dir = File.join(Dir.tmpdir, "arnold_write_test_#{SecureRandom.hex(4)}")
        config_path = File.join(config_dir, "config.yml")

        SetupWizard.stubs(:config_path).returns(config_path)

        output = StringIO.new
        wizard = SetupWizard.new(output: output)

        settings = [
          SetupWizard::Setting.new(key: :llm_provider, label: "LLM provider", value: "anthropic", source: :env_detected),
          SetupWizard::Setting.new(key: :llm_model, label: "Model", value: "claude-sonnet-4-6", source: :default),
          SetupWizard::Setting.new(key: :execution_provider, label: "Execution provider", value: "claude_code", source: :default),
          SetupWizard::Setting.new(key: :claude_code_repo_path, label: "Repository path", value: "/tmp/repo", source: :git_root),
          SetupWizard::Setting.new(key: :claude_code_cli, label: "Claude Code CLI", value: "1.0.0", source: :detected),
          SetupWizard::Setting.new(key: :max_iterations, label: "Max iterations", value: "3", source: :default),
          SetupWizard::Setting.new(key: :claude_code_max_budget_usd, label: "Budget limit (USD)", value: "unlimited", source: :default)
        ]

        wizard.send(:write_config!, settings)

        assert File.exist?(config_path)
        content = File.read(config_path)

        # Verify comment header is present
        assert_match(/Arnold Pipeline Configuration/, content)
        assert_match(/ANTHROPIC_API_KEY/, content)
        assert_match(/Do not add your API key to this file/, content)
        assert_match(/arnold doctor/, content)

        # Verify YAML body is parseable and correct
        saved = YAML.safe_load_file(config_path, symbolize_names: true, permitted_classes: [Symbol])
        assert_equal "anthropic", saved[:llm_provider]
        assert_equal "claude-sonnet-4-6", saved[:llm_model]
        assert_equal "claude_code", saved[:execution_provider]
        assert_equal "/tmp/repo", saved[:claude_code_repo_path]
        assert_equal 3, saved[:max_iterations]
        assert_nil saved[:claude_code_max_budget_usd]
        assert_nil saved[:llm_api_key], "API key must not be written to config file"
        assert_nil saved[:claude_code_cli]
      ensure
        FileUtils.rm_rf(config_dir)
      end

      test "write_config! sets file permissions to 0600" do
        config_dir = File.join(Dir.tmpdir, "arnold_perms_test_#{SecureRandom.hex(4)}")
        config_path = File.join(config_dir, "config.yml")

        SetupWizard.stubs(:config_path).returns(config_path)

        output = StringIO.new
        wizard = SetupWizard.new(output: output)

        settings = [
          SetupWizard::Setting.new(key: :llm_provider, label: "LLM provider", value: "anthropic", source: :default)
        ]

        wizard.send(:write_config!, settings)

        mode = File.stat(config_path).mode & 0o777
        assert_equal 0o600, mode, "Config file should have 0600 permissions"
      ensure
        FileUtils.rm_rf(config_dir)
      end

      test "write_config! uses openai env var in comments for openai provider" do
        config_dir = File.join(Dir.tmpdir, "arnold_openai_test_#{SecureRandom.hex(4)}")
        config_path = File.join(config_dir, "config.yml")

        SetupWizard.stubs(:config_path).returns(config_path)

        output = StringIO.new
        wizard = SetupWizard.new(output: output)

        settings = [
          SetupWizard::Setting.new(key: :llm_provider, label: "LLM provider", value: "openai", source: :user_input)
        ]

        wizard.send(:write_config!, settings)

        content = File.read(config_path)
        assert_match(/OPENAI_API_KEY/, content)
      ensure
        FileUtils.rm_rf(config_dir)
      end

      test "write_config! uses openrouter env var in comments for openrouter provider" do
        config_dir = File.join(Dir.tmpdir, "arnold_openrouter_test_#{SecureRandom.hex(4)}")
        config_path = File.join(config_dir, "config.yml")

        SetupWizard.stubs(:config_path).returns(config_path)

        output = StringIO.new
        wizard = SetupWizard.new(output: output)

        settings = [
          SetupWizard::Setting.new(key: :llm_provider, label: "LLM provider", value: "openrouter", source: :user_input)
        ]

        wizard.send(:write_config!, settings)

        content = File.read(config_path)
        assert_match(/OPENROUTER_API_KEY/, content)
      ensure
        FileUtils.rm_rf(config_dir)
      end

      test "write_config! saves budget as float when set" do
        config_dir = File.join(Dir.tmpdir, "arnold_budget_test_#{SecureRandom.hex(4)}")
        config_path = File.join(config_dir, "config.yml")

        SetupWizard.stubs(:config_path).returns(config_path)

        output = StringIO.new
        wizard = SetupWizard.new(output: output)

        settings = [
          SetupWizard::Setting.new(key: :llm_provider, label: "LLM provider", value: "anthropic", source: :default),
          SetupWizard::Setting.new(key: :claude_code_max_budget_usd, label: "Budget", value: "$10", source: :user_input),
          SetupWizard::Setting.new(key: :max_iterations, label: "Iterations", value: "5", source: :user_input)
        ]

        wizard.send(:write_config!, settings)

        saved = YAML.safe_load_file(config_path, symbolize_names: true)
        assert_equal 10.0, saved[:claude_code_max_budget_usd]
        assert_equal 5, saved[:max_iterations]
      ensure
        FileUtils.rm_rf(config_dir)
      end

      # --- Next steps ---

      test "display_next_steps shows arnold doctor when api key is missing" do
        output = StringIO.new
        wizard = SetupWizard.new(output: output)

        settings = [
          SetupWizard::Setting.new(key: :llm_provider, label: "LLM provider", value: "anthropic", source: :user_input)
        ]

        wizard.send(:display_next_steps, settings)
        text = output.string

        assert_match(/arnold doctor/, text)
        assert_match(/Almost there/, text)
        refute_match(/arnold run "Build/, text)
      end

      test "display_next_steps shows arnold run when api key is present" do
        ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"
        output = StringIO.new
        wizard = SetupWizard.new(output: output)

        settings = [
          SetupWizard::Setting.new(key: :llm_provider, label: "LLM provider", value: "anthropic", source: :env_detected)
        ]

        wizard.send(:display_next_steps, settings)
        text = output.string

        assert_match(/arnold run/, text)
        assert_match(/You're ready/, text)
      end

      test "display_next_steps shows config edit instructions" do
        output = StringIO.new
        wizard = SetupWizard.new(output: output)

        settings = [
          SetupWizard::Setting.new(key: :llm_provider, label: "LLM provider", value: "anthropic", source: :default)
        ]

        wizard.send(:display_next_steps, settings)
        text = output.string

        assert_match(/arnold setup/, text)
        assert_match(/config\.yml/, text)
      end

      # --- Source formatting ---

      test "format_source returns readable labels" do
        wizard = SetupWizard.new(output: StringIO.new)

        assert_equal "(from config file)", wizard.send(:format_source, :config_file)
        assert_equal "(from environment)", wizard.send(:format_source, :env_detected)
        assert_equal "(detected)", wizard.send(:format_source, :detected)
        assert_equal "(git root)", wizard.send(:format_source, :git_root)
        assert_equal "(default)", wizard.send(:format_source, :default)
        assert_equal "(set by you)", wizard.send(:format_source, :user_input)
        assert_equal "", wizard.send(:format_source, :missing)
      end

      # --- prompt_for_missing! ---

      test "prompt_for_missing! skips detected settings" do
        output = StringIO.new
        mock_prompt = mock("prompt")
        wizard = SetupWizard.new(output: output, prompt: mock_prompt)

        settings = [
          SetupWizard::Setting.new(key: :llm_provider, label: "Provider", value: "anthropic", source: :env_detected)
        ]

        result = wizard.prompt_for_missing!(settings)
        assert_equal "anthropic", result.first.value
        assert_equal :env_detected, result.first.source
      end

      test "prompt_for_missing! prompts for missing provider" do
        output = StringIO.new
        mock_prompt = mock("prompt")
        mock_prompt.expects(:select).with("Which AI should handle planning and analysis?", %w[Anthropic OpenAI OpenRouter]).returns("OpenAI")

        wizard = SetupWizard.new(output: output, prompt: mock_prompt)

        settings = [
          SetupWizard::Setting.new(key: :llm_provider, label: "Planning AI (llm_provider)", value: nil, source: :missing)
        ]

        result = wizard.prompt_for_missing!(settings)
        assert_equal "openai", result.first.value
        assert_equal :user_input, result.first.source
      end

      # --- Friendly labels ---

      test "detect_settings uses friendly labels with config keys" do
        ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"
        SetupWizard.stubs(:config_path).returns("/tmp/nonexistent_#{SecureRandom.hex(4)}/config.yml")
        wizard = SetupWizard.new(output: StringIO.new)
        wizard.stubs(:claude_code_installed?).returns(false)
        wizard.stubs(:detect_git_root).returns("/tmp/repo")
        settings = wizard.detect_settings

        labels = settings.map(&:label)
        assert labels.any? { |l| l.include?("Planning AI") && l.include?("llm_provider") }
        assert labels.any? { |l| l.include?("AI model") && l.include?("llm_model") }
        assert labels.any? { |l| l.include?("Code engine") && l.include?("execution_provider") }
        assert labels.any? { |l| l.include?("Target repo") && l.include?("claude_code_repo_path") }
        assert labels.any? { |l| l.include?("Feedback rounds") && l.include?("max_iterations") }
        assert labels.any? { |l| l.include?("Cost limit") && l.include?("claude_code_max_budget_usd") }
      end

      # --- reconcile_model_with_provider ---

      test "model updates to gpt-5-mini-2025-08-07 when provider changes to openai" do
        wizard = SetupWizard.new(output: StringIO.new)

        settings = [
          SetupWizard::Setting.new(key: :llm_provider, label: "Planning AI (llm_provider)", value: "openai", source: :user_input),
          SetupWizard::Setting.new(key: :llm_model, label: "AI model (llm_model)", value: "claude-sonnet-4-6", source: :default)
        ]

        result = wizard.send(:reconcile_model_with_provider, settings)
        model = result.find { |s| s.key == :llm_model }
        assert_equal "gpt-5-mini-2025-08-07", model.value
        assert_equal :default, model.source
      end

      test "model updates to claude-sonnet-4-6 when provider changes to anthropic" do
        wizard = SetupWizard.new(output: StringIO.new)

        settings = [
          SetupWizard::Setting.new(key: :llm_provider, label: "Planning AI (llm_provider)", value: "anthropic", source: :user_input),
          SetupWizard::Setting.new(key: :llm_model, label: "AI model (llm_model)", value: "gpt-5-mini-2025-08-07", source: :default)
        ]

        result = wizard.send(:reconcile_model_with_provider, settings)
        model = result.find { |s| s.key == :llm_model }
        assert_equal "claude-sonnet-4-6", model.value
        assert_equal :default, model.source
      end

      test "model is not changed when source is config_file" do
        wizard = SetupWizard.new(output: StringIO.new)

        settings = [
          SetupWizard::Setting.new(key: :llm_provider, label: "Planning AI (llm_provider)", value: "openai", source: :user_input),
          SetupWizard::Setting.new(key: :llm_model, label: "AI model (llm_model)", value: "claude-sonnet-4-6", source: :config_file)
        ]

        result = wizard.send(:reconcile_model_with_provider, settings)
        model = result.find { |s| s.key == :llm_model }
        assert_equal "claude-sonnet-4-6", model.value
        assert_equal :config_file, model.source
      end

      test "model is not changed when source is user_input" do
        wizard = SetupWizard.new(output: StringIO.new)

        settings = [
          SetupWizard::Setting.new(key: :llm_provider, label: "Planning AI (llm_provider)", value: "openai", source: :user_input),
          SetupWizard::Setting.new(key: :llm_model, label: "AI model (llm_model)", value: "claude-sonnet-4-6", source: :user_input)
        ]

        result = wizard.send(:reconcile_model_with_provider, settings)
        model = result.find { |s| s.key == :llm_model }
        assert_equal "claude-sonnet-4-6", model.value
        assert_equal :user_input, model.source
      end

      test "reconcile is no-op when provider is nil" do
        wizard = SetupWizard.new(output: StringIO.new)

        settings = [
          SetupWizard::Setting.new(key: :llm_model, label: "AI model (llm_model)", value: "claude-sonnet-4-6", source: :default)
        ]

        result = wizard.send(:reconcile_model_with_provider, settings)
        assert_equal settings, result
      end

      test "reconcile is no-op when model setting is absent" do
        wizard = SetupWizard.new(output: StringIO.new)

        settings = [
          SetupWizard::Setting.new(key: :llm_provider, label: "Planning AI (llm_provider)", value: "openai", source: :user_input)
        ]

        result = wizard.send(:reconcile_model_with_provider, settings)
        assert_equal settings, result
      end

      # --- reconcile after edit_setting ---

      test "editing provider in confirm_and_save reconciles the model" do
        config_dir = File.join(Dir.tmpdir, "arnold_edit_reconcile_#{SecureRandom.hex(4)}")
        config_path = File.join(config_dir, "config.yml")
        SetupWizard.stubs(:config_path).returns(config_path)

        output = StringIO.new
        mock_prompt = mock("prompt")
        wizard = SetupWizard.new(output: output, prompt: mock_prompt)

        # First call: user picks "Edit a setting", selects provider, changes to OpenAI
        # Second call: user picks "Save"
        mock_prompt.expects(:select).with("Save this configuration?", cycle: true).twice.yields(
          stub(choice: nil)
        ).returns(:edit, :save)

        # edit_setting: user selects provider (index 0), then picks OpenAI
        mock_prompt.expects(:select).with("Which setting to edit?", anything, cycle: true).returns(0)
        mock_prompt.expects(:select).with("Which AI should handle planning and analysis?", %w[Anthropic OpenAI OpenRouter]).returns("OpenAI")

        settings = [
          SetupWizard::Setting.new(key: :llm_provider, label: "Planning AI (llm_provider)", value: "anthropic", source: :env_detected),
          SetupWizard::Setting.new(key: :llm_model, label: "AI model (llm_model)", value: "claude-sonnet-4-6", source: :default)
        ]

        result = wizard.confirm_and_save!(settings)
        model = result.find { |s| s.key == :llm_model }
        assert_equal "gpt-5-mini-2025-08-07", model.value
      ensure
        FileUtils.rm_rf(config_dir)
      end

      # --- integration: run! reconciles model after provider prompt ---

      test "run! saves correct model when user selects different provider during prompt" do
        config_dir = File.join(Dir.tmpdir, "arnold_run_integration_#{SecureRandom.hex(4)}")
        config_path = File.join(config_dir, "config.yml")
        SetupWizard.stubs(:config_path).returns(config_path)

        output = StringIO.new
        mock_prompt = mock("prompt")
        wizard = SetupWizard.new(output: output, prompt: mock_prompt)

        # Detection: anthropic env detected, so provider is set, but model defaults to claude
        ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"
        wizard.stubs(:claude_code_installed?).returns(false)
        wizard.stubs(:detect_git_root).returns("/tmp/repo")

        # prompt_for_missing! has no missing settings (provider auto-detected), so no prompts
        # But we need to simulate the user choosing to edit provider to openai
        # Actually, let's simulate both env vars set so provider is missing
        ENV["OPENAI_API_KEY"] = "sk-test"

        # prompt_for_missing! will prompt for provider since both env vars are set
        mock_prompt.expects(:select).with("Which AI should handle planning and analysis?", %w[Anthropic OpenAI OpenRouter]).returns("OpenAI")

        # confirm_and_save! — user saves immediately
        mock_prompt.expects(:select).with("Save this configuration?", cycle: true).yields(
          stub(choice: nil)
        ).returns(:save)

        wizard.run!

        saved = YAML.safe_load_file(config_path, symbolize_names: true)
        assert_equal "openai", saved[:llm_provider]
        assert_equal "gpt-5-mini-2025-08-07", saved[:llm_model], "Model should be gpt-5-mini-2025-08-07 after user selected OpenAI provider"
      ensure
        FileUtils.rm_rf(config_dir)
      end

      # --- Shell profile detection ---

      test "detect_shell_profile returns zshrc for zsh" do
        ENV["SHELL"] = "/bin/zsh"
        wizard = SetupWizard.new(output: StringIO.new)
        assert_equal "~/.zshrc", wizard.send(:detect_shell_profile)
      end

      test "detect_shell_profile returns bashrc for bash" do
        ENV["SHELL"] = "/bin/bash"
        wizard = SetupWizard.new(output: StringIO.new)
        # Will return either .bash_profile or .bashrc depending on what exists
        profile = wizard.send(:detect_shell_profile)
        assert_match(/\.bash/, profile)
      end

      test "detect_shell_profile returns profile for unknown shell" do
        ENV["SHELL"] = "/bin/fish"
        wizard = SetupWizard.new(output: StringIO.new)
        assert_equal "~/.profile", wizard.send(:detect_shell_profile)
      end
    end
  end
end
