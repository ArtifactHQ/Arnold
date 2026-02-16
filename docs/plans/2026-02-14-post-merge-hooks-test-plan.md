# Test Plan: Post-Merge Hooks & Verification Checks

## Objective

Validate that the post-merge hooks and verification checks feature works end-to-end
in a real pipeline run, confirming that:
1. Hooks trigger on matching file patterns and commit derived files
2. Verification checks run after hooks and pass results to the tier gate
3. Required check failure short-circuits remaining checks
4. The tier gate receives and acts on verification results
5. Events are recorded in the audit trail
6. Backward compatibility: empty hooks/checks config runs cleanly

---

## Prerequisites

```bash
# Claude Code CLI installed
which claude  # must return a path

# API key set
echo $ANTHROPIC_API_KEY  # must be non-empty

# Create a fresh test repo
mkdir -p /tmp/arnold-test-repo && cd /tmp/arnold-test-repo
git init
git commit --allow-empty -m "Initial commit"
```

---

## Test 1: Full Pipeline Run (Happy Path)

### Config: `/tmp/arnold-test-config.yml`

```yaml
llm_provider: anthropic
execution_provider: claude_code
claude_code_repo_path: /tmp/arnold-test-repo
claude_code_model: sonnet
claude_code_max_turns: 25
claude_code_permission_mode: bypassPermissions
claude_code_max_concurrency: 2

max_iterations: 2
tier_gate_enabled: true
context_propagation_enabled: true
max_tier_retries: 1

post_merge_hooks:
  - name: "Regenerate schema"
    trigger_paths:
      - "db/migrate/**"
    command: "bin/rails db:prepare && bin/rails db:schema:dump"
    commit_paths:
      - "db/schema.rb"
    commit_message: "Regenerate schema.rb after tier merge"

  - name: "Bundle lock"
    trigger_paths:
      - "Gemfile"
    command: "bundle install --quiet"
    commit_paths:
      - "Gemfile.lock"
    commit_message: "Update Gemfile.lock after tier merge"

verification_checks:
  - name: "Boot check"
    command: "bin/rails runner 'puts :ok'"
    type: boot
    required: true

  - name: "Test suite"
    command: "bin/rails test"
    type: test_suite
    required: false

event_logging_enabled: true
verbose_event_logging: true
```

### Command

```bash
arnold run "Build a Rails 8 task manager app with a Task model (title:string, description:text, status:string, due_date:date), a TasksController with full CRUD, and a root route pointing to tasks#index. Use SQLite. Include model validations: title is required, status defaults to 'pending' and must be one of pending/in_progress/completed." \
  --config /tmp/arnold-test-config.yml \
  --verbose
```

### Why This NL Description

- **Multi-tier**: Generator + migration (tier 0), controller + views + routes (tier 1), validations + tests (tier 2)
- **Schema changes**: Migrations will trigger the "Regenerate schema" post-merge hook
- **Gemfile changes**: Likely triggers "Bundle lock" hook if gems are added
- **Boot-testable**: A Rails app with a model + controller + routes can boot and pass basic tests
- **Small enough**: 3-5 tasks, finishes in reasonable time (~5 min with Claude Code)

### Expected Results

| Check | Expected |
|-------|----------|
| Pipeline completes | Status: `completed` or `max_iterations_reached` |
| Post-merge hooks ran | `arnold log ID --stage execution` shows `post_merge_hooks` events |
| Schema hook triggered | Event payload shows `name: "Regenerate schema"`, `triggered: true` |
| Verification checks ran | `arnold log ID --stage execution` shows `verification_checks` events |
| Boot check passed | Event shows `all_passed: true` or boot check `success: true` |
| Test results in gate | Tier gate event payload includes verification_results |
| Repo has schema.rb | `cat /tmp/arnold-test-repo/db/schema.rb` shows generated schema |
| Auto-commit exists | `git log --oneline` shows "Regenerate schema.rb after tier merge" commit |

### Verification Commands

