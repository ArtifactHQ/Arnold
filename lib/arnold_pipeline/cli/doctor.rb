module ArnoldPipeline
  module CliModule
    class Doctor
      Check = Data.define(:name, :status, :message, :fix) do
        def initialize(name:, status:, message:, fix: nil)
          super(name:, status:, message:, fix:)
        end
      end

      REQUIRED_CHECKS = %i[ruby git api_key sqlite].freeze

      def self.run_all
        [
          check_ruby,
          check_git,
          check_api_keys,
          check_sqlite,
          check_node,
          check_openspec,
          check_claude_code
        ]
      end

      def self.all_required_passed?(results)
        results.select { |r| REQUIRED_CHECKS.any? { |name| r.name.downcase.gsub(/\s+/, "_").start_with?(name.to_s) } }
               .none? { |r| r.status == :fail }
      end

      def self.check_ruby
        version = RUBY_VERSION
        if Gem::Version.new(version) >= Gem::Version.new("3.2")
          Check.new(name: "Ruby", status: :pass, message: version)
        elsif Gem::Version.new(version) >= Gem::Version.new("3.0")
          Check.new(name: "Ruby", status: :warn, message: "#{version} — recommend >= 3.2",
                    fix: "Install Ruby 3.2+ via rbenv or asdf")
        else
          Check.new(name: "Ruby", status: :fail, message: "#{version} — requires >= 3.0",
                    fix: "Install Ruby 3.2+ via rbenv or asdf")
        end
      end

      def self.check_git
        version = command_version("git --version")
        if version
          # Extract version number from "git version 2.43.0"
          ver = version[/\d+\.\d+\.\d+/] || version
          Check.new(name: "Git", status: :pass, message: ver)
        else
          Check.new(name: "Git", status: :fail, message: "not found",
                    fix: "Install git: https://git-scm.com/downloads")
        end
      end

      def self.check_api_keys
        if ENV["ANTHROPIC_API_KEY"]&.then { |k| !k.empty? }
          Check.new(name: "API key", status: :pass, message: "ANTHROPIC_API_KEY configured")
        elsif ENV["OPENAI_API_KEY"]&.then { |k| !k.empty? }
          Check.new(name: "API key", status: :pass, message: "OPENAI_API_KEY configured")
        elsif ArnoldPipeline.configuration.instance_variable_get(:@llm_api_key)&.then { |k| !k.empty? }
          Check.new(name: "API key", status: :pass, message: "configured via config file")
        else
          Check.new(name: "API key", status: :fail, message: "no API key found",
                    fix: "export ANTHROPIC_API_KEY=sk-ant-... or run 'arnold run --preview' to set up interactively")
        end
      end

      def self.check_sqlite
        version = command_version("sqlite3 --version")
        if version
          Check.new(name: "SQLite3", status: :pass, message: version.split.first)
        else
          Check.new(name: "SQLite3", status: :fail, message: "not found",
                    fix: "Install sqlite3: apt install sqlite3 / brew install sqlite3")
        end
      end

      def self.check_node
        version = command_version("node --version")
        if version
          major = version.delete_prefix("v").split(".").first.to_i
          if major >= 18
            Check.new(name: "Node.js", status: :pass, message: version.delete_prefix("v"))
          else
            Check.new(name: "Node.js", status: :warn,
                      message: "#{version.delete_prefix('v')} — recommend >= 18 for OpenSpec",
                      fix: "Install Node.js 18+: https://nodejs.org")
          end
        else
          Check.new(name: "Node.js", status: :skip,
                    message: "not found (optional — needed for OpenSpec)")
        end
      end

      def self.check_openspec
        path = ArnoldPipeline.configuration.openspec_cli_path || "openspec"
        version = command_version("#{path} --version")
        if version
          Check.new(name: "OpenSpec CLI", status: :pass, message: version)
        else
          Check.new(name: "OpenSpec CLI", status: :skip,
                    message: "not found (optional — needed for spec merging)",
                    fix: "npm install -g @fission-ai/openspec")
        end
      end

      def self.check_claude_code
        version = command_version("claude --version")
        if version
          Check.new(name: "Claude Code CLI", status: :pass, message: version)
        else
          Check.new(name: "Claude Code CLI", status: :skip,
                    message: "not found (optional — needed for claude_code execution provider)",
                    fix: "npm install -g @anthropic-ai/claude-code")
        end
      end

      def self.command_version(cmd)
        output = `#{cmd} 2>/dev/null`.strip
        output.empty? ? nil : output
      rescue Errno::ENOENT
        nil
      end
    end
  end
end
