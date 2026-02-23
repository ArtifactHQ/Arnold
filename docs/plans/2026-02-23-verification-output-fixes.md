# Verification Output Pipeline Fixes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ensure boot/solid_stack failure error messages reach the execution agent so corrective tasks can fix the actual root cause.

**Architecture:** Three surgical fixes across two files: (1) propagate `required` flag from VerificationCheck into the result hash so the tier engine's required-check-failure path activates, (2) add `head_and_tail_capture` for non-test-suite checks so boot exception messages aren't truncated, (3) broaden `extract_test_output` → `extract_verification_output` to include all failed check output in corrective task descriptions.

**Tech Stack:** Ruby, Minitest, Mocha for stubs

---

### Task 1: Add `required` flag to verification check result hash

**Files:**
- Modify: `lib/arnold_pipeline/verification_runner.rb:51-59` (success path) and `65-73` (rescue path)
- Test: `test/lib/arnold_pipeline/verification_runner_test.rb`

**Step 1: Write the failing tests**

Add after the existing "short-circuits on required check failure" test (after line 53):

```ruby
test "result hash includes required flag from check config" do
  checks = [
    VerificationCheck.new(name: "required_check", command: @pass_script, required: true),
    VerificationCheck.new(name: "optional_check", command: @pass_script, required: false)
  ]

  result = VerificationRunner.call(repo_path: @tmpdir, checks: checks)

  assert_equal true, result[:checks][0][:required]
  assert_equal false, result[:checks][1][:required]
end

test "result hash includes required flag even on exception" do
  checks = [
    VerificationCheck.new(name: "bad_cmd", command: "/nonexistent/command/xyz_12345", required: true)
  ]

  result = VerificationRunner.call(repo_path: @tmpdir, checks: checks)

  assert_equal true, result[:checks][0][:required]
  refute result[:checks][0][:success]
end
```

**Step 2: Run tests to verify they fail**

Run: `bundle exec rails test test/lib/arnold_pipeline/verification_runner_test.rb -n /required flag/ -v 2>&1 | tail -10`
Expected: 2 failures — `required` key is nil because `run_check` doesn't include it.

**Step 3: Add `required:` to both result hashes**

In `lib/arnold_pipeline/verification_runner.rb`, add `required: check.required?` to the success result hash (line 51-59) after `duration_ms:`:

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
        stdout: capture_output(check.type, stdout, STDOUT_CAP),
        stderr: capture_output(check.type, stderr, STDERR_CAP),
        duration_ms: duration_ms,
        required: check.required?
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
        duration_ms: duration_ms,
        required: check.required?
      }
    end
```

Note: This step also replaces `tail_capture` calls with `capture_output` — implement that in Task 2. For now, just add the `required:` line to the existing hashes without changing capture calls.

Actually, to keep Task 1 atomic: only add `required: check.required?` to both hashes. Don't change the capture calls yet.

**Step 4: Run tests to verify they pass**

Run: `bundle exec rails test test/lib/arnold_pipeline/verification_runner_test.rb -v 2>&1 | tail -10`
Expected: All tests pass including the 2 new ones.

**Step 5: Commit**

```
git add lib/arnold_pipeline/verification_runner.rb test/lib/arnold_pipeline/verification_runner_test.rb
git commit -m "fix(verification): propagate required flag into check result hash [SPEC-VCHECK-007]"
```

---

### Task 2: Add smart capture strategy per check type

**Files:**
- Modify: `lib/arnold_pipeline/verification_runner.rb:117-123`
- Test: `test/lib/arnold_pipeline/verification_runner_test.rb`

The current `tail_capture` keeps the last N chars — correct for test output (summary at bottom) but wrong for boot errors (exception at top). Add `head_and_tail_capture` and route based on check type.

**Step 1: Write the failing tests**

Add at the end of the test file (before final `end`s):

```ruby
test "boot check preserves error message at top of stderr" do
  boot_script = File.join(@tmpdir, "boot_fail.sh")
  # Simulate boot error: exception at top, long stack trace filling the rest
  error_line = "NameError: uninitialized constant UsersController"
  stack_lines = (1..200).map { |i| "\tfrom /app/lib/file#{i}.rb:#{i}:in `method_#{i}'" }.join("\n")
  File.write(boot_script, "#!/bin/bash\necho '#{error_line}' >&2\necho '#{stack_lines}' >&2\nexit 1\n")
  FileUtils.chmod(0o755, boot_script)

  checks = [
    VerificationCheck.new(name: "Boot check", command: boot_script, type: :boot, required: true)
  ]

  result = VerificationRunner.call(repo_path: @tmpdir, checks: checks)

  stderr = result[:checks][0][:stderr]
  # The actual error message at the TOP must be preserved
  assert_includes stderr, "NameError: uninitialized constant UsersController"
