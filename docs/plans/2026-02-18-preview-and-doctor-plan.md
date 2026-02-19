# Preview Mode & Doctor Command Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add zero-config `--preview` mode and `arnold doctor` environment health checker to reduce time-to-first-value for new users.

**Architecture:** Two independent features. Phase 1 rewires existing `--preview` to auto-set null provider + stop_after tasks, adds interactive API key prompting via tty-prompt, and auto-loads `~/.arnold_pipeline/config.yml`. Phase 2 adds a new `doctor` Thor subcommand with shell-based dependency checks.

**Tech Stack:** Ruby 4, Thor CLI, tty-prompt gem (new dependency)

---

### Task 1: Add tty-prompt dependency

**Files:**
- Modify: `arnold_pipeline.gemspec:31` (add dependency)

**Step 1: Add tty-prompt to gemspec**

Add after the `faraday-retry` dependency line:

```ruby
spec.add_dependency "tty-prompt", "~> 0.23"
```

**Step 2: Install the gem**

Run: `bundle install`
Expected: tty-prompt and its dependencies install successfully.

**Step 3: Commit**

```bash
git add arnold_pipeline.gemspec Gemfile.lock
git commit -m "chore: add tty-prompt dependency for interactive CLI prompts [SPEC-CLI]"
```

---

### Task 2: Auto-load ~/.arnold_pipeline/config.yml

**Files:**
- Modify: `lib/arnold_pipeline/cli.rb:431-450` (load_config! method)
- Test: `test/lib/arnold_pipeline/cli_test.rb`

**Step 1: Write the failing test**

Add to `cli_test.rb`:

```ruby
test "load_config! auto-loads ~/.arnold_pipeline/config.yml when present" do
  config_dir = File.join(Dir.tmpdir, "arnold_pipeline_test_#{SecureRandom.hex(4)}")
  config_path = File.join(config_dir, "config.yml")
  FileUtils.mkdir_p(config_dir)
  File.write(config_path, YAML.dump("llm_provider" => "openai", "llm_model" => "gpt-4o-mini"))

  cli = Cli.new
  stub_const_value = config_path
  Cli.const_set(:USER_CONFIG_PATH, stub_const_value) if !Cli.const_defined?(:USER_CONFIG_PATH)
  original = Cli::USER_CONFIG_PATH

  begin
    Cli.send(:remove_const, :USER_CONFIG_PATH)
    Cli.const_set(:USER_CONFIG_PATH, config_path)

    cli.send(:load_config!, { "config" => nil })
    assert_equal :openai, ArnoldPipeline.configuration.llm_provider
    assert_equal "gpt-4o-mini", ArnoldPipeline.configuration.llm_model
  ensure
    Cli.send(:remove_const, :USER_CONFIG_PATH)
    Cli.const_set(:USER_CONFIG_PATH, original)
    ArnoldPipeline.reset_configuration!
    FileUtils.rm_rf(config_dir)
  end
end

test "load_config! explicit --config overrides user config" do
  user_dir = File.join(Dir.tmpdir, "arnold_user_cfg_#{SecureRandom.hex(4)}")
  user_config_path = File.join(user_dir, "config.yml")
  FileUtils.mkdir_p(user_dir)
  File.write(user_config_path, YAML.dump("llm_model" => "should-be-overridden"))

  explicit_config = File.join(Dir.tmpdir, "arnold_explicit_#{SecureRandom.hex(4)}.yml")
  File.write(explicit_config, YAML.dump("llm_model" => "explicit-model"))

  original = Cli::USER_CONFIG_PATH
  begin
    Cli.send(:remove_const, :USER_CONFIG_PATH)
    Cli.const_set(:USER_CONFIG_PATH, user_config_path)

    cli = Cli.new
    cli.send(:load_config!, { "config" => explicit_config })
    assert_equal "explicit-model", ArnoldPipeline.configuration.llm_model
  ensure
    Cli.send(:remove_const, :USER_CONFIG_PATH)
    Cli.const_set(:USER_CONFIG_PATH, original)
    ArnoldPipeline.reset_configuration!
    FileUtils.rm_rf(user_dir)
    File.delete(explicit_config) if File.exist?(explicit_config)
  end
end

test "load_config! skips user config when file does not exist" do
  original = Cli::USER_CONFIG_PATH
  begin
    Cli.send(:remove_const, :USER_CONFIG_PATH)
    Cli.const_set(:USER_CONFIG_PATH, "/nonexistent/path/config.yml")

    cli = Cli.new
    cli.send(:load_config!, { "config" => nil })
    # Should not raise, default config remains
    assert_equal :anthropic, ArnoldPipeline.configuration.llm_provider
  ensure
    Cli.send(:remove_const, :USER_CONFIG_PATH)
    Cli.const_set(:USER_CONFIG_PATH, original)
    ArnoldPipeline.reset_configuration!
  end
end
```

