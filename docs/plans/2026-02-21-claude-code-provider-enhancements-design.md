# Claude Code Provider Enhancements — Design Document

**Date:** 2026-02-21
**Status:** Approved
**Spec items:** SPEC-PROVIDER-001 (new), SPEC-EXEC-001 (update)

## Motivation

The Claude Code execution provider (`lib/arnold_pipeline/providers/execution/claude_code.rb`) handles the provider conformance contract well but treats Claude Code as a black-box subprocess. It passes `--output-format json` but never parses the JSON output. It jams behavioral instructions and task content into one prompt. It doesn't leverage Claude Code's native `CLAUDE.md` auto-loading, system prompt separation, or tool restrictions.

These enhancements improve code quality produced by the pipeline, provide execution observability (cost, turns, timing per task), and make the provider extensible as the Library system grows with new personas, domains, and recipes.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Execution metadata in contract | Loose hash (optional `:execution_metadata` key) | Providers populate provider-specific keys; orchestrator acts on known keys like `cost_usd`. No rigid schema forced across fundamentally different providers. |
| System prompt strategy | `--append-system-prompt` | Preserves Claude Code's built-in tool usage and safety instructions. Adds behavioral instructions on top. |
| CLAUDE.md generation | `ClaudeMdGenerator` service, Ruby method (not ERB) | Pulls from Library::Persona, Recipe, DomainType YAML. New YAML additions flow through automatically without code changes. |
| Tool restrictions | Full control via config (`--tools`, `--allowedTools`, `--disallowedTools`) | Maximum flexibility. All three nil by default — users opt in. |
| Guardrails | `max_turns` default 25 + optional `max_budget_usd` | 25 turns gives room for implement-test-fix loops without runaway spending. Budget is per-task via `--max-budget-usd`. |
| CLAUDE.md placement | Root `CLAUDE.md` if repo doesn't have one; `.claude/CLAUDE.md` if it does | Claude Code loads both additively. Repo's own instructions are never overwritten. |

## Architecture

### Layer 1: Contract Extension

`fetch_results` return elements may include an optional `:execution_metadata` key:

```ruby
{
  task_id: 42,
  external_id: "cc-1-42",
  diffs: [...],
  comments: [...],
  status: :completed,
  workflow_active: false,
  execution_metadata: {          # Optional — provider-specific, opaque to framework
    cost_usd: 0.034,             # Claude Code: from total_cost_usd
    duration_ms: 28470,          # Claude Code: from duration_ms
    num_turns: 12,               # Claude Code: from num_turns
    model: "sonnet",             # Claude Code: from provider config
    session_id: "abc-123"        # Claude Code: from session_id
  }
}
```

- Stored on task record via new `execution_metadata` json column (same pattern as `result_comments`).
- Executor stores it when present; ignores when absent.
- GitHub provider continues returning nil/omitting — valid behavior.
- SharedProviderTests gets one optional-field test.
- Conformance checklist gets a new optional section.

### Layer 2: JSON Output Parsing

New `parse_claude_output` private method parses the JSON from `claude --print --output-format json`:

```ruby
def parse_claude_output(raw_output)
  parsed = JSON.parse(raw_output)
  {
    result: parsed["result"],
    cost_usd: parsed["total_cost_usd"],
    duration_ms: parsed["duration_ms"],
    num_turns: parsed["num_turns"],
    session_id: parsed["session_id"],
    is_error: parsed["is_error"],
    subtype: parsed["subtype"]
  }
rescue JSON::ParserError
  { result: raw_output, cost_usd: nil, duration_ms: nil, num_turns: nil }
end
```

Integration:
- `execute_claude_code` calls `parse_claude_output`, stores parsed data alongside existing result.
- `execute_work_item` adds `:parsed` key to `@results` storage.
- `fetch_results` populates `execution_metadata:` from parsed data.
- On failure: populates `comments:` with Claude's final message (`parsed[:result]`) so the analysis agent sees *why* the task failed.

Failure comment format:
```ruby
comments: [
  { "source" => "claude_code", "author" => "claude",
    "body" => "Task failed: #{parsed[:result]}" }
]
```

### Layer 3: Prompt Restructuring

Split the current monolithic prompt into three layers:

**`--append-system-prompt` — behavioral instructions (how to act):**
```
You are an implementation agent in an automated pipeline.
Complete the task fully without asking questions.
Make reasonable decisions and document assumptions in code comments.
Run the project's test suite after implementing changes. If tests fail, fix them.
Only commit once tests pass.
Do not create project subdirectories — work in the current directory.
Do not run `git init` — this directory is already tracked by git.
If scaffolding a Rails app, use `rails new . --force` (dot = current dir).
Commit all changes when finished.
```

