require "test_helper"
require "arnold_pipeline/cli/doctor"

module ArnoldPipeline
  module CliModule
    class DoctorTest < ActiveSupport::TestCase
      setup do
        @original_anthropic = ENV["ANTHROPIC_API_KEY"]
        @original_openai = ENV["OPENAI_API_KEY"]
        @original_openrouter = ENV["OPENROUTER_API_KEY"]
      end

      teardown do
        if @original_anthropic
          ENV["ANTHROPIC_API_KEY"] = @original_anthropic
        else
          ENV.delete("ANTHROPIC_API_KEY")
        end
        if @original_openai
          ENV["OPENAI_API_KEY"] = @original_openai
        else
          ENV.delete("OPENAI_API_KEY")
        end
        if @original_openrouter
          ENV["OPENROUTER_API_KEY"] = @original_openrouter
        else
          ENV.delete("OPENROUTER_API_KEY")
        end
        ArnoldPipeline.reset_configuration!
      end

      # 1. Check data object stores name, status, message, fix (fix defaults to nil)
      test "Check stores name, status, message, and fix" do
        check = Doctor::Check.new(name: "Ruby", status: :pass, message: "4.0.0")
        assert_equal "Ruby", check.name
        assert_equal :pass, check.status
        assert_equal "4.0.0", check.message
        assert_nil check.fix
      end

      test "Check stores fix when provided" do
        check = Doctor::Check.new(name: "Git", status: :fail, message: "not found", fix: "Install git")
        assert_equal "Install git", check.fix
      end

      test "Check is immutable Data object" do
        check = Doctor::Check.new(name: "Ruby", status: :pass, message: "4.0.0")
        assert_kind_of Data, check
        assert check.frozen?
      end

      # 2. check_ruby returns :pass (we're on Ruby 4.0)
      test "check_ruby returns pass for current ruby version" do
        result = Doctor.check_ruby
        assert_equal :pass, result.status
        assert_equal "Ruby", result.name
        assert_match(/\d+\.\d+/, result.message)
      end

      # 3. check_git returns :pass (git is available in dev env)
      test "check_git returns pass when git is available" do
        result = Doctor.check_git
        assert_equal :pass, result.status
        assert_equal "Git", result.name
        assert_match(/\d+\.\d+/, result.message)
      end

      test "check_git returns fail when git is not found" do
        Doctor.stubs(:command_version).with("git --version").returns(nil)
        result = Doctor.check_git
        assert_equal :fail, result.status
        assert_equal "not found", result.message
        assert result.fix
      end

      # 4. check_api_keys scenarios
      test "check_api_keys returns pass when ANTHROPIC_API_KEY set" do
        ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"
        ENV.delete("OPENAI_API_KEY")
        result = Doctor.check_api_keys
        assert_equal :pass, result.status
        assert_match(/ANTHROPIC_API_KEY/, result.message)
      end

      test "check_api_keys returns pass when OPENAI_API_KEY set" do
        ENV.delete("ANTHROPIC_API_KEY")
        ENV["OPENAI_API_KEY"] = "sk-test"
        ENV.delete("OPENROUTER_API_KEY")
        result = Doctor.check_api_keys
        assert_equal :pass, result.status
        assert_match(/OPENAI_API_KEY/, result.message)
      end

      test "check_api_keys returns pass when OPENROUTER_API_KEY set" do
        ENV.delete("ANTHROPIC_API_KEY")
        ENV.delete("OPENAI_API_KEY")
        ENV["OPENROUTER_API_KEY"] = "sk-or-test"
        result = Doctor.check_api_keys
        assert_equal :pass, result.status
        assert_match(/OPENROUTER_API_KEY/, result.message)
      end

      test "check_api_keys prefers ANTHROPIC_API_KEY when both set" do
        ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"
        ENV["OPENAI_API_KEY"] = "sk-test"
        result = Doctor.check_api_keys
        assert_equal :pass, result.status
        assert_match(/ANTHROPIC_API_KEY/, result.message)
      end

      test "check_api_keys returns pass when configured via config file" do
        ENV.delete("ANTHROPIC_API_KEY")
        ENV.delete("OPENAI_API_KEY")
        ENV.delete("OPENROUTER_API_KEY")
        ArnoldPipeline.configure { |c| c.llm_api_key = "some-key" }
        result = Doctor.check_api_keys
        assert_equal :pass, result.status
        assert_match(/config file/, result.message)
      end

      test "check_api_keys returns fail when no key set" do
        ENV.delete("ANTHROPIC_API_KEY")
        ENV.delete("OPENAI_API_KEY")
        ENV.delete("OPENROUTER_API_KEY")
        ArnoldPipeline.reset_configuration!
        result = Doctor.check_api_keys
        assert_equal :fail, result.status
        assert result.fix
      end

      test "check_api_keys treats empty string as missing" do
        ENV["ANTHROPIC_API_KEY"] = ""
        ENV.delete("OPENAI_API_KEY")
        ENV.delete("OPENROUTER_API_KEY")
        ArnoldPipeline.reset_configuration!
        result = Doctor.check_api_keys
        assert_equal :fail, result.status
      end

      # 5. check_sqlite returns :pass (sqlite3 is available)
      test "check_sqlite returns pass when sqlite3 available" do
        result = Doctor.check_sqlite
        assert_equal :pass, result.status
        assert_equal "SQLite3", result.name
      end

      test "check_sqlite returns fail when sqlite3 not found" do
        Doctor.stubs(:command_version).with("sqlite3 --version").returns(nil)
        result = Doctor.check_sqlite
        assert_equal :fail, result.status
        assert result.fix
      end

      # 6. check_node returns :pass or :warn or :skip based on availability
      test "check_node returns pass, warn, or skip based on availability" do
        result = Doctor.check_node
        assert_includes [ :pass, :warn, :skip ], result.status
        assert_equal "Node.js", result.name
      end

      test "check_node returns pass for node >= 18" do
        Doctor.stubs(:command_version).with("node --version").returns("v22.5.0")
        result = Doctor.check_node
        assert_equal :pass, result.status
        assert_equal "22.5.0", result.message
      end

      test "check_node returns warn for node < 18" do
        Doctor.stubs(:command_version).with("node --version").returns("v16.20.0")
        result = Doctor.check_node
        assert_equal :warn, result.status
        assert_match(/recommend/, result.message)
        assert result.fix
      end

      test "check_node returns skip when node not found" do
        Doctor.stubs(:command_version).with("node --version").returns(nil)
        result = Doctor.check_node
        assert_equal :skip, result.status
        assert_match(/optional/, result.message)
      end

      # 7. check_openspec returns :pass or :skip
      test "check_openspec returns pass or skip" do
        result = Doctor.check_openspec
        assert_includes [ :pass, :skip ], result.status
        assert_equal "OpenSpec CLI", result.name
      end

      test "check_openspec returns pass when openspec is available" do
        Doctor.stubs(:command_version).with("openspec --version").returns("1.2.3")
        result = Doctor.check_openspec
        assert_equal :pass, result.status
        assert_equal "1.2.3", result.message
      end

      test "check_openspec returns skip when openspec not found" do
        Doctor.stubs(:command_version).with("openspec --version").returns(nil)
        result = Doctor.check_openspec
        assert_equal :skip, result.status
        assert result.fix
      end

      test "check_openspec uses configured cli path" do
        ArnoldPipeline.configure { |c| c.openspec_cli_path = "/custom/openspec" }
        Doctor.stubs(:command_version).with("/custom/openspec --version").returns("2.0.0")
        result = Doctor.check_openspec
        assert_equal :pass, result.status
        assert_equal "2.0.0", result.message
      end

      # 8. check_claude_code returns :pass or :skip
      test "check_claude_code returns pass or skip" do
        result = Doctor.check_claude_code
        assert_includes [ :pass, :skip ], result.status
        assert_equal "Claude Code CLI", result.name
      end

      test "check_claude_code returns pass when claude is available" do
        Doctor.stubs(:command_version).with("claude --version").returns("1.0.5")
        result = Doctor.check_claude_code
        assert_equal :pass, result.status
        assert_equal "1.0.5", result.message
      end

      test "check_claude_code returns skip when claude not found" do
        Doctor.stubs(:command_version).with("claude --version").returns(nil)
        result = Doctor.check_claude_code
        assert_equal :skip, result.status
        assert_match(/optional/, result.message)
      end

      # 9. run_all returns array of Check results with >= 7 items
      test "run_all returns array of Check results" do
        ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"
        results = Doctor.run_all
        assert_kind_of Array, results
        assert results.all? { |r| r.is_a?(Doctor::Check) }
        assert results.length >= 7
      end

      test "run_all includes all expected check names" do
        ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"
        results = Doctor.run_all
        names = results.map(&:name)
        assert_includes names, "Ruby"
        assert_includes names, "Git"
        assert_includes names, "API key"
        assert_includes names, "SQLite3"
        assert_includes names, "Node.js"
        assert_includes names, "OpenSpec CLI"
        assert_includes names, "Claude Code CLI"
      end

      # 10. all_required_passed? returns true when ruby/git/api_keys/sqlite pass
      test "all_required_passed? returns true when required checks pass" do
        results = [
          Doctor::Check.new(name: "Ruby", status: :pass, message: "4.0.0"),
          Doctor::Check.new(name: "Git", status: :pass, message: "2.43.0"),
          Doctor::Check.new(name: "API key", status: :pass, message: "ANTHROPIC_API_KEY configured"),
          Doctor::Check.new(name: "SQLite3", status: :pass, message: "3.45.0"),
          Doctor::Check.new(name: "Node.js", status: :skip, message: "not found"),
          Doctor::Check.new(name: "OpenSpec CLI", status: :skip, message: "not found"),
          Doctor::Check.new(name: "Claude Code CLI", status: :skip, message: "not found")
        ]
        assert Doctor.all_required_passed?(results)
      end

      test "all_required_passed? returns false when a required check fails" do
        results = [
          Doctor::Check.new(name: "Ruby", status: :pass, message: "4.0.0"),
          Doctor::Check.new(name: "Git", status: :pass, message: "2.43.0"),
          Doctor::Check.new(name: "API key", status: :fail, message: "no API key found"),
          Doctor::Check.new(name: "SQLite3", status: :pass, message: "3.45.0")
        ]
        refute Doctor.all_required_passed?(results)
      end

      test "all_required_passed? ignores optional check failures" do
        results = [
          Doctor::Check.new(name: "Ruby", status: :pass, message: "4.0.0"),
          Doctor::Check.new(name: "Git", status: :pass, message: "2.43.0"),
          Doctor::Check.new(name: "API key", status: :pass, message: "configured"),
          Doctor::Check.new(name: "SQLite3", status: :pass, message: "3.45.0"),
          Doctor::Check.new(name: "Node.js", status: :skip, message: "not found"),
          Doctor::Check.new(name: "OpenSpec CLI", status: :skip, message: "not found")
        ]
        assert Doctor.all_required_passed?(results)
      end

      test "all_required_passed? returns true with warn status on required check" do
        results = [
          Doctor::Check.new(name: "Ruby", status: :warn, message: "3.1.0"),
          Doctor::Check.new(name: "Git", status: :pass, message: "2.43.0"),
          Doctor::Check.new(name: "API key", status: :pass, message: "configured"),
          Doctor::Check.new(name: "SQLite3", status: :pass, message: "3.45.0")
        ]
        assert Doctor.all_required_passed?(results)
      end

      # command_version edge cases
      test "command_version returns nil for nonexistent command" do
        result = Doctor.command_version("nonexistent_command_12345 --version")
        assert_nil result
      end

      test "command_version returns output for valid command" do
        result = Doctor.command_version("ruby --version")
        assert_kind_of String, result
        assert_match(/ruby/i, result)
      end

      # REQUIRED_CHECKS constant
      test "REQUIRED_CHECKS includes expected symbols" do
        assert_equal %i[ruby git api_key sqlite], Doctor::REQUIRED_CHECKS
      end
    end
  end
end