**Step 2: Run tests to verify they fail**

Run: `bundle exec rails test test/lib/arnold_pipeline/cli_test.rb -n /load_config/`
Expected: FAIL — `USER_CONFIG_PATH` constant doesn't exist yet.

**Step 3: Implement auto-loading in load_config!**

In `cli.rb`, add the constant after `STANDALONE_DB_PATH`:

```ruby
USER_CONFIG_PATH = File.join(STANDALONE_DB_DIR, "config.yml")
```

Update `load_config!` to auto-load user config first:

```ruby
def load_config!(options)
  # Auto-load user config (lowest priority)
  if File.exist?(USER_CONFIG_PATH)
    user_config = YAML.safe_load_file(USER_CONFIG_PATH, symbolize_names: true)
    apply_config!(user_config)
  end

  # Explicit --config overrides user config
  if options[:config]
    yaml_config = YAML.safe_load_file(options[:config], symbolize_names: true)
    apply_config!(yaml_config)
  end

  ArnoldPipeline.configure do |c|
    c.llm_provider = options[:provider].to_sym if options[:provider]
    c.llm_model = options[:model] if options[:model]
    c.github_repo = options[:repo] if options[:repo]
    c.github_issue_mention = options[:issue_mention] if options[:issue_mention]
    c.polling_interval = options[:polling_interval] if options[:polling_interval]
    c.polling_timeout = options[:polling_timeout] if options[:polling_timeout]
    c.execution_provider = options[:execution_provider].to_sym if options[:execution_provider]
    c.claude_code_repo_path = options[:claude_code_repo_path] if options[:claude_code_repo_path]
    c.claude_code_model = options[:claude_code_model] if options[:claude_code_model]
    c.claude_code_max_turns = options[:claude_code_max_turns] if options[:claude_code_max_turns]
    c.claude_code_permission_mode = options[:claude_code_permission_mode] if options[:claude_code_permission_mode]
  end
end
```

**Step 4: Run tests to verify they pass**

Run: `bundle exec rails test test/lib/arnold_pipeline/cli_test.rb -n /load_config/`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/arnold_pipeline/cli.rb test/lib/arnold_pipeline/cli_test.rb
git commit -m "feat(cli): auto-load ~/.arnold_pipeline/config.yml on startup [SPEC-CLI]"
```

---

### Task 3: Interactive API key setup for preview mode

**Files:**
- Create: `lib/arnold_pipeline/cli/setup_wizard.rb`
- Test: `test/lib/arnold_pipeline/cli/setup_wizard_test.rb`

**Step 1: Write the failing tests**

Create `test/lib/arnold_pipeline/cli/setup_wizard_test.rb`:

```ruby
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

        SetupWizard.stub(:config_path, config_path) do
          SetupWizard.prompt_and_configure!
        end

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

        SetupWizard.stub(:config_path, config_path) do
          SetupWizard.prompt_and_configure!
        end

        refute File.exist?(config_path)
      ensure
        FileUtils.rm_rf(config_dir)
      end
    end
  end
