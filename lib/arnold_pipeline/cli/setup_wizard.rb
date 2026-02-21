require "tty-prompt"
require "yaml"
require "fileutils"

module ArnoldPipeline
  module CliModule
    class SetupWizard
      CONFIG_DIR = File.expand_path("~/.arnold_pipeline")
      CONFIG_PATH = File.join(CONFIG_DIR, "config.yml")

      def self.api_key_available?
        return true if ArnoldPipeline.configuration.instance_variable_get(:@llm_api_key)&.then { |k| !k.empty? }
        return true if ENV["ANTHROPIC_API_KEY"]&.then { |k| !k.empty? }
        return true if ENV["OPENAI_API_KEY"]&.then { |k| !k.empty? }
        false
      end

      def self.prompt_and_configure!
        prompt = TTY::Prompt.new

        provider_name = prompt.select("Which LLM provider?", %w[Anthropic OpenAI])
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
    end
  end
end
