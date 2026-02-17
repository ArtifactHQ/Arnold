# Design: Color-Coded Log Output for `arnold log`

**Date:** 2026-02-17
**Status:** Approved

## Problem

The current `arnold log` command outputs a flat chronological list of events. With 77+ events in a typical run, scanning to answer "what went wrong?" requires reading every line. Passes, failures, tier boundaries, and analysis decisions all share the same visual weight.

## Design Decisions

- **Full restructure** of log output (not just color overlay on existing format)
- **Separate `LogFormatter` class** extracted from CLI (~750 lines already)
- **Custom ANSI color module** (no gem dependency, supports backgrounds/bold/dim)

## Architecture

### 1. AnsiColor Module

`lib/arnold_pipeline/ansi_color.rb` — small module with composable styling methods:

- `bold`, `dim`, `red`, `green`, `yellow`, `cyan`, `magenta`
- `bg_green` (green bg, black text), `bg_red` (red bg, white text)
- Composable via nesting: `bold(red("text"))`
- All methods return plain text when color disabled

Color gating:
- `$stdout.tty?` — no ANSI codes when piped
- `ENV['NO_COLOR']` — [no-color.org](https://no-color.org) convention
- `--no-color` CLI flag — explicit override

### 2. LogFormatter Class

`lib/arnold_pipeline/log_formatter.rb` — takes events + options, produces formatted output.

**Interface:**
```ruby
LogFormatter.new(events, color: true, verbose: false).render
# Returns a single string with the full formatted output
```

**Responsibilities:**
1. Group events into tier blocks, analysis blocks, and preamble
2. Render each block with appropriate headers and separators
3. Format individual events by type into compact colored lines
4. Render terminal banner (pipeline completed/failed)

### 3. Output Structure

```
Pipeline Run #67
2026-02-17

  05:12:50  library      persona=General Analyst  recipe=Generic  domain=PRODUCTIVITY
  05:13:47  spec         ✓ v1 generated (29,296 chars) (57.0s)
  05:14:42  tasks        ✓ 12 tasks → 9 tiers (18 deps) (55.1s)

──────────────────────────────────────────────────────────────────────
▶ TIER 0  (1 task)
  • Project bootstrap: create Rails 8 app with SQLite, Tailwind...
  05:16:28  tasks        ✓ 1 passed
  05:16:30  hooks        2/2 triggered OK
  05:16:32  verify        PASS   4 passed, 0 failed
  05:16:32  criteria     6/7 unmet (advisory)
  05:16:32  gate          PASS   via verification_tests_passed

──────────────────────────────────────────────────────────────────────
◆ ANALYSIS (iteration 1) (54.6s)
  06:05:56  decision     ↻ iterate_tasks  confidence=80%
  06:05:56  outcome      ↻ iterate_tasks → 8 corrective tasks

 ✓ PIPELINE COMPLETED   2 iterations, 8 tasks
```

### 4. Color Assignments

| Element | Color | Rationale |
|---|---|---|
| Timestamps | Dim (gray) | Present but not primary signal |
| PASS badge | Green background, black text | Unmistakable positive |
| FAIL badge | Red background, white text | Unmistakable negative |
| Task success (✓ N passed) | Green text | Consistent with pass |
| Task failure (✗ N failed) | Red text | Consistent with fail |
| Gate failure detail (↳) | Red text, indented | Tied to fail badge above |
| Criteria (advisory) | Yellow text + dim "(advisory)" | Warning level |
| Hooks (OK) | Green text | Passed |
| Hooks (none triggered) | Dim text | Non-event |
| Repo scan | Dim text | Context, not verdict |
| Tier header (▶ TIER N) | Bold magenta | Block boundary marker |
| Analysis header (◆) | Bold bright cyan | Distinct from tier headers |
| Decision: done | Green bold ✓ | Terminal positive |
| Decision: iterate_tasks | Yellow bold ↻ | Loop continuing |
| Pipeline COMPLETED | Green background banner | Terminal success |
| Pipeline FAILED | Red background banner | Terminal failure |
| Stage labels | Fixed-width, muted stage color | Subtle grouping |

### 5. CLI Integration

New `--no-color` flag on the `log` command. Command delegates to `LogFormatter`:

```ruby
def log(id)
  # ...existing setup/validation...
  formatter = LogFormatter.new(
    events,
    pipeline_run: run_record,
    color: color_enabled?,
    verbose: options[:verbose]
  )
  puts formatter.render
end
```

`--json` path unchanged (no ANSI codes in JSON output).

### 6. Event Type → Label Mapping

Events are rendered with short stage-like labels instead of raw event_type names:

| Event Type | Label | Block |
|---|---|---|
| library_selection | `library` | preamble |
| spec_generated | `spec` | preamble |
| tasks_broken | `tasks` | preamble |
| tier_execution_started | (tier header) | tier block |
| tier_execution_completed | `tasks` | tier block |
| post_merge_hooks | `hooks` | tier block |
| verification_execution / verification_checks | `verify` | tier block |
| criteria_check | `criteria` | tier block |
| repo_context_scanned | `scan` | tier block |
| tier_gate_evaluated | `gate` | tier block |
| analysis_completed | `decision` | analysis block |
| iteration_decision | `outcome` | analysis block |
| spec_delta_merged | `spec` | analysis block |
| pipeline_completed | (terminal banner) | terminal |
| pipeline_failed | (terminal banner) | terminal |
| pipeline_paused | (terminal banner) | terminal |

### 7. Testing

- Unit tests for `LogFormatter` with color disabled
- Tests for each event type's formatted output
- Test for `--no-color` flag behavior
- Test for `NO_COLOR` env var behavior
- Test for tier grouping logic
- Test for terminal banner rendering
- Existing CLI log tests updated to match new output format