end
```

**Step 2: Run tests to verify they fail**

Run: `bundle exec rails test test/lib/arnold_pipeline/cli/setup_wizard_test.rb`
Expected: FAIL — file doesn't exist.

**Step 3: Implement SetupWizard**

Create `lib/arnold_pipeline/cli/setup_wizard.rb`:

```ruby
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
```

**Step 4: Run tests to verify they pass**

Run: `bundle exec rails test test/lib/arnold_pipeline/cli/setup_wizard_test.rb`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/arnold_pipeline/cli/setup_wizard.rb test/lib/arnold_pipeline/cli/setup_wizard_test.rb
git commit -m "feat(cli): add interactive API key setup wizard [SPEC-CLI]"
```

---

### Task 4: Rewire --preview to zero-config mode

**Files:**
- Modify: `lib/arnold_pipeline/cli.rb:33-70` (run_pipeline preview block)
- Test: `test/lib/arnold_pipeline/cli_test.rb`

**Step 1: Write the failing tests**

Add to `cli_test.rb`:

```ruby
test "run --preview auto-sets null provider and stop_after tasks" do
  mock_run = PipelineRun.create!(nl_input: "Build a todo app", status: :paused)
  mock_run.tasks.create!(title: "Setup", tier: 0, position: 0, status: :pending)

  mock_orchestrator = mock("orchestrator")
  mock_orchestrator.expects(:call).with(nl_input: "Build a todo app", stop_after: :tasks).returns(mock_run)

  ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)

  output = capture_output { Cli.start(["run", "--preview", "Build a todo app"]) }

  assert_equal :null, ArnoldPipeline.configuration.execution_provider
  assert_match(/Arnold Preview/, output)
  assert_match(/Specification/, output)
ensure
  ArnoldPipeline.reset_configuration!
end

test "run --preview prints formatted spec content" do
  mock_run = PipelineRun.create!(nl_input: "Build a todo app", status: :paused)
  mock_run.create_specification!(content: "# Todo App\n\n## Purpose\nA simple todo list.", version: 1)
  mock_run.tasks.create!(title: "Setup DB", description: "Create tables", tier: 0, position: 0, status: :pending)
  mock_run.tasks.create!(title: "Add API", description: "REST endpoints", tier: 1, position: 1, status: :pending, depends_on: [0])

  mock_orchestrator = mock("orchestrator")
  mock_orchestrator.expects(:call).returns(mock_run)
  ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)

  output = capture_output { Cli.start(["run", "--preview", "Build a todo app"]) }

  assert_match(/# Todo App/, output)
  assert_match(/Tier 0/, output)
  assert_match(/Setup DB/, output)
  assert_match(/Tier 1/, output)
  assert_match(/Add API/, output)
  assert_match(/depends on: 0/, output)
  assert_match(/Run without --preview to execute/, output)
ensure
  ArnoldPipeline.reset_configuration!
end

test "run --preview prompts for API key when none available" do
  original_anthropic = ENV["ANTHROPIC_API_KEY"]
  original_openai = ENV["OPENAI_API_KEY"]
  ENV.delete("ANTHROPIC_API_KEY")
  ENV.delete("OPENAI_API_KEY")

  require "arnold_pipeline/cli/setup_wizard"
  ArnoldPipeline::CliModule::SetupWizard.expects(:api_key_available?).returns(false)
  ArnoldPipeline::CliModule::SetupWizard.expects(:prompt_and_configure!)

  mock_run = PipelineRun.create!(nl_input: "test", status: :paused)
  mock_run.tasks.create!(title: "Setup", tier: 0, position: 0, status: :pending)
  mock_orchestrator = mock("orchestrator")
  mock_orchestrator.expects(:call).returns(mock_run)
  ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)

  capture_output { Cli.start(["run", "--preview", "test"]) }
ensure
  ENV["ANTHROPIC_API_KEY"] = original_anthropic if original_anthropic
  ENV["OPENAI_API_KEY"] = original_openai if original_openai
  ArnoldPipeline.reset_configuration!
end
```

**Step 2: Run tests to verify they fail**

Run: `bundle exec rails test test/lib/arnold_pipeline/cli_test.rb -n /preview/`
Expected: Some fail — preview doesn't set null provider yet, doesn't print spec content, doesn't prompt for key.

**Step 3: Implement the rewired preview mode**

Replace the preview block in `run_pipeline` (lines ~47-69) with:

```ruby
if options[:preview]
  ArnoldPipeline.configure { |c| c.execution_provider = :null }

  require "arnold_pipeline/cli/setup_wizard"
  unless CliModule::SetupWizard.api_key_available?
    CliModule::SetupWizard.prompt_and_configure!
  end

  logger = build_logger(options[:verbose])
  orchestrator = Orchestrator.new(logger:)
  result = orchestrator.call(nl_input: description, stop_after: :tasks)

  say ""
  say "--- Arnold Preview ---", :green
  say ""

  if result.specification
    say "-- Specification --", :green
    say result.specification.content
    say ""
  end

  tasks_by_tier = result.tasks.order(:tier, :position).group_by(&:tier)
  total_tasks = result.tasks.count
  total_tiers = tasks_by_tier.keys.size

  say "-- Tasks (#{total_tasks} tasks, #{total_tiers} tiers) --", :green
  tasks_by_tier.sort.each do |tier, tasks|
    say "Tier #{tier}:"
    tasks.each do |task|
      deps = task.depends_on.any? ? " (depends on: #{task.depends_on.join(', ')})" : ""
      say "  #{task.position}. [#{task.title}] — #{task.description.to_s.truncate(80)}#{deps}"
    end
  end

  say ""
  say "--- Preview complete. Run without --preview to execute. ---", :green
  return
end
```

**Step 4: Run tests to verify they pass**

Run: `bundle exec rails test test/lib/arnold_pipeline/cli_test.rb -n /preview/`
Expected: PASS

**Step 5: Run full CLI test suite**

Run: `bundle exec rails test test/lib/arnold_pipeline/cli_test.rb`
Expected: PASS — existing dry-run tests may need minor adjustments since preview behavior changed.

**Step 6: Commit**

```bash
git add lib/arnold_pipeline/cli.rb test/lib/arnold_pipeline/cli_test.rb
git commit -m "feat(cli): rewire --preview for zero-config spec+task generation [SPEC-CLI]"
```

---

### Task 5: Doctor command — health check service

**Files:**
- Create: `lib/arnold_pipeline/cli/doctor.rb`
- Test: `test/lib/arnold_pipeline/cli/doctor_test.rb`

**Step 1: Write the failing tests**

Create `test/lib/arnold_pipeline/cli/doctor_test.rb`:

```ruby
require "test_helper"
require "arnold_pipeline/cli/doctor"

module ArnoldPipeline
  module CliModule
    class DoctorTest < ActiveSupport::TestCase
      setup do
        @original_anthropic = ENV["ANTHROPIC_API_KEY"]
        @original_openai = ENV["OPENAI_API_KEY"]
      end

      teardown do
        ENV["ANTHROPIC_API_KEY"] = @original_anthropic if @original_anthropic
        ENV["OPENAI_API_KEY"] = @original_openai if @original_openai
        ArnoldPipeline.reset_configuration!
      end

      test "Check stores name, status, message, and fix" do
        check = Doctor::Check.new(name: "Ruby", status: :pass, message: "4.0.0")
        assert_equal "Ruby", check.name
        assert_equal :pass, check.status
        assert_equal "4.0.0", check.message
        assert_nil check.fix
      end

      test "check_ruby returns pass for valid ruby" do
        result = Doctor.check_ruby
        assert_equal :pass, result.status
        assert_match(/\d+\.\d+/, result.message)
      end

      test "check_git returns pass when git is available" do
        result = Doctor.check_git
        assert_equal :pass, result.status
        assert_match(/\d+\.\d+/, result.message)
      end

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
        result = Doctor.check_api_keys
        assert_equal :pass, result.status
        assert_match(/OPENAI_API_KEY/, result.message)
      end

      test "check_api_keys returns fail when no key set" do
        ENV.delete("ANTHROPIC_API_KEY")
        ENV.delete("OPENAI_API_KEY")
        ArnoldPipeline.reset_configuration!
        result = Doctor.check_api_keys
        assert_equal :fail, result.status
        assert result.fix
      end

      test "check_sqlite returns pass when sqlite3 available" do
        result = Doctor.check_sqlite
        assert_equal :pass, result.status
      end

      test "check_node returns pass or warn based on version" do
        result = Doctor.check_node
        assert_includes [:pass, :warn, :skip], result.status
      end

      test "check_openspec returns pass or skip" do
        result = Doctor.check_openspec
        assert_includes [:pass, :skip], result.status
      end

      test "check_claude_code returns pass or skip" do
        result = Doctor.check_claude_code
        assert_includes [:pass, :skip], result.status
      end

      test "run_all returns array of Check results" do
        ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"
        results = Doctor.run_all
        assert_kind_of Array, results
        assert results.all? { |r| r.is_a?(Doctor::Check) }
        assert results.length >= 7
      end

      test "all_required_passed? returns true when required checks pass" do
        ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"
        results = Doctor.run_all
        # If we're in a dev environment, required checks should pass
        if results.none? { |r| r.status == :fail }
          assert Doctor.all_required_passed?(results)
        end
      end
    end
  end
end
```