This is a private `system_prompt` method. Working directory rules and test-running instructions move here from `build_prompt`.

**CLAUDE.md — project context (what you're building with):**

Auto-loaded by Claude Code from the worktree. Generated by `ClaudeMdGenerator` (see below).

**`build_prompt` — task content only (what to do):**

```ruby
def build_prompt(title:, description:, labels:, prior_context:)
  context_section = if prior_context
    <<~CTX
      ## Prior Implementation Context
      Previous tiers have already implemented and merged code into this repository.
      You can see their work in the existing files. Here is a summary:

      #{prior_context}

      Build on top of existing code. Do not rewrite or duplicate what already exists.
    CTX
  else
    "This is the first implementation tier. Start from the project's current state."
  end

  <<~PROMPT
    ## Task
    **#{title}**
    #{description}
    #{"Labels: #{Array(labels).join(', ')}" if Array(labels).any?}

    #{context_section}
  PROMPT
end
```

### Layer 4: ClaudeMdGenerator Service

**Location:** `lib/arnold_pipeline/services/claude_md_generator.rb`

**Interface:**
```ruby
ClaudeMdGenerator.call(persona:, recipe:, domain_type:) # => String
```

Assembles CLAUDE.md from Library data structures:

| Section | Source |
|---------|--------|
| `## Tech Stack` | `recipe.framework` (all key/value pairs) |
| `## Conventions` | `recipe.sections[].guidance` (flattened) |
| `## Testing` | `recipe.verification` (test_command, setup_commands, boot_command, health_checks) |
| `## Domain Context` | `domain_type.name`, `domain_type.primary_value`, `domain_type.emphasis` |
| `## Terminology` | `domain_type.terminology` (term mappings) |
| `## Watch For` | `domain_type.watch_for` |

Key properties:
- **No hardcoded content.** Every section is driven by YAML data. Missing fields produce omitted sections.
- **Nil-safe.** Works with all-generic/fallback inputs, producing a minimal valid CLAUDE.md.
- **Extensible.** New recipes with new `framework` keys or new domain types with new `terminology` entries automatically appear without code changes.

### Layer 5: Data Flow — Library Selections to Provider

**Step 1: Orchestrator stores selections on pipeline_run.**

In `generate_spec!`, after library matching:

```ruby
pipeline_run.metadata["library_selections"] = {
  "persona" => persona&.name,
  "recipe" => recipe&.name,
  "supporting_recipes" => supporting_recipes&.map(&:name),
  "domain_type" => domain_type&.code
}
pipeline_run.save!
```

**Step 2: Provider reads selections in `create_tasks`.**

`create_tasks` reads `pipeline_run.metadata["library_selections"]`, instantiates a Library::Manager, and resolves names back to objects.

**Step 3: `setup_worktree` calls the generator.**

`write_claude_md!(worktree_path)` calls `ClaudeMdGenerator.call(...)` and writes the result. If the repo already has a root `CLAUDE.md`, writes to `.claude/CLAUDE.md` instead (additive loading).

### Layer 6: CLI Command Construction

Updated `build_cli_command`:

```ruby
def build_cli_command(prompt)
  cmd_parts = [
    "claude", "--print", "--output-format", "json",
    "--model", model,
    "--permission-mode", permission_mode,
    "--append-system-prompt", system_prompt
  ]
  cmd_parts += ["--max-turns", max_turns.to_s] if max_turns
  cmd_parts += ["--max-budget-usd", max_budget_usd.to_s] if max_budget_usd
  cmd_parts += tool_restriction_flags
  cmd_parts << prompt
  cmd_parts.shelljoin
end
```

Tool restriction flags (new private method):

```ruby
def tool_restriction_flags
  flags = []
  if tools = ArnoldPipeline.configuration.claude_code_tools
    flags += ["--tools", Array(tools).join(",")]
  end
  if allowed = ArnoldPipeline.configuration.claude_code_allowed_tools
    Array(allowed).each { |t| flags += ["--allowedTools", t] }
  end
  if disallowed = ArnoldPipeline.configuration.claude_code_disallowed_tools
    Array(disallowed).each { |t| flags += ["--disallowedTools", t] }
  end
  flags
end
```

### Layer 7: Configuration Changes

New attributes on `Configuration`:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `claude_code_max_budget_usd` | Float/nil | `nil` | Per-task dollar budget via `--max-budget-usd` |
| `claude_code_tools` | Array/nil | `nil` | Tool whitelist via `--tools` |
| `claude_code_allowed_tools` | Array/nil | `nil` | Auto-approve patterns via `--allowedTools` |
| `claude_code_disallowed_tools` | Array/nil | `nil` | Blocked tool patterns via `--disallowedTools` |

Default changes:

| Option | Old Default | New Default | Rationale |
|--------|-------------|-------------|-----------|
| `claude_code_max_turns` | `nil` (unlimited) | `25` | Prevents runaway spending while allowing implement-test-fix loops |

Validation in `validate_configuration!`:
- `claude_code_max_budget_usd`: nil or positive Numeric
- `claude_code_tools`, `claude_code_allowed_tools`, `claude_code_disallowed_tools`: nil or Array of Strings

## Files Changed

### New files

| File | Purpose |
|------|---------|
| `lib/arnold_pipeline/services/claude_md_generator.rb` | Generates CLAUDE.md from Library data |
| `test/lib/arnold_pipeline/services/claude_md_generator_test.rb` | Unit tests |
| `db/migrate/TIMESTAMP_add_execution_metadata_to_tasks.rb` | New json column on tasks |

### Modified files

| File | Changes |
|------|---------|
| `lib/arnold_pipeline/providers/execution/claude_code.rb` | JSON parsing, `--append-system-prompt`, tool flags, `--max-budget-usd`, default max_turns 25, `write_claude_md!`, enriched `fetch_results`, cleaner `build_prompt`, `resolve_library_selections` |
| `lib/arnold_pipeline/configuration.rb` | New attrs (`claude_code_max_budget_usd`, tool restriction attrs). Default change: `claude_code_max_turns` nil → 25. Validation for new attrs. |
| `lib/arnold_pipeline/executor.rb` | Store `execution_metadata` on task when present in fetch_results |
| `lib/arnold_pipeline/orchestrator.rb` | Store `library_selections` in `pipeline_run.metadata` during `generate_spec!` |
| `test/lib/arnold_pipeline/providers/execution/claude_code_test.rb` | Tests for all new behavior |
| `test/lib/arnold_pipeline/providers/execution/shared_provider_tests.rb` | Optional `execution_metadata` shape test |
| `docs/provider_conformance_checklist.md` | New optional section for execution_metadata, advisory for failure comments |
| `README.md` | Update config tables, add new options, update defaults, document CLAUDE.md generation and execution metadata |

### Unchanged

| File | Reason |
|------|--------|
| `lib/arnold_pipeline/providers/execution/base.rb` | Contract extension is additive (optional key) — no code change needed |
| `lib/arnold_pipeline/providers/execution/github.rb` | Continues returning nil/omitting execution_metadata — valid |
| `lib/arnold_pipeline/providers/execution/null.rb` | No changes needed |

## Risk Assessment

| Risk | Mitigation |
|------|------------|
| `max_turns` default change (nil → 25) could break existing workflows needing more turns | Config option remains. 25 is generous for single-task implementation. Documented in README. |
| JSON parsing failure on unexpected CLI version | `parse_claude_output` rescues `JSON::ParserError`, falls back to raw string |
| Library::Manager instantiation per `create_tasks` | Lightweight (reads cached YAML). One instantiation per tier, not per task. |
| Generated CLAUDE.md conflicts with repo's own | Explicitly handled: writes to `.claude/CLAUDE.md` when root file exists |
| New migration for `execution_metadata` column | Standard pattern, matches existing `result_comments` column |
| Tool restriction flags with wrong patterns | Validation checks Array of Strings. Invalid patterns are Claude CLI's problem to reject. |

## Conformance Checklist Updates

Add to section 2 (fetch_results):

```markdown
### Execution metadata (optional)

- [ ] Each element may include `:execution_metadata` (Hash or nil)
- [ ] `:execution_metadata` values are JSON-serializable
- [ ] Provider functions correctly when `:execution_metadata` is omitted or nil
```

Add to SharedProviderTests:

```ruby
test "fetch_results execution_metadata is nil or a Hash" do
  results = provider_instance.fetch_results(pipeline_run: @pipeline_run)
  results.each do |r|
    meta = r[:execution_metadata]
    assert(meta.nil? || meta.is_a?(Hash), "execution_metadata must be nil or Hash")
  end
end
```