end

test "test_suite check preserves summary at bottom of stdout" do
  test_script = File.join(@tmpdir, "test_fail.sh")
  # Simulate test output: loading noise at top, summary at bottom
  noise = (1..200).map { |i| "Loading test_#{i}..." }.join("\n")
  summary = "14 runs, 28 assertions, 2 failures, 0 errors, 0 skips"
  File.write(test_script, "#!/bin/bash\necho '#{noise}'\necho '#{summary}'\nexit 1\n")
  FileUtils.chmod(0o755, test_script)

  checks = [
    VerificationCheck.new(name: "Test suite", command: test_script, type: :test_suite, required: false)
  ]

  result = VerificationRunner.call(repo_path: @tmpdir, checks: checks)

  stdout = result[:checks][0][:stdout]
  # The summary at the BOTTOM must be preserved
  assert_includes stdout, summary
end

test "head_and_tail_capture preserves both ends when output exceeds cap" do
  runner = VerificationRunner.new(repo_path: @tmpdir, checks: [])
  head = "ERROR: Something went wrong\n"
  middle = "x" * 3000
  tail = "\nLast relevant line"
  output = head + middle + tail

  result = runner.send(:head_and_tail_capture, output, 200)

  assert result.length <= 200 + 20 # allow for truncation marker
  assert_includes result, "ERROR: Something went wrong"
  assert_includes result, "Last relevant line"
  assert_includes result, "...[truncated]..."
end

test "head_and_tail_capture returns output unchanged when under cap" do
  runner = VerificationRunner.new(repo_path: @tmpdir, checks: [])
  short = "just a short error"

  result = runner.send(:head_and_tail_capture, short, 200)

  assert_equal short, result
end
```

**Step 2: Run tests to verify they fail**

Run: `bundle exec rails test test/lib/arnold_pipeline/verification_runner_test.rb -n /head_and_tail|boot check preserves|test_suite check preserves/ -v 2>&1 | tail -15`
Expected: Failures — `head_and_tail_capture` method doesn't exist yet, and boot check uses tail_capture which truncates the error.

**Step 3: Implement head_and_tail_capture and capture routing**

Replace lines 117-123 in `lib/arnold_pipeline/verification_runner.rb`:

```ruby
    # Route capture strategy based on check type.
    # Test suites: keep tail (failure summary at bottom).
    # Everything else: keep head+tail (exception at top, context at bottom).
    def capture_output(check_type, output, cap)
      if check_type == :test_suite
        tail_capture(output, cap)
      else
        head_and_tail_capture(output, cap)
      end
    end

    # Keep the LAST n characters — test failure summaries appear at the end.
    def tail_capture(output, cap)
      return output if output.length <= cap
      output[-cap, cap]
    end

    # Keep the FIRST n/2 and LAST n/2 characters — boot/solid_stack errors
    # have the exception at the top and recent context at the bottom.
    def head_and_tail_capture(output, cap)
      return output if output.length <= cap

      half = cap / 2
      output[0, half] + "\n...[truncated]...\n" + output[-half, half]
    end
