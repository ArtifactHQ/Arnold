# Solid Stack Boot Probe Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a built-in `solid_stack` verification check type that probes SolidQueue/SolidCache/ActionCable database connections.

**Architecture:** VerificationRunner gains a `solid_stack` check type. When encountered, it generates a Rails runner script inline instead of using the check's `command`. The script tests each Solid stack Record class's database connection and exits 1 with descriptive errors on failure.

**Tech Stack:** Ruby, Minitest, Mocha

---

### Task 1: Add `solid_stack` to VerificationCheck

**Files:**
- Modify: `lib/arnold_pipeline/verification_check.rb`
- Test: `test/lib/arnold_pipeline/verification_runner_test.rb`

**Step 1: Write the failing test**

Add to `test/lib/arnold_pipeline/verification_runner_test.rb`:

```ruby
test "VerificationCheck accepts solid_stack type without command" do
  check = VerificationCheck.new(name: "solid", type: :solid_stack, required: true)
  assert_equal :solid_stack, check.type
  assert_nil check.command
  assert check.required?
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rails test test/lib/arnold_pipeline/verification_runner_test.rb -n "test_VerificationCheck_accepts_solid_stack_type_without_command"`
Expected: FAIL — `command` is a required keyword argument

**Step 3: Make command optional in VerificationCheck**

In `lib/arnold_pipeline/verification_check.rb`, change:

```ruby
# Old:
TYPES = %i[boot test_suite custom].freeze

attr_reader :name, :command, :type, :required

def initialize(name:, command:, type: :custom, required: false)
  @name = name
  @command = command
  @type = type.to_sym
  @required = required
end
```

To:

```ruby
TYPES = %i[boot test_suite custom solid_stack].freeze

attr_reader :name, :command, :type, :required

def initialize(name:, command: nil, type: :custom, required: false)
  @name = name
  @command = command
  @type = type.to_sym
  @required = required
end
```

**Step 4: Run test to verify it passes**

Run: `bundle exec rails test test/lib/arnold_pipeline/verification_runner_test.rb -n "test_VerificationCheck_accepts_solid_stack_type_without_command"`
Expected: PASS

**Step 5: Run full verification runner tests to check for regressions**

Run: `bundle exec rails test test/lib/arnold_pipeline/verification_runner_test.rb`
Expected: All tests pass (existing tests all provide `command:`)

---

### Task 2: Add `solid_stack_script` to VerificationRunner

**Files:**
- Modify: `lib/arnold_pipeline/verification_runner.rb`
- Test: `test/lib/arnold_pipeline/verification_runner_test.rb`

**Step 1: Write the failing test for solid_stack check passing**

Add to `test/lib/arnold_pipeline/verification_runner_test.rb`:

```ruby
test "solid_stack check generates and runs probe script" do
  # Create a minimal Rails-like environment in tmpdir
  runner_script = File.join(@tmpdir, "bin", "rails")
  FileUtils.mkdir_p(File.join(@tmpdir, "bin"))
  File.write(runner_script, <<~BASH)
    #!/bin/bash
    # Simulate bin/rails runner by evaluating the -e argument
    # Just echo success since there's no real Rails env
    echo "All Solid stack connections OK"
    exit 0
  BASH
  FileUtils.chmod(0o755, runner_script)

  checks = [
    VerificationCheck.new(name: "Solid stack", type: :solid_stack, required: true)
  ]

  result = VerificationRunner.call(repo_path: @tmpdir, checks: checks)

  assert_equal 1, result[:checks].size
  assert result[:checks][0][:success]
  assert_equal :solid_stack, result[:checks][0][:type]
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rails test test/lib/arnold_pipeline/verification_runner_test.rb -n "test_solid_stack_check_generates_and_runs_probe_script"`
Expected: FAIL — runner tries to execute nil command

**Step 3: Implement solid_stack_script and run_check dispatch**

In `lib/arnold_pipeline/verification_runner.rb`, modify `run_check`:

```ruby
def run_check(check)
  @logger&.info("[VerificationRunner] Running check: #{check.name}")

  command = check.type == :solid_stack ? solid_stack_command : check.command
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  stdout, stderr, status = Bundler.with_unbundled_env do
    Open3.capture3(command, chdir: @repo_path)
  end
  duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round

  {
    name: check.name,
    type: check.type,
    success: status.success?,
    exit_code: status.exitstatus,
    stdout: tail_capture(stdout, STDOUT_CAP),
    stderr: tail_capture(stderr, STDERR_CAP),
    duration_ms: duration_ms
  }
rescue => e
  duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - (start || Process.clock_gettime(Process::CLOCK_MONOTONIC))) * 1000).round

  @logger&.warn("[VerificationRunner] Check '#{check.name}' raised: #{e.message}")

  {
    name: check.name,
    type: check.type,
    success: false,
    exit_code: nil,
    stdout: "",
    stderr: e.message[0, STDERR_CAP],
    duration_ms: duration_ms
  }
end
```

Add the new private method:

```ruby
SOLID_STACK_SCRIPT = <<~'RUBY'
  errors = []
  if defined?(SolidQueue::Record)
    begin
      SolidQueue::Record.connection.active?
      puts "SolidQueue: OK"
    rescue => e
      errors << "SolidQueue: #{e.message}. Ensure config.solid_queue.connects_to = { database: { writing: :queue } } is set in config/environments/development.rb"
    end
  end
  if defined?(SolidCache::Record)
    begin
      SolidCache::Record.connection.active?
      puts "SolidCache: OK"
    rescue => e
      errors << "SolidCache: #{e.message}. Ensure config.solid_cache.connects_to = { database: { writing: :cache } } is set in config/environments/development.rb"
    end
  end
  if defined?(ActionCable) && ActionCable.const_defined?(:Record, false)
    begin
      ActionCable::Record.connection.active?
      puts "ActionCable: OK"
    rescue => e
      errors << "ActionCable: #{e.message}. Check cable database configuration in config/environments/development.rb"
    end
  end
  if errors.any?
    $stderr.puts errors.join("\n")
    exit 1
  else
    puts "All Solid stack connections OK"
  end
RUBY

def solid_stack_command
  "bin/rails runner -e '#{SOLID_STACK_SCRIPT.gsub("'", "'\\''")}'"
end
```

Note: The single-quote escaping is fragile. Use a heredoc approach instead:

```ruby
def solid_stack_command
  script_path = File.join(@repo_path, "tmp", "arnold_solid_check.rb")
  File.write(script_path, SOLID_STACK_SCRIPT)
  "bin/rails runner #{script_path}"
end
```

**Step 4: Run test to verify it passes**

Run: `bundle exec rails test test/lib/arnold_pipeline/verification_runner_test.rb -n "test_solid_stack_check_generates_and_runs_probe_script"`
Expected: PASS

---

### Task 3: Test solid_stack failure path

**Files:**
- Test: `test/lib/arnold_pipeline/verification_runner_test.rb`

**Step 1: Write test for solid_stack check failing**

```ruby
test "solid_stack check reports failure when probe script exits non-zero" do
  runner_script = File.join(@tmpdir, "bin", "rails")
  FileUtils.mkdir_p(File.join(@tmpdir, "bin"))
  File.write(runner_script, <<~BASH)
    #!/bin/bash
    echo "SolidQueue: no such table: solid_queue_jobs. Ensure config.solid_queue.connects_to is set" >&2
    exit 1
  BASH
  FileUtils.chmod(0o755, runner_script)

  checks = [
    VerificationCheck.new(name: "Solid stack", type: :solid_stack, required: true)
  ]

  result = VerificationRunner.call(repo_path: @tmpdir, checks: checks)

  assert_equal 1, result[:checks].size
  refute result[:checks][0][:success]
  assert_includes result[:checks][0][:stderr], "SolidQueue"
  refute result[:all_passed]
end
```

**Step 2: Run test**

Run: `bundle exec rails test test/lib/arnold_pipeline/verification_runner_test.rb -n "test_solid_stack_check_reports_failure_when_probe_script_exits_non_zero"`
Expected: PASS (this should already work with the implementation from Task 2)

---

### Task 4: Handle `solid_stack` in `build_checks`

**Files:**
- Modify: `lib/arnold_pipeline/tier_execution_engine.rb:827-839`
- Test: `test/lib/arnold_pipeline/tier_execution_engine_test.rb`

**Step 1: Write failing test**

Add to the tier execution engine test file, in the verification checks section:

```ruby
test "build_checks creates solid_stack check without command" do
  ArnoldPipeline.configure do |c|
    c.verification_checks = [
      { "name" => "Solid stack", "type" => "solid_stack", "required" => true }
    ]
  end

  engine = build_engine
  checks = engine.send(:build_checks)

  assert_equal 1, checks.size
  assert_equal :solid_stack, checks[0].type
  assert_nil checks[0].command
  assert checks[0].required?
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rails test test/lib/arnold_pipeline/tier_execution_engine_test.rb -n "test_build_checks_creates_solid_stack_check_without_command"`
Expected: FAIL — `build_checks` currently passes `command:` which may be nil from config but was previously always required

**Step 3: Update `build_checks` in tier_execution_engine.rb**

In `lib/arnold_pipeline/tier_execution_engine.rb`, the `build_checks` method at line 827:

```ruby
def build_checks
  config = ArnoldPipeline.configuration
  return [] unless config.verification_checks.present?

  config.verification_checks.map do |c|
    VerificationCheck.new(
      name: c["name"] || c[:name],
      command: c["command"] || c[:command],
      type: c["type"] || c[:type] || :custom,
      required: c["required"] || c[:required] || false
    )
  end
end
```

No change needed here — since `command:` is now optional in VerificationCheck (Task 1), this already works. The `command` value will be `nil` for `solid_stack` entries (which don't have a `command` key in config), and that's fine because VerificationRunner generates the command.

**Step 4: Run test to verify it passes**

Run: `bundle exec rails test test/lib/arnold_pipeline/tier_execution_engine_test.rb -n "test_build_checks_creates_solid_stack_check_without_command"`
Expected: PASS

---

### Task 5: Run full test suite

Run: `bundle exec rails test`
Expected: All tests pass (1345+ tests, 0 failures)

---

### Task 6: Commit and update MEMORY.md

**Step 1: Commit**

```bash
git add lib/arnold_pipeline/verification_check.rb lib/arnold_pipeline/verification_runner.rb test/lib/arnold_pipeline/verification_runner_test.rb lib/arnold_pipeline/tier_execution_engine.rb test/lib/arnold_pipeline/tier_execution_engine_test.rb
git commit -m "feat(verification): add solid_stack built-in check type for Solid Queue/Cache/Cable connection probing [SPEC-EXEC-001]"
```

**Step 2: Update MEMORY.md**

Add to the Verification section:
- `solid_stack` built-in check type: generates `tmp/arnold_solid_check.rb` script, runs via `bin/rails runner`
- Probes SolidQueue::Record, SolidCache::Record, ActionCable::Record connections
- Descriptive error messages guide corrective tasks to add `connects_to` in development.rb
