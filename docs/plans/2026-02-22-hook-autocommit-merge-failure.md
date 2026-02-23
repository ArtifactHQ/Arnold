# Hook Auto-Commit & Merge Failure Distinction Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Prevent post-merge hooks from leaving dirty files that block worktree merges, and report accurate failure reasons when merges fail.

**Architecture:** Extend PostMergeHookRunner to snapshot dirty state before hooks and auto-commit any newly dirty files after. Extend task_failure_reason to check result_comments for merge error markers.

**Tech Stack:** Ruby, Minitest, Mocha stubs, git CLI

---

### Task 1: Auto-commit dirty files after post-merge hooks

**Files:**
- Modify: `lib/arnold_pipeline/post_merge_hook_runner.rb`
- Test: `test/lib/arnold_pipeline/post_merge_hook_runner_test.rb`

**Step 1: Write the failing tests**

Add these tests to the end of the existing `PostMergeHookRunnerTest` class in `test/lib/arnold_pipeline/post_merge_hook_runner_test.rb` (before the final two `end` statements):

```ruby
test "auto-commits files dirtied by hook but not listed in commit_paths" do
  # Create a script that generates TWO derived files
  script_path = File.join(@tmpdir, "generate.sh")
  File.write(script_path, "#!/bin/sh\necho 'listed' > listed.txt\necho 'unlisted' > unlisted.txt\n")
  File.chmod(0o755, script_path)
  system("git", "-C", @tmpdir, "add", "generate.sh")
  system("git", "-C", @tmpdir, "commit", "-m", "add script", "--no-verify", out: File::NULL, err: File::NULL)

  hook = PostMergeHook.new(
    name: "generate",
    trigger_paths: ["*.rb"],
    command: "./generate.sh",
    commit_paths: ["listed.txt"],
    commit_message: "chore: update listed file"
  )

  results = PostMergeHookRunner.call(
    repo_path: @tmpdir,
    changed_files: ["app.rb"],
    hooks: [hook]
  )

  assert results.first[:success]

  # Working tree should be clean — both files committed
  status_output, = Open3.capture3("git", "status", "--porcelain", chdir: @tmpdir)
  assert_empty status_output.strip, "Expected clean working tree but found: #{status_output}"

  # unlisted.txt should exist and be tracked
  assert File.exist?(File.join(@tmpdir, "unlisted.txt"))
  log_output, = Open3.capture3("git", "log", "--oneline", "-1", chdir: @tmpdir)
  assert_includes log_output, "Auto-commit"
end

test "auto-commit result includes list of unexpected files" do
  script_path = File.join(@tmpdir, "generate.sh")
  File.write(script_path, "#!/bin/sh\necho 'a' > extra_a.txt\necho 'b' > extra_b.txt\n")
  File.chmod(0o755, script_path)
  system("git", "-C", @tmpdir, "add", "generate.sh")
  system("git", "-C", @tmpdir, "commit", "-m", "add script", "--no-verify", out: File::NULL, err: File::NULL)

  hook = PostMergeHook.new(
    name: "generate",
    trigger_paths: ["*.rb"],
    command: "./generate.sh"
    # No commit_paths — all files are "unexpected"
  )

  results = PostMergeHookRunner.call(
    repo_path: @tmpdir,
    changed_files: ["app.rb"],
    hooks: [hook]
  )

  assert results.first[:success]
  assert_includes results.first[:auto_committed], "extra_a.txt"
  assert_includes results.first[:auto_committed], "extra_b.txt"
end

test "does not auto-commit files that were already dirty before hook ran" do
  # Create a pre-existing dirty file
  File.write(File.join(@tmpdir, "preexisting.txt"), "dirty before hook")

  script_path = File.join(@tmpdir, "generate.sh")
  File.write(script_path, "#!/bin/sh\necho 'new' > hook_output.txt\n")
  File.chmod(0o755, script_path)
  system("git", "-C", @tmpdir, "add", "generate.sh")
  system("git", "-C", @tmpdir, "commit", "-m", "add script", "--no-verify", out: File::NULL, err: File::NULL)

  hook = PostMergeHook.new(
    name: "generate",
    trigger_paths: ["*.rb"],
    command: "./generate.sh"
  )

  results = PostMergeHookRunner.call(
    repo_path: @tmpdir,
    changed_files: ["app.rb"],
    hooks: [hook]
  )

  assert results.first[:success]

  # hook_output.txt should be auto-committed
  assert_includes results.first[:auto_committed], "hook_output.txt"

  # preexisting.txt should still be dirty (not auto-committed)
  status_output, = Open3.capture3("git", "status", "--porcelain", chdir: @tmpdir)
  assert_includes status_output, "preexisting.txt"
end

test "no auto-commit when hook leaves no new dirty files" do
  hook = PostMergeHook.new(
    name: "clean",
    trigger_paths: ["*.rb"],
    command: "echo clean"
  )

  before_log, = Open3.capture3("git", "rev-list", "--count", "HEAD", chdir: @tmpdir)

  results = PostMergeHookRunner.call(
    repo_path: @tmpdir,
    changed_files: ["app.rb"],
    hooks: [hook]
  )

  after_log, = Open3.capture3("git", "rev-list", "--count", "HEAD", chdir: @tmpdir)
  assert_equal before_log.strip, after_log.strip
  assert_empty results.first[:auto_committed] || []
end
```