```

Then update `run_check` lines 56-57 to use `capture_output`:

```ruby
        stdout: capture_output(check.type, stdout, STDOUT_CAP),
        stderr: capture_output(check.type, stderr, STDERR_CAP),
```

**Step 4: Run tests to verify they pass**

Run: `bundle exec rails test test/lib/arnold_pipeline/verification_runner_test.rb -v 2>&1 | tail -10`
Expected: All tests pass including the 4 new ones and all existing ones (regression check — the existing tail_capture tests still pass because test_suite checks still use tail_capture).

**Step 5: Commit**

```
git add lib/arnold_pipeline/verification_runner.rb test/lib/arnold_pipeline/verification_runner_test.rb
git commit -m "fix(verification): smart capture per check type — head+tail for boot, tail for tests [SPEC-VCHECK-007]"
```

---

### Task 3: Broaden extract_test_output to extract_verification_output

**Files:**
- Modify: `lib/arnold_pipeline/tier_execution_engine.rb:1009-1020` and `1043-1044`
- Test: `test/lib/arnold_pipeline/tier_execution_engine_test.rb:2428-2466`

**Step 1: Write the failing tests**

Replace the existing `extract_test_output` tests (lines 2428-2466) and add new ones:

```ruby
# --- extract_verification_output ---

test "extract_verification_output returns nil when verification_results is nil" do
  result = @engine.send(:extract_verification_output, nil)
  assert_nil result
end

test "extract_verification_output extracts test_suite output" do
  verification_results = {
    checks: [
      { name: "Test suite", type: :test_suite, success: false, exit_code: 1,
        stdout: "FAIL test_something\nExpected 1 got 2", stderr: "" }
    ]
  }
  result = @engine.send(:extract_verification_output, verification_results)
  assert_includes result, "### Test suite (FAILED, exit code 1)"
  assert_includes result, "FAIL test_something"
end

test "extract_verification_output extracts boot check output" do
  verification_results = {
    checks: [
      { name: "Boot check", type: :boot, success: false, required: true, exit_code: 1,
        stdout: "", stderr: "NameError: uninitialized constant UsersController" }
    ]
  }
  result = @engine.send(:extract_verification_output, verification_results)
  assert_includes result, "### Boot check (FAILED, exit code 1)"
  assert_includes result, "NameError: uninitialized constant UsersController"
end

test "extract_verification_output includes all failed checks" do
  verification_results = {
    checks: [
      { name: "Bundle install", type: :custom, success: true, exit_code: 0,
        stdout: "ok", stderr: "" },
      { name: "Boot check", type: :boot, success: false, required: true, exit_code: 1,
        stdout: "", stderr: "LoadError: cannot load file" },
      { name: "Test suite", type: :test_suite, success: false, exit_code: 1,
        stdout: "2 failures", stderr: "" }
    ]
  }
  result = @engine.send(:extract_verification_output, verification_results)
  assert_includes result, "### Boot check (FAILED, exit code 1)"
  assert_includes result, "LoadError: cannot load file"
  assert_includes result, "### Test suite (FAILED, exit code 1)"
  assert_includes result, "2 failures"
  # Passing checks should NOT appear
  refute_includes result, "Bundle install"
end

test "extract_verification_output returns nil when all checks pass" do
  verification_results = {
    checks: [
      { name: "Boot check", type: :boot, success: true, exit_code: 0,
        stdout: "OK", stderr: "" }
    ]
  }
  result = @engine.send(:extract_verification_output, verification_results)
  assert_nil result
end

test "extract_verification_output truncates individual check output to 3000 chars" do
  long_output = "x" * 5000
  verification_results = {
    checks: [
      { name: "Test suite", type: :test_suite, success: false, exit_code: 1,
        stdout: long_output, stderr: "" }
    ]
  }
  result = @engine.send(:extract_verification_output, verification_results)
  # Total result should be reasonable (header + 3000 chars max per check)
  assert result.length < 3200