**Step 2: Run tests to verify they fail**

Run: `bundle exec rails test test/lib/arnold_pipeline/cli/doctor_test.rb`
Expected: FAIL — file doesn't exist.

**Step 3: Implement Doctor service**

Create `lib/arnold_pipeline/cli/doctor.rb`:

```ruby
module ArnoldPipeline
  module CliModule
    class Doctor
      Check = Data.define(:name, :status, :message, :fix) do
        def initialize(name:, status:, message:, fix: nil)
          super(name:, status:, message:, fix:)
        end
      end

      REQUIRED_CHECKS = %i[ruby git api_keys sqlite].freeze

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
        results.select { |r| REQUIRED_CHECKS.any? { |name| r.name.downcase.start_with?(name.to_s) } }
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
          Check.new(name: "Git", status: :pass, message: version)
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
                    fix: "export ANTHROPIC_API_KEY=sk-ant-... or run arnold run --preview to set up interactively")
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
```

**Step 4: Run tests to verify they pass**

Run: `bundle exec rails test test/lib/arnold_pipeline/cli/doctor_test.rb`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/arnold_pipeline/cli/doctor.rb test/lib/arnold_pipeline/cli/doctor_test.rb
git commit -m "feat(cli): add Doctor health check service [SPEC-CLI]"
```

---

### Task 6: Doctor CLI subcommand

**Files:**
- Modify: `lib/arnold_pipeline/cli.rb` (add doctor subcommand)
- Test: `test/lib/arnold_pipeline/cli_test.rb`

**Step 1: Write the failing test**

Add to `cli_test.rb`:

```ruby
test "doctor command outputs health check results" do
  original_anthropic = ENV["ANTHROPIC_API_KEY"]
  ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"

  output = capture_output { Cli.start(["doctor"]) }

  assert_match(/Arnold Doctor/, output)
  assert_match(/Ruby/, output)
  assert_match(/Git/, output)
  assert_match(/API key/, output)
  assert_match(/SQLite/, output)
ensure
  ENV["ANTHROPIC_API_KEY"] = original_anthropic
end

test "doctor exits with 0 when all required checks pass" do
  original_anthropic = ENV["ANTHROPIC_API_KEY"]
  ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"

  # Should not raise SystemExit
  capture_output { Cli.start(["doctor"]) }
ensure
  ENV["ANTHROPIC_API_KEY"] = original_anthropic
end

test "doctor exits with 1 when required check fails" do
  original_anthropic = ENV["ANTHROPIC_API_KEY"]
  original_openai = ENV["OPENAI_API_KEY"]
  ENV.delete("ANTHROPIC_API_KEY")
  ENV.delete("OPENAI_API_KEY")
  ArnoldPipeline.reset_configuration!

  assert_raises(SystemExit) do
    capture_output_and_errors { Cli.start(["doctor"]) }
  end
ensure
  ENV["ANTHROPIC_API_KEY"] = original_anthropic if original_anthropic
  ENV["OPENAI_API_KEY"] = original_openai if original_openai
  ArnoldPipeline.reset_configuration!
