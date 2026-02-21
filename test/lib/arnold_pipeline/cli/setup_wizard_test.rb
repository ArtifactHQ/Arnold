require "test_helper"
require "arnold_pipeline/cli/setup_wizard"

module ArnoldPipeline
  module CliModule
    class SetupWizardTest < ActiveSupport::TestCase
      setup do
        ArnoldPipeline.reset_configuration!
        @original_anthropic = ENV["ANTHROPIC_API_KEY"]
        @original_openai = ENV["OPENAI_API_KEY"]
        ENV.delete("ANTHROPIC_API_KEY")
        ENV.delete("OPENAI_API_KEY")
      end

      teardown do
        ENV["ANTHROPIC_API_KEY"] = @original_anthropic if @original_anthropic
        ENV["OPENAI_API_KEY"] = @original_openai if @original_openai
        ArnoldPipeline.reset_configuration!
      end

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

      test "api_key_available? returns false when no key is available" do
        refute SetupWizard.api_key_available?
      end

      test "prompt_and_configure! sets api key on configuration" do
        mock_prompt = mock("prompt")
        mock_prompt.expects(:select).with("Which LLM provider?", %w[Anthropic OpenAI]).returns("Anthropic")
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
    end
  end
end