```bash
# Get the run ID from arnold output, then:
RUN_ID=<id>

# Check status
arnold status $RUN_ID

# Check events for hooks
arnold log $RUN_ID --stage execution --verbose

# Look for hook events
arnold log $RUN_ID --json | jq '.[] | select(.event_type == "post_merge_hooks")'

# Look for verification events
arnold log $RUN_ID --json | jq '.[] | select(.event_type == "verification_checks")'

# Check the repo for auto-committed schema
cd /tmp/arnold-test-repo
git log --oneline | head -20
cat db/schema.rb
```

---

## Test 2: Required Check Failure (Short-Circuit)

### Config: `/tmp/arnold-test-fail-config.yml`

```yaml
llm_provider: anthropic
execution_provider: claude_code
claude_code_repo_path: /tmp/arnold-test-repo-fail
claude_code_model: sonnet
claude_code_max_turns: 15
claude_code_permission_mode: bypassPermissions
claude_code_max_concurrency: 1

max_iterations: 1
tier_gate_enabled: true
max_tier_retries: 1

post_merge_hooks: []

verification_checks:
  - name: "Intentional boot failure"
    command: "bin/rails runner 'raise \"deliberate boot failure\"'"
    type: boot
    required: true

  - name: "Should be skipped"
    command: "echo 'this should never run'"
    type: test_suite
    required: false

event_logging_enabled: true
verbose_event_logging: true
```

### Setup

```bash
mkdir -p /tmp/arnold-test-repo-fail && cd /tmp/arnold-test-repo-fail
git init && git commit --allow-empty -m "Initial commit"
```

### Command

```bash
arnold run "Build a simple Ruby script that prints hello world" \
  --config /tmp/arnold-test-fail-config.yml \
  --stop-after executed \
  --verbose
```

### Expected Results

| Check | Expected |
|-------|----------|
| Boot check failed | Verification event shows `success: false` for "Intentional boot failure" |
| Second check skipped | Only 1 check in results (short-circuited) |
| `all_passed: false` | Verification results show overall failure |
| Gate sees failure | Tier gate event payload includes failed verification_results |
| Gate may create corrective tasks | If tier_gate_enabled, corrective tasks target boot fix |

### Verification

```bash
RUN_ID=<id>
arnold log $RUN_ID --json | jq '.[] | select(.event_type == "verification_checks") | .summary'
# Should show: all_passed: false, summary contains "FAIL"
# Should show only 1 check result (second was skipped)
```

---

## Test 3: Empty Config (Backward Compatibility)

### Config: `/tmp/arnold-test-empty-config.yml`

```yaml
llm_provider: anthropic
execution_provider: claude_code
claude_code_repo_path: /tmp/arnold-test-repo-empty
claude_code_model: sonnet
claude_code_permission_mode: bypassPermissions

max_iterations: 1
tier_gate_enabled: true

# Explicitly empty — no hooks, no checks
post_merge_hooks: []
verification_checks: []

event_logging_enabled: true
```

### Setup

```bash
mkdir -p /tmp/arnold-test-repo-empty && cd /tmp/arnold-test-repo-empty
git init && git commit --allow-empty -m "Initial commit"
```

### Command

```bash
arnold run "Create a Ruby file called hello.rb that prints hello world" \
  --config /tmp/arnold-test-empty-config.yml \
  --stop-after executed \
  --verbose
```

### Expected Results

| Check | Expected |
|-------|----------|
| Pipeline runs without error | No crashes from empty hooks/checks |
| No hook events | `arnold log ID --json` has no `post_merge_hooks` events |
| No verification events | `arnold log ID --json` has no `verification_checks` events |
| Gate runs normally | Gate check still runs (without verification_results) |

---

## Test 4: Hook Trigger Matching (Selective Triggering)

### Config: `/tmp/arnold-test-selective-config.yml`

```yaml
llm_provider: anthropic
execution_provider: claude_code
claude_code_repo_path: /tmp/arnold-test-repo-selective
claude_code_model: sonnet
claude_code_permission_mode: bypassPermissions

max_iterations: 1
tier_gate_enabled: true

post_merge_hooks:
  - name: "Only triggers on Python files"
    trigger_paths:
      - "**/*.py"
    command: "echo 'python hook ran'"
    commit_paths: []

  - name: "Only triggers on migrations"
    trigger_paths:
      - "db/migrate/**"
    command: "echo 'migration hook ran'"
    commit_paths: []

verification_checks: []
event_logging_enabled: true
verbose_event_logging: true
```