end
```

**Step 2: Run tests to verify they fail**

Run: `bundle exec rails test test/lib/arnold_pipeline/cli_test.rb -n /doctor/`
Expected: FAIL — doctor command doesn't exist.

**Step 3: Implement doctor subcommand**

Add to `cli.rb`, after the `version` method:

```ruby
desc "doctor", "Check environment health and dependencies"
def doctor
  require "arnold_pipeline/cli/doctor"

  # Load user config so API keys from config file are detected
  if File.exist?(USER_CONFIG_PATH)
    user_config = YAML.safe_load_file(USER_CONFIG_PATH, symbolize_names: true)
    apply_config!(user_config)
  end

  results = CliModule::Doctor.run_all

  say "Arnold Doctor", :green
  say "-" * 40

  results.each do |check|
    indicator = case check.status
    when :pass then set_color("✓", :green)
    when :warn then set_color("!", :yellow)
    when :fail then set_color("✗", :red)
    when :skip then set_color("—", :cyan)
    end

    say "#{indicator} #{check.name}: #{check.message}"
    say "  → #{check.fix}" if check.fix && check.status != :pass
  end

  say ""
  pass_count = results.count { |r| r.status == :pass }
  warn_count = results.count { |r| r.status == :warn }
  fail_count = results.count { |r| r.status == :fail }
  skip_count = results.count { |r| r.status == :skip }

  parts = []
  parts << "#{pass_count} passed" if pass_count > 0
  parts << "#{warn_count} warnings" if warn_count > 0
  parts << "#{fail_count} failed" if fail_count > 0
  parts << "#{skip_count} optional skipped" if skip_count > 0
  say parts.join(", ")

  unless CliModule::Doctor.all_required_passed?(results)
    say "\nFix required issues above to use Arnold.", :red
    raise SystemExit.new(1)
  end
end
```

**Step 4: Run tests to verify they pass**

Run: `bundle exec rails test test/lib/arnold_pipeline/cli_test.rb -n /doctor/`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/arnold_pipeline/cli.rb test/lib/arnold_pipeline/cli_test.rb
git commit -m "feat(cli): add arnold doctor subcommand [SPEC-CLI]"
```

---

### Task 7: Wire doctor into error paths

**Files:**
- Modify: `lib/arnold_pipeline/cli.rb:513-530` (with_error_handling method)
- Test: `test/lib/arnold_pipeline/cli_test.rb`

**Step 1: Write the failing test**

Add to `cli_test.rb`:

```ruby
test "run shows doctor hint on ConfigurationError" do
  ArnoldPipeline::Orchestrator.stubs(:new).raises(ArnoldPipeline::ConfigurationError, "LLM API key is required")

  stderr_output = capture_stderr_through_exit { Cli.start(["run", "Build an app"]) }
  assert_match(/Configuration error:.*LLM API key is required/, stderr_output)
  assert_match(/arnold doctor/, stderr_output)
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rails test test/lib/arnold_pipeline/cli_test.rb -n /doctor_hint/`
Expected: FAIL — error message doesn't mention doctor.

**Step 3: Add doctor hint to error handling**

In `with_error_handling`, update the `ConfigurationError` rescue:

```ruby
rescue ArnoldPipeline::ConfigurationError => e
  say_error "Configuration error: #{e.message}", :red
  say_error "Run 'arnold doctor' to check your setup.", :yellow
  raise SystemExit.new(1)
```

**Step 4: Run test to verify it passes**

Run: `bundle exec rails test test/lib/arnold_pipeline/cli_test.rb -n /doctor_hint/`
Expected: PASS

**Step 5: Verify existing error tests still pass**

Run: `bundle exec rails test test/lib/arnold_pipeline/cli_test.rb -n /ConfigurationError/`
Expected: PASS (existing test checks for the error message, which is still there).

**Step 6: Commit**

```bash
git add lib/arnold_pipeline/cli.rb test/lib/arnold_pipeline/cli_test.rb
git commit -m "feat(cli): add doctor hint to configuration error messages [SPEC-CLI]"
```

---

### Task 8: Update existing --preview/--dry-run tests

**Files:**
- Modify: `test/lib/arnold_pipeline/cli_test.rb`