**Step 2: Run tests to verify they fail**

Run: `bundle exec rails test test/lib/arnold_pipeline/post_merge_hook_runner_test.rb -n "/auto.commit/"`
Expected: FAIL — `auto_committed` key doesn't exist, auto-commit behavior not implemented

**Step 3: Implement auto-commit in PostMergeHookRunner**

In `lib/arnold_pipeline/post_merge_hook_runner.rb`, replace the `run_hook` method (lines 25-51) and `commit_derived_files` method (lines 53-63), and add new private methods:

```ruby
def run_hook(hook)
  unless hook.triggered_by?(@changed_files)
    return { name: hook.name, triggered: false, success: nil, stdout: nil, stderr: nil, exit_code: nil }
  end

  pre_hook_dirty = current_dirty_files

  stdout, stderr, status = Bundler.with_unbundled_env do
    Open3.capture3(hook.command, chdir: @repo_path)
  end

  result = {
    name: hook.name,
    triggered: true,
    success: status.success?,
    stdout: truncate(stdout),
    stderr: truncate(stderr),
    exit_code: status.exitstatus
  }

  if status.success?
    commit_derived_files(hook) if hook.commit_paths.any?
    result[:auto_committed] = auto_commit_remaining!(hook, pre_hook_dirty)
  end

  result
rescue => e
  @logger&.error("PostMergeHookRunner: hook '#{hook.name}' raised #{e.class}: #{e.message}")
  { name: hook.name, triggered: true, success: false, error: e.message }
end

def commit_derived_files(hook)
  hook.commit_paths.each do |path|
    system("git", "add", path, chdir: @repo_path)
  end

  # Only commit if there are staged changes
  _, _, diff_status = Open3.capture3("git", "diff", "--cached", "--quiet", chdir: @repo_path)
  return if diff_status.success?

  system("git", "commit", "-m", hook.commit_message, "--no-verify", chdir: @repo_path)
end

def auto_commit_remaining!(hook, pre_hook_dirty)
  post_hook_dirty = current_dirty_files
  newly_dirty = post_hook_dirty - pre_hook_dirty
  return [] if newly_dirty.empty?

  @logger&.warn("[Arnold] Hook '#{hook.name}' modified files not in commit_paths: #{newly_dirty.join(', ')}. Auto-committing.")

  newly_dirty.each do |path|
    system("git", "add", path, chdir: @repo_path)
  end

  system("git", "commit", "-m", "Auto-commit files modified by hook '#{hook.name}'", "--no-verify", chdir: @repo_path)
  newly_dirty
end

def current_dirty_files
  output, = Open3.capture3("git", "status", "--porcelain", chdir: @repo_path)
  output.lines.map { |line| line[3..].strip }.reject(&:empty?)
end
```

**Step 4: Run tests to verify they pass**

Run: `bundle exec rails test test/lib/arnold_pipeline/post_merge_hook_runner_test.rb`
Expected: PASS — all existing tests still pass, new tests pass

**Step 5: Commit**

```bash
git add lib/arnold_pipeline/post_merge_hook_runner.rb test/lib/arnold_pipeline/post_merge_hook_runner_test.rb
git commit -m "fix(hooks): auto-commit files dirtied by post-merge hooks to prevent merge failures [SPEC-EXEC-001]"
```

---

### Task 2: Distinguish merge failures from empty diffs

