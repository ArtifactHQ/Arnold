require "tty-prompt"
require "yaml"
require "fileutils"

module ArnoldPipeline
  module CliModule
    class SetupWizard
      CONFIG_DIR = File.expand_path("~/.arnold_pipeline")
      CONFIG_PATH = File.join(CONFIG_DIR, "config.yml")

      ENV_VAR_NAMES = {
        "anthropic" => "ANTHROPIC_API_KEY",
        "openai" => "OPENAI_API_KEY",
        "openrouter" => "OPENROUTER_API_KEY"
      }.freeze

      Setting = Data.define(:key, :label, :value, :source) do
        def detected? = source != :missing
        def mask_value
          return "(not set)" unless value
          value
        end
      end

      def self.api_key_available?
        return true if ArnoldPipeline.configuration.instance_variable_get(:@llm_api_key)&.then { |k| !k.empty? }
        return true if ENV["ANTHROPIC_API_KEY"]&.then { |k| !k.empty? }
        return true if ENV["OPENAI_API_KEY"]&.then { |k| !k.empty? }
        return true if ENV["OPENROUTER_API_KEY"]&.then { |k| !k.empty? }
        false
      end

      def self.prompt_and_configure!
        prompt = TTY::Prompt.new

        provider_name = prompt.select("Which LLM provider?", %w[Anthropic OpenAI OpenRouter])
        provider = provider_name.downcase.to_sym

        api_key = prompt.mask("Enter your #{provider_name} API key:")

        ArnoldPipeline.configure do |c|
          c.llm_provider = provider
          c.llm_api_key = api_key
        end

        if prompt.yes?("Save to ~/.arnold_pipeline/config.yml for future use?")
          save_config!(provider:, api_key:)
        end
      end

      def self.config_path
        CONFIG_PATH
      end

      def self.save_config!(provider:, api_key:)
        path = config_path
        dir = File.dirname(path)
        FileUtils.mkdir_p(dir)

        existing = if File.exist?(path)
          YAML.safe_load_file(path, symbolize_names: true) || {}
        else
          {}
        end

        existing[:llm_provider] = provider.to_s
        existing[:llm_api_key] = api_key

        File.write(path, YAML.dump(existing.transform_keys(&:to_s)))
      end

      # --- Full interactive setup ---

      def initialize(output: $stdout, prompt: nil)
        @output = output
        @prompt = prompt || TTY::Prompt.new(output: @output)
      end

      def run!
        settings = detect_settings
        display_header(settings)
        settings = prompt_for_missing!(settings)
        settings = reconcile_model_with_provider(settings)
        provider_name = settings.find { |s| s.key == :llm_provider }&.value
        display_api_key_instructions(provider_name)
        display_summary(settings)
        confirm_and_save!(settings)
      end

      def detect_settings
        existing_config = load_existing_config
        [
          detect_llm_provider(existing_config),
          detect_llm_model(existing_config),
          detect_execution_provider(existing_config),
          detect_repo_path(existing_config),
          detect_claude_code_cli,
          detect_max_iterations(existing_config),
          detect_max_budget(existing_config)
        ]
      end

      def display_header(settings)
        reconfigure = File.exist?(self.class.config_path)
        missing_count = settings.count { |s| !s.detected? }

        @output.puts ""
        @output.puts "  Arnold Pipeline Setup"
        @output.puts "  " + ("-" * 21)
        @output.puts ""
        if reconfigure
          @output.puts "  Existing config found at #{self.class.config_path}"
          @output.puts ""
        end
        if missing_count > 0
          @output.puts "  Detected #{settings.count - missing_count} settings, #{missing_count} need your input."
        else
          @output.puts "  All settings detected automatically."
        end
        @output.puts ""
      end

      def prompt_for_missing!(settings)
        settings.map do |setting|
          if setting.detected?
            setting
          else
            value = prompt_for_setting(setting)
            Setting.new(key: setting.key, label: setting.label, value: value, source: :user_input)
          end
        end
      end

      def display_api_key_instructions(provider_name)
        return unless provider_name

        env_var = ENV_VAR_NAMES[provider_name]
        return unless env_var

        if env_var_set?(env_var)
          @output.puts "  API key:  #{env_var} is set in your environment."
          @output.puts ""
        else
          shell_profile = detect_shell_profile
          @output.puts "  API key:  #{env_var} is not set."
          @output.puts ""
          @output.puts "  To configure it, add this to #{shell_profile}:"
          @output.puts ""
          @output.puts "    export #{env_var}=\"your-api-key-here\""
          @output.puts ""
          @output.puts "  Then reload your shell:"
          @output.puts ""
          @output.puts "    source #{shell_profile}"
          @output.puts ""
        end
      end

      def display_summary(settings)
        @output.puts "  Configuration:"
        @output.puts ""

        settings.each_with_index do |setting, idx|
          num = (idx + 1).to_s.rjust(2)
          source_label = format_source(setting.source)
          display_label = setting.label
          @output.puts "  #{num}. #{display_label.ljust(40)} #{setting.mask_value.to_s.ljust(30)} #{source_label}"
        end
        @output.puts ""
      end

      def confirm_and_save!(settings)
        loop do
          choice = @prompt.select("Save this configuration?", cycle: true) do |menu|
            menu.choice "Yes, save to #{self.class.config_path}", :save
            menu.choice "Edit a setting", :edit
            menu.choice "Cancel", :cancel
          end

          case choice
          when :save
            write_config!(settings)
            display_next_steps(settings)
            return settings
          when :edit
            settings = edit_setting(settings)
            settings = reconcile_model_with_provider(settings)
            display_summary(settings)
          when :cancel
            @output.puts "  Setup cancelled. No changes were made."
            return nil
          end
        end
      end

      private

      def load_existing_config
        return {} unless File.exist?(self.class.config_path)

        YAML.safe_load_file(self.class.config_path, symbolize_names: true) || {}
      rescue StandardError
        {}
      end

      # --- Detection methods ---

      def detect_llm_provider(existing_config)
        anthropic_set = env_var_set?("ANTHROPIC_API_KEY")
        openai_set = env_var_set?("OPENAI_API_KEY")
        openrouter_set = env_var_set?("OPENROUTER_API_KEY")

        set_count = [anthropic_set, openai_set, openrouter_set].count(true)

        if existing_config[:llm_provider]
          Setting.new(key: :llm_provider, label: "Planning AI (llm_provider)", value: existing_config[:llm_provider], source: :config_file)
        elsif set_count == 1
          if anthropic_set
            Setting.new(key: :llm_provider, label: "Planning AI (llm_provider)", value: "anthropic", source: :env_detected)
          elsif openai_set
            Setting.new(key: :llm_provider, label: "Planning AI (llm_provider)", value: "openai", source: :env_detected)
          else
            Setting.new(key: :llm_provider, label: "Planning AI (llm_provider)", value: "openrouter", source: :env_detected)
          end
        elsif set_count >= 2
          # Multiple are set — we'll ask the user to confirm in prompt_for_missing!
          Setting.new(key: :llm_provider, label: "Planning AI (llm_provider)", value: nil, source: :missing)
        else
          Setting.new(key: :llm_provider, label: "Planning AI (llm_provider)", value: nil, source: :missing)
        end
      end

      def detect_llm_model(existing_config)
        if existing_config[:llm_model]
          Setting.new(key: :llm_model, label: "AI model (llm_model)", value: existing_config[:llm_model], source: :config_file)
        else
          provider = detect_provider_name(existing_config)
          Setting.new(key: :llm_model, label: "AI model (llm_model)", value: default_model_for(provider), source: :default)
        end
      end

      def detect_execution_provider(existing_config)
        if existing_config[:execution_provider]
          Setting.new(key: :execution_provider, label: "Code engine (execution_provider)", value: existing_config[:execution_provider], source: :config_file)
        elsif claude_code_installed?
          Setting.new(key: :execution_provider, label: "Code engine (execution_provider)", value: "claude_code", source: :detected)
        else
          Setting.new(key: :execution_provider, label: "Code engine (execution_provider)", value: "claude_code", source: :default)
        end
      end

      def detect_repo_path(existing_config)
        if existing_config[:claude_code_repo_path]
          Setting.new(key: :claude_code_repo_path, label: "Target repo (claude_code_repo_path)", value: existing_config[:claude_code_repo_path], source: :config_file)
        else
          git_root = detect_git_root
          if git_root
            Setting.new(key: :claude_code_repo_path, label: "Target repo (claude_code_repo_path)", value: git_root, source: :git_root)
          else
            Setting.new(key: :claude_code_repo_path, label: "Target repo (claude_code_repo_path)", value: nil, source: :missing)
          end
        end
      end

      def detect_claude_code_cli
        if claude_code_installed?
          version = `claude --version 2>/dev/null`.strip
          version = version.empty? ? "installed" : version
          Setting.new(key: :claude_code_cli, label: "Claude Code CLI", value: version, source: :detected)
        else
          Setting.new(key: :claude_code_cli, label: "Claude Code CLI", value: "not found", source: :not_installed)
        end
      end

      def detect_max_iterations(existing_config)
        if existing_config[:max_iterations]
          Setting.new(key: :max_iterations, label: "Feedback rounds (max_iterations)", value: existing_config[:max_iterations].to_s, source: :config_file)
        else
          Setting.new(key: :max_iterations, label: "Feedback rounds (max_iterations)", value: "3", source: :default)
        end
      end

      def detect_max_budget(existing_config)
        if existing_config[:claude_code_max_budget_usd]
          Setting.new(key: :claude_code_max_budget_usd, label: "Cost limit (claude_code_max_budget_usd)", value: "$#{existing_config[:claude_code_max_budget_usd]}", source: :config_file)
        else
          Setting.new(key: :claude_code_max_budget_usd, label: "Cost limit (claude_code_max_budget_usd)", value: "unlimited", source: :default)
        end
      end

      # --- Prompt methods ---

      def prompt_for_setting(setting)
        case setting.key
        when :llm_provider
          name = @prompt.select("Which AI should handle planning and analysis?", %w[Anthropic OpenAI OpenRouter])
          name.downcase
        when :claude_code_repo_path
          @prompt.ask("Which repository should Arnold work on?", default: Dir.pwd)
        else
          @prompt.ask("#{setting.label}:")
        end
      end

      def edit_setting(settings)
        choices = settings.each_with_index.filter_map do |setting, idx|
          next if setting.key == :claude_code_cli # not editable

          { name: "#{setting.label} (#{setting.mask_value})", value: idx }
        end

        idx = @prompt.select("Which setting to edit?", choices, cycle: true)
        setting = settings[idx]

        new_value = prompt_for_edit(setting)
        return settings if new_value.nil?

        updated = Setting.new(key: setting.key, label: setting.label, value: new_value, source: :user_input)
        settings.dup.tap { |s| s[idx] = updated }
      end

      def prompt_for_edit(setting)
        case setting.key
        when :llm_provider
          name = @prompt.select("Which AI should handle planning and analysis?", %w[Anthropic OpenAI OpenRouter])
          name.downcase
        when :llm_model
          @prompt.ask("AI model:", default: setting.value)
        when :execution_provider
          @prompt.select("What should write the code?", %w[claude_code github])
        when :claude_code_repo_path
          @prompt.ask("Which repository should Arnold work on?", default: setting.value)
        when :max_iterations
          @prompt.ask("How many feedback rounds? (1-10):", default: setting.value)
        when :claude_code_max_budget_usd
          result = @prompt.ask("Max spend per run in USD (blank for unlimited):", default: nil)
          result.nil? || result.strip.empty? ? "unlimited" : "$#{result.delete('$')}"
        else
          @prompt.ask("#{setting.label}:", default: setting.value)
        end
      end

      # --- Persistence ---

      def write_config!(settings)
        path = self.class.config_path
        FileUtils.mkdir_p(File.dirname(path))

        config = {}
        settings.each do |setting|
          next if setting.key == :claude_code_cli # not a config value

          config[setting.key.to_s] = normalize_value(setting)
        end

        provider_name = config["llm_provider"]
        env_var = ENV_VAR_NAMES[provider_name] || "ANTHROPIC_API_KEY"

        comment_header = <<~COMMENT
          # Arnold Pipeline Configuration
          # Generated by: arnold setup
          #
          # API key is read from environment variable: #{env_var}
          # To set it, add to your shell profile (~/.zshrc or ~/.bashrc):
          #   export #{env_var}="your-api-key-here"
          #
          # Do not add your API key to this file.
          # Run `arnold doctor` to verify your environment.

        COMMENT

        yaml_body = YAML.dump(config)

        File.write(path, comment_header + yaml_body)
        File.chmod(0o600, path)
        @output.puts "  Config saved to #{path}"
      end

      def normalize_value(setting)
        case setting.key
        when :max_iterations
          setting.value.to_i
        when :claude_code_max_budget_usd
          val = setting.value.to_s.delete("$")
          val == "unlimited" ? nil : val.to_f
        else
          setting.value
        end
      end

      def display_next_steps(settings)
        provider_name = settings.find { |s| s.key == :llm_provider }&.value
        env_var = ENV_VAR_NAMES[provider_name] || "ANTHROPIC_API_KEY"
        api_key_present = env_var_set?(env_var)

        @output.puts ""
        if api_key_present
          @output.puts "  You're ready! Run your first pipeline:"
          @output.puts ""
          @output.puts "    arnold run \"Build a REST API for managing bookmarks\""
        else
          @output.puts "  Almost there! Set your API key, then verify your setup:"
          @output.puts ""
          @output.puts "    arnold doctor"
        end
        @output.puts ""
        @output.puts "  To change settings later:"
        @output.puts "    - Edit #{self.class.config_path}"
        @output.puts "    - Or re-run: arnold setup"
        @output.puts ""
      end

      # --- Reconciliation ---

      def reconcile_model_with_provider(settings)
        provider = settings.find { |s| s.key == :llm_provider }&.value
        model_setting = settings.find { |s| s.key == :llm_model }
        return settings unless provider && model_setting
        return settings unless model_setting.source == :default

        expected_model = default_model_for(provider)
        return settings if model_setting.value == expected_model

        updated = Setting.new(key: :llm_model, label: model_setting.label, value: expected_model, source: :default)
        settings.map { |s| s.key == :llm_model ? updated : s }
      end

      def default_model_for(provider_name)
        ArnoldPipeline::Configuration::PROVIDER_DEFAULTS.dig(provider_name.to_sym, :model) || "claude-sonnet-4-6"
      end

      # --- Helpers ---

      def detect_provider_name(existing_config)
        existing_config[:llm_provider]&.to_s ||
          (env_var_set?("ANTHROPIC_API_KEY") ? "anthropic" : nil) ||
          (env_var_set?("OPENAI_API_KEY") ? "openai" : nil) ||
          (env_var_set?("OPENROUTER_API_KEY") ? "openrouter" : nil) ||
          "anthropic"
      end

      def env_var_set?(name)
        ENV[name] && !ENV[name].empty?
      end

      def claude_code_installed?
        system("which claude > /dev/null 2>&1")
      end

      def detect_git_root
        root = `git rev-parse --show-toplevel 2>/dev/null`.strip
        root.empty? ? nil : root
      end

      def detect_shell_profile
        shell = ENV["SHELL"].to_s
        if shell.end_with?("zsh")
          "~/.zshrc"
        elsif shell.end_with?("bash")
          File.exist?(File.expand_path("~/.bash_profile")) ? "~/.bash_profile" : "~/.bashrc"
        else
          "~/.profile"
        end
      end

      def format_source(source)
        case source
        when :config_file then "(from config file)"
        when :env_detected then "(from environment)"
        when :detected then "(detected)"
        when :git_root then "(git root)"
        when :default then "(default)"
        when :user_input then "(set by you)"
        when :not_installed then "(not installed)"
        when :missing then ""
        else "(#{source})"
        end
      end
    end
  end
end