The existing `--dry-run` and `--preview` tests (lines 294-329) assumed the old preview behavior (showing provider info). Update them to match the new formatted output.

**Step 1: Review and fix any broken existing tests**

Run: `bundle exec rails test test/lib/arnold_pipeline/cli_test.rb`

Fix any tests that fail due to the preview output format change. The key changes:
- Old: "DRY RUN" message, shows execution provider info
- New: "Arnold Preview" header, shows spec content + formatted task list

Update the two existing preview tests to match new output:

```ruby
test "run --dry-run shows preview output" do
  mock_run = PipelineRun.create!(nl_input: "Build a recipe app", status: :paused)
  mock_run.create_specification!(content: "# Recipe App Spec", version: 1)
  mock_run.tasks.create!(title: "Setup project", tier: 0, position: 0, status: :pending)
  mock_run.tasks.create!(title: "Add models", tier: 1, position: 1, status: :pending)
  mock_run.tasks.create!(title: "Add views", tier: 1, position: 2, status: :pending)

  mock_orchestrator = mock("orchestrator")
  mock_orchestrator.expects(:call).with(nl_input: "Build a recipe app", stop_after: :tasks).returns(mock_run)
  ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)

  output = capture_output { Cli.start(["run", "--dry-run", "Build a recipe app"]) }

  assert_match(/Arnold Preview/, output)
  assert_match(/# Recipe App Spec/, output)
  assert_match(/3 tasks, 2 tiers/, output)
  assert_match(/Tier 0/, output)
  assert_match(/Tier 1/, output)
  assert_match(/Run without --preview to execute/, output)
ensure
  ArnoldPipeline.reset_configuration!
end

test "run --preview shows formatted task output" do
  mock_run = PipelineRun.create!(nl_input: "Build an app", status: :paused)
  mock_run.create_specification!(content: "# App Spec", version: 1)
  mock_run.tasks.create!(title: "Setup", tier: 0, position: 0, status: :pending)

  mock_orchestrator = mock("orchestrator")
  mock_orchestrator.expects(:call).returns(mock_run)
  ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)

  output = capture_output { Cli.start(["run", "--preview", "Build an app"]) }
  assert_match(/Arnold Preview/, output)
  assert_match(/Setup/, output)
ensure
  ArnoldPipeline.reset_configuration!
end
```

**Step 2: Run full CLI test suite**

Run: `bundle exec rails test test/lib/arnold_pipeline/cli_test.rb`
Expected: PASS — all tests green.

**Step 3: Commit**

```bash
git add test/lib/arnold_pipeline/cli_test.rb
git commit -m "test: update preview/dry-run tests for new output format [SPEC-CLI]"
```

---

### Task 9: Run full test suite

**Step 1: Run full test suite**

Run: `bundle exec rails test`
Expected: All 1216+ tests pass, 0 failures.

**Step 2: Fix any breakage**

If any tests fail due to the new code, fix them. Common issues:
- Tests that check `say_error` output for ConfigurationError may need to account for the new "arnold doctor" hint line
- Tests that rely on specific configuration state may need `ArnoldPipeline.reset_configuration!` in teardown

**Step 3: Commit any fixes**

```bash
git add -A
git commit -m "fix: resolve test suite issues from preview+doctor features [SPEC-CLI]"
```

---

### Task 10: Update README quick start

**Files:**
- Modify: `README.md`

**Step 1: Update the Quick Start section**

The first code block a new user sees should be three lines. Find the current "Quick Start" or "Getting Started" section and replace it to lead with the preview path:

```markdown
## Quick Start

```bash
gem install arnold_pipeline
export ANTHROPIC_API_KEY=sk-ant-...   # or OPENAI_API_KEY
arnold run "Build a todo list app with user auth" --preview
```

This generates a full specification and task breakdown without requiring any infrastructure setup.
Ready to execute? See [Execution Providers](#execution-providers) to set up GitHub or Claude Code.

### Check Your Setup

```bash
arnold doctor
```

Reports pass/fail/warn for all dependencies with one-line fix commands.
```

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: update quick start to lead with --preview path [SPEC-CLI]"
```