**Files:**
- Modify: `lib/arnold_pipeline/tier_execution_engine.rb:173-180`
- Test: `test/lib/arnold_pipeline/tier_execution_engine_test.rb`

**Step 1: Write the failing tests**

Add these tests near the existing `task_failure_reason` tests (around line 2053) in `test/lib/arnold_pipeline/tier_execution_engine_test.rb`:

```ruby
test "task_failure_reason returns merge_failed for failed task with merge error comment" do
  pipeline_run = PipelineRun.create!(nl_input: "Build an app")
  task = pipeline_run.tasks.create!(
    title: "Merge Fail", position: 0, status: :failed, result_diff: "[]",
    result_comments: [{ "source" => "arnold", "author" => "system", "body" => "Merge failed: Your local changes would be overwritten" }]
  )

  assert_equal "merge_failed", @engine.send(:task_failure_reason, task)
end

test "task_failure_reason returns empty_diff for failed task with non-merge comments" do
  pipeline_run = PipelineRun.create!(nl_input: "Build an app")
  task = pipeline_run.tasks.create!(
    title: "Empty", position: 0, status: :failed, result_diff: "[]",
    result_comments: [{ "source" => "arnold", "author" => "system", "body" => "Some other error" }]
  )

  assert_equal "empty_diff", @engine.send(:task_failure_reason, task)
end

test "task_failure_reason returns merge_failed even when result_diff is nil" do
  pipeline_run = PipelineRun.create!(nl_input: "Build an app")
  task = pipeline_run.tasks.create!(
    title: "Merge Nil", position: 0, status: :failed, result_diff: nil,
    result_comments: [{ "source" => "arnold", "author" => "system", "body" => "Merge failed: conflict" }]
  )

  assert_equal "merge_failed", @engine.send(:task_failure_reason, task)
end
```

**Step 2: Run tests to verify they fail**

Run: `bundle exec rails test test/lib/arnold_pipeline/tier_execution_engine_test.rb -n "/merge_failed/"`
Expected: FAIL — returns "empty_diff" instead of "merge_failed"

**Step 3: Update task_failure_reason**

In `lib/arnold_pipeline/tier_execution_engine.rb`, replace `task_failure_reason` (lines 173-180):

```ruby
def task_failure_reason(task)
  return nil unless task.failed?

  if task.result_comments&.any? { |c| c["body"]&.start_with?("Merge failed:") }
    "merge_failed"
  elsif task.result_diff.blank? || task.result_diff == "[]"
    "empty_diff"
  else
    "execution_error"
  end
end
```

**Step 4: Run tests to verify they pass**

Run: `bundle exec rails test test/lib/arnold_pipeline/tier_execution_engine_test.rb -n "/task_failure_reason/"`
Expected: PASS — all 7 task_failure_reason tests pass (4 existing + 3 new)

**Step 5: Commit**

```bash
git add lib/arnold_pipeline/tier_execution_engine.rb test/lib/arnold_pipeline/tier_execution_engine_test.rb
git commit -m "fix(tier_gate): distinguish merge failures from empty diffs in task_failure_reason [SPEC-EXEC-001]"
```

---

### Task 3: Run full test suite and verify

**Step 1: Run the full test suite**

Run: `bundle exec rails test`
Expected: 1340+ tests, 0 failures, 0 errors (except the pre-existing ConfigurationTest)

**Step 2: Verify hook runner tests specifically**

Run: `bundle exec rails test test/lib/arnold_pipeline/post_merge_hook_runner_test.rb`
Expected: All pass

**Step 3: Verify tier engine tests specifically**

Run: `bundle exec rails test test/lib/arnold_pipeline/tier_execution_engine_test.rb`
Expected: All pass

---

### Task 4: Update MEMORY.md

**Files:**
- Modify: `/home/kyle/.claude/projects/-home-kyle-Documents-Projects-artifact-arnold-pipeline/memory/MEMORY.md`

Add to the "Claude Code Execution Provider" section:
- `PostMergeHookRunner` auto-commits files dirtied by hooks not listed in `commit_paths` — prevents dirty working directory merge failures
- `task_failure_reason` now returns `"merge_failed"` (not `"empty_diff"`) when `result_comments` contain `"Merge failed:"` prefix
- Pipeline #94 root cause: `db:prepare` dirtied solid schema files not in `commit_paths`, blocking 28/37 merges