end
```

**Step 2: Run tests to verify they fail**

Run: `bundle exec rails test test/lib/arnold_pipeline/tier_execution_engine_test.rb -n /extract_verification_output/ -v 2>&1 | tail -15`
Expected: `NoMethodError: undefined method 'extract_verification_output'`

**Step 3: Implement extract_verification_output**

Replace lines 1009-1020 in `lib/arnold_pipeline/tier_execution_engine.rb`:

```ruby
    def extract_verification_output(verification_results)
      return nil unless verification_results

      failed_checks = verification_results[:checks]&.select { |c| !c[:success] }
      return nil if failed_checks.blank?

      sections = failed_checks.map do |c|
        output = [c[:stdout], c[:stderr]].compact.reject(&:empty?).join("\n")
        next if output.strip.empty?

        truncated = output.length > 3000 ? output[-3000..] : output
        "### #{c[:name]} (FAILED, exit code #{c[:exit_code]})\n#{truncated}"
      end.compact

      return nil if sections.empty?

      sections.join("\n\n")
    end
```

Then update line 1044 to change the section header from `## Test Output` to `## Verification Output`:

```ruby
      if verification_output.present?
        sections << "## Verification Output\n#{verification_output}"
      end
```

Also update the caller at line 540 — rename `extract_test_output` to `extract_verification_output`:

```ruby
            verification_output: extract_verification_output(verification_results)
```

Search for all references to `extract_test_output` in the file and rename them to `extract_verification_output`.

**Step 4: Update the build_corrective_description test**

In the existing test at line 2470-2484, update `"## Test Output"` to `"## Verification Output"`:

```ruby
test "build_corrective_description includes verification output when provided" do
  verification_output = "### Test suite (FAILED, exit code 1)\n1 runs, 0 assertions, 1 failures\nFAIL UserTest#test_validates_email\nExpected nil to not be nil"

  result = @engine.send(:build_corrective_description,
    base_description: "Fix the failing tests",
    gate_issues: ["test failures"],
    original_tier_tasks: [],
    acceptance_criteria_summary: nil,
    verification_output: verification_output
  )

  assert_includes result, "## Verification Output"
  assert_includes result, "FAIL UserTest#test_validates_email"
  assert_includes result, "Expected nil to not be nil"
end

test "build_corrective_description omits verification output when nil" do
  result = @engine.send(:build_corrective_description,
    base_description: "Fix the failing tests",
    gate_issues: ["test failures"],
    original_tier_tasks: [],
    acceptance_criteria_summary: nil,
    verification_output: nil
  )

  refute_includes result, "## Verification Output"
end
```

**Step 5: Run tests to verify they pass**

Run: `bundle exec rails test test/lib/arnold_pipeline/tier_execution_engine_test.rb -v 2>&1 | tail -10`
Expected: All tests pass including the new and updated ones.

**Step 6: Commit**

```
git add lib/arnold_pipeline/tier_execution_engine.rb test/lib/arnold_pipeline/tier_execution_engine_test.rb
git commit -m "fix(tier_engine): extract all failed check output for corrective tasks [SPEC-VCHECK-007]"
```

---

### Task 4: Run full test suite and verify

**Step 1: Run the full test suite**

Run: `bundle exec rails test 2>&1 | tail -5`
Expected: All tests pass (1363+ runs, 0 failures, 0 errors).

**Step 2: Verify no regressions**

Specifically check that existing tier gate and verification tests still pass:
Run: `bundle exec rails test test/lib/arnold_pipeline/tier_execution_engine_test.rb test/lib/arnold_pipeline/verification_runner_test.rb -v 2>&1 | tail -5`

**Step 3: Final commit if any fixups needed**

If any tests needed adjustment, commit the fixes.