### Setup

```bash
mkdir -p /tmp/arnold-test-repo-selective && cd /tmp/arnold-test-repo-selective
git init && git commit --allow-empty -m "Initial commit"
```

### Command

```bash
arnold run "Create a Ruby file called calculator.rb with add and subtract methods" \
  --config /tmp/arnold-test-selective-config.yml \
  --stop-after executed \
  --verbose
```

### Expected Results

| Check | Expected |
|-------|----------|
| Python hook NOT triggered | Hook result shows `triggered: false` (no .py files changed) |
| Migration hook NOT triggered | Hook result shows `triggered: false` (no migrations) |
| No commits from hooks | `git log` shows no hook commit messages |
| Event recorded | `post_merge_hooks` event exists but shows no triggered hooks |

---

## Test 5: Unit Test Verification

Already validated — run to confirm current state:

```bash
cd /home/kyle/Documents/Projects/artifact/arnold_pipeline
bundle exec rails test 2>&1 | tail -5
# Expected: 938 runs, 2800 assertions, 0 failures, 0 errors, 0 skips
```

### Targeted test runs:

```bash
# Post-merge hook value object + runner
bundle exec rails test test/lib/arnold_pipeline/post_merge_hook_test.rb \
                       test/lib/arnold_pipeline/post_merge_hook_runner_test.rb
# Expected: 15 runs, 0 failures

# Verification check + runner
bundle exec rails test test/lib/arnold_pipeline/verification_check_test.rb \
                       test/lib/arnold_pipeline/verification_runner_test.rb
# Expected: 15 runs, 0 failures

# TierExecutionEngine integration
bundle exec rails test test/lib/arnold_pipeline/tier_execution_engine_test.rb
# Expected: All pass, includes new hook/check integration tests

# Tier gate check agent
bundle exec rails test test/lib/arnold_pipeline/agents/tier_gate_check_test.rb
# Expected: All pass, includes verification_results param tests

# Empirical validation integration
bundle exec rails test test/lib/arnold_pipeline/integration/empirical_validation_test.rb
# Expected: All pass
```

---

## Test 6: Event Audit Trail

After any successful run from Tests 1-4:

```bash
RUN_ID=<id>

# All events for the run
arnold log $RUN_ID --verbose

# Filter to execution stage (where hooks and checks run)
arnold log $RUN_ID --stage execution --verbose

# JSON output for programmatic inspection
arnold log $RUN_ID --json | jq '[.[] | .event_type] | unique'
# Should include: "post_merge_hooks", "verification_checks" (if configured)
# Should NOT include: "verification_execution", "test_execution" (deprecated)

# Check event payloads have correct structure
arnold log $RUN_ID --json | jq '.[] | select(.event_type == "verification_checks") | .payload'
# Expected structure: { checks: [...], all_passed: bool, summary: "..." }
```

---

## Test Matrix Summary

| Test | Hooks Config | Checks Config | Provider | Stop After | Key Validation |
|------|-------------|---------------|----------|------------|----------------|
| 1 | 2 hooks | 2 checks (1 required) | claude_code | full run | Happy path E2E |
| 2 | empty | 2 checks (required fails) | claude_code | executed | Short-circuit behavior |
| 3 | empty | empty | claude_code | executed | Backward compatibility |
| 4 | 2 hooks (won't match) | empty | claude_code | executed | Selective triggering |
| 5 | n/a | n/a | n/a | n/a | Unit tests (938 tests) |
| 6 | varies | varies | claude_code | varies | Event audit trail |

---

## Pass Criteria

- [ ] Test 5: All 938 unit tests pass (0 failures)
- [ ] Test 1: Pipeline completes, hooks fire on migration changes, verification results in gate
- [ ] Test 2: Required check failure short-circuits, gate sees failed verification
- [ ] Test 3: Empty config runs cleanly with no hook/check events
- [ ] Test 4: Hooks with non-matching patterns don't trigger
- [ ] Test 6: Event audit trail shows correct event types and payloads
- [ ] No deprecated event types (`verification_execution`, `test_execution`) appear in any run
