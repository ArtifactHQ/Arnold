> **Reference document.** This is a planning document for future Arnold × Ralph integration. Not yet implemented. See `docs/` for current Arnold documentation.

---

# Arnold × Ralph Integration Plan

**Date:** 2026-03-16
**Author:** Chris Sotraidis + Claude
**Status:** Draft v2 — incorporating feedback
**Last updated:** 2026-03-16

---

## The Big Idea

Arnold owns **what to build** (structured docs organized by feature). Ralph owns **how to build it** (autonomous loop that spawns fresh AI agents to implement stories one at a time). Today, there's a manual gap between them: Arnold produces docs, and someone has to hand-craft a `prd.json` for Ralph to consume. This plan closes that gap with new Arnold commands — all prefixed with `ralph-` for clarity — and a configuration layer that lets users opt into Ralph features during Arnold installation.

The end state: you describe your product in Arnold's docs, run a command, and Ralph starts building it. Arnold checks the result. Drift gets resolved. New stories get generated if needed. Repeat until done.

---

## What Each System Brings

| Concern | Arnold | Ralph |
|---------|--------|-------|
| Source of truth | `docs/` folder (feature-organized markdown) | `prd.json` (flat story list) |
| Persistence | `.arnold-snapshot.json`, `status.md`, git | `progress.txt`, `AGENTS.md`, git |
| Quality gate | Drift detection (docs vs. code comparison) | Typecheck/lint + tests + browser verification |
| Execution model | Human-triggered slash commands inside AI agent | Bash loop spawning fresh AI instances |
| Output | Reports, doc updates, decision records | Committed code, progress logs |
| Control model | User approves every change | Autonomous within iteration; user reviews between batches |

They're complementary. Arnold is the spec layer. Ralph is the build layer. Neither one alone closes the loop.

---

## Configuration: Ralph as an Optional Module

Ralph integration is **opt-in**, not default. Users who just want Arnold's doc-first workflow shouldn't see Ralph commands cluttering their experience.

### How it works

Arnold gets a lightweight config file: `.arnold/config.json` (or a config block in the project's CLAUDE.md). This config tracks optional modules:

```json
{
  "modules": {
    "ralph": {
      "enabled": false,
      "tool": null,
      "installed": false
    }
  }
}
```

### Enabling Ralph

**During fresh install:**

The installer (`install.sh`) adds an optional flag:

```bash
# Install Arnold with Ralph integration
curl -fsSL https://raw.githubusercontent.com/ArtifactHQ/Arnold-Lite/main/install.sh | bash -s -- --with-ralph

# Install Arnold without Ralph (default)
curl -fsSL https://raw.githubusercontent.com/ArtifactHQ/Arnold-Lite/main/install.sh | bash
```

When `--with-ralph` is passed:
1. Arnold's standard commands are installed as usual
2. Ralph-specific commands (`ralph-stories.md`, `ralph-handoff.md`, `ralph-loop.md`, `ralph-learn.md`) are also installed
3. Config is set to `"ralph": { "enabled": true }`
4. If Ralph isn't detected in the environment (`ralph.sh` not found), installer prints a message: "Ralph integration enabled but Ralph is not installed. Install it: https://github.com/snarktank/ralph"

**On an existing Arnold project:**

A setup command enables it after the fact:

```
/arnold:ralph-setup
```

This command:
1. Checks if Ralph is installed (looks for `ralph.sh` or `scripts/ralph/ralph.sh`)
2. If not found, tells the user how to install it and provides the link
3. Asks which tool the user wants Ralph to use: `amp` or `claude` (stores in config)
4. Installs the Ralph-specific command files if not already present
5. Updates `.arnold/config.json` with Ralph settings
6. Updates `/arnold:help` output to include Ralph commands

**Plugin path:**

For Claude Code plugin installs, the Ralph commands exist in the plugin but are gated. When any `/arnold:ralph-*` command is run without Ralph enabled, it outputs: "Ralph integration isn't enabled. Run /arnold:ralph-setup to get started."

### What non-Ralph users see

If Ralph is disabled:
- `/arnold:help` shows the standard 11 commands — no Ralph commands listed
- Running any `/arnold:ralph-*` command gives the setup prompt above
- No Ralph-related files are created or modified
- Arnold works exactly as it does today

If Ralph is enabled:
- `/arnold:help` shows a "Ralph Integration" section with the 4 Ralph commands
- Ralph commands are fully functional
- Arnold's existing commands gain Ralph-awareness (see "Enhanced Existing Commands" section below)

---

## Command Naming: Everything Ralph Says "Ralph"

All Ralph-specific commands are namespaced under `arnold:ralph-*` so users know exactly what they're interacting with. No ambiguity about which system a command belongs to.

| Command | Purpose |
|---------|---------|
| `/arnold:ralph-setup` | Enable Ralph integration, configure tool preference, check installation |
| `/arnold:ralph-stories` | Convert Arnold docs into Ralph's `prd.json` format |
| `/arnold:ralph-handoff` | Package everything Ralph needs and tell you the run command |
| `/arnold:ralph-loop` | Show cycle status — where you are, what to do next |
| `/arnold:ralph-learn` | Import Ralph's `progress.txt` learnings back into Arnold docs |

These live alongside Arnold's existing commands:

```
commands/arnold/
├── init.md
├── plan.md
├── check.md
├── update.md
├── status.md
├── help.md
├── decide.md
├── resolve.md
├── recap.md
├── diff.md
├── spec.md
├── ralph-setup.md       # NEW
├── ralph-stories.md     # NEW
├── ralph-handoff.md     # NEW
├── ralph-loop.md        # NEW
└── ralph-learn.md       # NEW

skills/
├── ...existing skills...
├── ralph-setup/SKILL.md
├── ralph-stories/SKILL.md
├── ralph-handoff/SKILL.md
├── ralph-loop/SKILL.md
└── ralph-learn/SKILL.md
```

---

## Architecture: Five New Pieces

### Piece 1: `/arnold:ralph-setup` (configuration)

The entry point for Ralph integration. Run once per project.

**What it does:**

1. Checks if Ralph is installed in the environment
   - Looks for `ralph.sh` at project root, `scripts/ralph/ralph.sh`, or in PATH
   - If not found: "Ralph is not installed. Get it at https://github.com/snarktank/ralph — then run this command again."
   - Does NOT auto-install Ralph. That's the user's decision.
2. Asks which AI tool to use with Ralph: `amp` or `claude`
   - Stores the preference in `.arnold/config.json`
   - This affects the command output from `/arnold:ralph-handoff`
3. Detects project language/stack for quality gate configuration
   - TypeScript → "tsc --noEmit" + test runner
   - Python → "mypy" or "pyright" + "pytest"
   - Go → "go vet" + "go test"
   - Rust → "cargo check" + "cargo test"
   - JavaScript (no TS) → linter (eslint) + test runner
   - Other/unknown → asks user to specify their check and test commands
   - Stores in config as `qualityGates.typecheck` and `qualityGates.test`
4. Creates `.arnold/config.json` with all settings
5. Confirms setup with a summary

**Config file after setup:**

```json
{
  "modules": {
    "ralph": {
      "enabled": true,
      "tool": "claude",
      "ralphPath": "./ralph.sh",
      "qualityGates": {
        "typecheck": "tsc --noEmit",
        "test": "npm test",
        "lint": "eslint ."
      },
      "language": "typescript"
    }
  }
}
```

### Piece 2: `/arnold:ralph-stories` (the bridge)

The critical piece. Reads Arnold's `docs/` folder and generates a Ralph-compatible `prd.json`.

**What it reads:**
- `docs/overview.md` — project name and description
- `docs/status.md` — feature statuses (only generates stories for 🔵 Not Started and 🟡 In Progress features)
- `docs/[feature]/overview.md` — core rules, assumptions, key behaviors
- `docs/[feature]/[flow].md` — step-by-step user flows with acceptance criteria
- `docs/[feature]/edge-cases.md` — error handling scenarios
- `docs/unknowns.md` — skips features with unresolved ❓ questions that block implementation
- `docs/.arnold-snapshot.json` — if it exists, uses drift items as stories (fix drift = story)
- `.arnold/config.json` — reads language/stack and quality gate commands

**What it outputs:**

A `prd.json` file at the project root, formatted exactly as Ralph expects:

```json
{
  "project": "{{ from docs/overview.md project name }}",
  "branchName": "ralph/{{ kebab-case feature or batch name }}",
  "description": "{{ from docs/overview.md one-liner }}",
  "userStories": [
    {
      "id": "US-001",
      "title": "{{ derived from feature rule or flow step }}",
      "description": "As a {{ user type }}, I want {{ behavior from docs }} so that {{ purpose from docs }}",
      "acceptanceCriteria": [
        "{{ specific, testable criterion derived from doc rule }}",
        "{{ quality gate from config, e.g. 'tsc --noEmit passes' or 'mypy passes' or 'cargo check passes' }}",
        "{{ test gate if applicable, e.g. 'npm test passes' or 'pytest passes' }}"
      ],
      "priority": 1,
      "passes": false,
      "notes": "Source: docs/{{ feature }}/{{ file }}.md | Provenance: {{ user-stated|domain-derived|etc }}"
    }
  ]
}
```

**Key design decisions:**

1. **Language-agnostic quality gates.** The command reads quality gate commands from `.arnold/config.json` (set during `/arnold:ralph-setup`). No assumptions about TypeScript. A Python project gets "mypy passes" and "pytest passes." A Go project gets "go vet passes" and "go test passes." A vanilla JS project gets "eslint passes" and whatever test runner is configured.

2. **Story sizing.** Ralph needs stories that fit in one context window. Arnold's docs are rich and narrative. The command must decompose: one flow step = one story, one edge case = one story, one core rule = one story. If a flow doc has 5 happy-path steps, that's 5 stories. The rule of thumb: if you can't describe the change in 2-3 sentences, split it.
   - Count acceptance criteria per story — if > 5, consider splitting
   - Flag stories that touch more than 3 files as potentially too large
   - Default to over-splitting (more small stories > fewer big ones)
   - Include a `--granularity fine|normal|coarse` flag for user control

3. **Provenance → priority mapping.** Arnold tracks where rules come from. This maps to Ralph's priority:
   - `(user-stated)` rules → highest priority (these are what you explicitly asked for)
   - `(decided)` rules → high priority (deliberate choices)
   - `(domain-derived)` rules → medium priority
   - `(Arnold-inferred)` rules → lower priority (Claude reasoned these should exist — build them last)

4. **Acceptance criteria derivation.** Arnold's docs contain rules like "Sessions expire after 24 hours." The command translates these into testable acceptance criteria: "Session TTL is set to 86400 seconds (24 hours)." Every criterion must be verifiable — no vague language.

5. **Smart drift handling.** When `.arnold-snapshot.json` contains 🔴 drifted items, the command uses best judgment to decide how to handle each one rather than always blocking on user input:
   - **Obvious fixes** (docs say 24hr, code says 72hr — a clear numeric mismatch): Generate a fix story that aligns code to docs. The docs are the source of truth by default. The story notes say "Auto-resolved: docs are source of truth."
   - **Ambiguous drift** (docs say JWT, code uses opaque tokens — a different approach entirely): Flag these and ask the user which direction to go. Don't generate a story until the user decides.
   - **Cosmetic drift** (different naming conventions, comment styles): Skip. Not worth a story.
   - The heuristic: if the drift is a value change (numbers, strings, config), trust docs. If the drift is an architectural change (different library, different pattern), ask the user. If it's trivial, ignore it.

6. **Feature scoping.** Like other Arnold commands, `/arnold:ralph-stories` accepts an optional feature argument: `/arnold:ralph-stories auth` generates stories only for the auth feature.

7. **Skip unknowns.** Features with unresolved ❓ items in `unknowns.md` get skipped with a warning. You don't want Ralph building something where a fundamental question hasn't been answered yet.

8. **Story ID namespacing.** Stories get IDs like `US-001`, `US-002`, etc. If regenerating (e.g., via `--refresh` after an Arnold check cycle), existing completed stories (`passes: true`) are preserved. New stories get the next available ID.

9. **Notes field = traceability.** Every story's `notes` field links back to the specific Arnold doc and provenance tag that generated it. This makes it possible to trace any piece of Ralph-built code back to the doc that requested it.

10. **Infrastructure stories.** When the command detects no test infrastructure (no test config, no typecheck config for the detected language), it auto-generates priority-0 infrastructure stories: "Set up test framework," "Add typecheck/lint configuration." These run first so Ralph has quality gates from the start.

**Command file locations:**

```
commands/arnold/ralph-stories.md
skills/ralph-stories/SKILL.md
```

### Piece 3: `/arnold:ralph-handoff` (the packager)

Packages everything Ralph needs to start building. It's the "go build this" button.

**What it does:**

1. Checks Ralph is installed and enabled (reads config). If not → points to `/arnold:ralph-setup`.
2. Runs `/arnold:ralph-stories` to generate (or regenerate) `prd.json`
3. Reads tool preference from `.arnold/config.json` — uses whatever the user chose during setup (`amp` or `claude`). If not set, asks which tool they want to use and saves the choice.
4. Generates or updates a Ralph-compatible `AGENTS.md` at the project root by:
   - Reading Arnold's `docs/overview.md` for project context
   - Reading Arnold's `docs/decisions/` for architectural choices Ralph should respect
   - Reading Arnold's `docs/unknowns.md` for things Ralph should NOT touch
   - Reading `.arnold/config.json` for quality gate commands
   - Appending Arnold-specific conventions (doc structure, provenance tags, what not to modify)
5. Creates or updates `progress.txt` with an initial entry noting the Arnold doc state
6. Outputs the ready-to-run command using the configured tool: `./ralph.sh --tool claude 10` or `./ralph.sh --tool amp 10`
7. Warns about any blockers: unresolved unknowns, features with ❓ status, missing test infrastructure, ambiguous drift items that need user resolution

**Critical rule in AGENTS.md generation:**

```markdown
## Arnold Integration Rules
- The `docs/` folder is READ-ONLY. Do not modify any file in `docs/`.
- The `.arnold-snapshot.json` file is READ-ONLY. Do not modify it.
- The `.arnold/` directory is READ-ONLY. Do not modify it.
- Read `docs/[feature]/overview.md` before implementing any feature.
- Read `docs/decisions/` before making architectural choices.
- If you encounter a situation not covered by docs, implement it but note it in progress.txt.
- Commit messages should reference the story ID: "[US-001] Implement session timeout"
- Quality gates: {{ typecheck command from config }}, {{ test command from config }}
```

This is crucial — Ralph's agents need to treat Arnold's docs as the spec, not something to edit.

### Piece 4: `/arnold:ralph-loop` (cycle status)

A status command that tells you where you are in the Arnold ↔ Ralph cycle and what to do next. This isn't an automated orchestrator — it's your dashboard.

**The cycle it tracks:**

```
┌──────────────────────────────────────────────────┐
│  1. /arnold:ralph-stories                        │
│     Generate prd.json from docs                  │
│                                                  │
│  2. /arnold:ralph-handoff                        │
│     Package AGENTS.md + progress.txt + tool pref │
│                                                  │
│  3. ./ralph.sh --tool {{ configured tool }} N    │
│     Ralph builds N stories autonomously          │
│                                                  │
│  4. /arnold:check                                │
│     Compare docs to what Ralph built             │
│                                                  │
│  5. /arnold:resolve (if drift found)             │
│     Fix any drift (docs or code)                 │
│                                                  │
│  6. /arnold:ralph-learn                          │
│     Import Ralph's learnings back into docs      │
│                                                  │
│  7. /arnold:ralph-stories --refresh              │
│     Regenerate prd.json with new/fix stories     │
│                                                  │
│  8. If incomplete stories remain → go to 3       │
│     If all stories pass + check clean → done     │
└──────────────────────────────────────────────────┘
```

**What `/arnold:ralph-loop` reads:**
- `prd.json` — how many stories pass vs. remain
- `docs/.arnold-snapshot.json` — any drift from last check
- `progress.txt` — what Ralph has logged, how many iterations
- `docs/status.md` — feature statuses
- `.arnold/config.json` — tool preference, language

**Example output:**

```
🦕 ARNOLD × RALPH LOOP STATUS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Cycle: 2 (second Ralph batch)
Tool: claude | Language: python
📋 Stories: 14/18 complete (4 remaining)
🔍 Last check: clean (drift resolved in cycle 1)
📝 Ralph progress: 14 iterations, 2 failed quality gates (retried successfully)

Remaining stories:
  US-015: Stripe webhook handling (payments)
  US-016: Refund flow (payments)
  US-017: Waitlist implementation (booking)
  US-018: Waitlist notification (booking)

NEXT STEP: ./ralph.sh --tool claude 6
Then: /arnold:check → /arnold:ralph-learn → /arnold:ralph-loop

Hold on to your docs. 🦕
```

### Piece 5: `/arnold:ralph-learn` (feedback loop — progress.txt → docs)

This is the piece that closes the knowledge loop. After Ralph runs, `progress.txt` contains learnings — patterns discovered, gotchas encountered, codebase insights. This command reads those learnings and proposes updates to Arnold's docs.

**What it does:**

1. Reads `progress.txt` for new entries since last learn cycle
2. Reads `AGENTS.md` for patterns Ralph's agents discovered
3. Categorizes each learning:
   - **Pattern/convention** → proposes addition to relevant feature's `overview.md` or a new decision record
   - **Gotcha/edge case** → proposes addition to relevant feature's `edge-cases.md`
   - **Architectural insight** → proposes a decision record in `docs/decisions/`
   - **Story-specific detail** → skips (not worth documenting)
4. Presents proposed doc updates for user approval (same approve/reject flow as `/arnold:update`)
5. Marks which progress.txt entries have been processed (to avoid re-proposing)

**Why this matters:**

Without this command, knowledge flows one way: Arnold → Ralph. Ralph learns things while building (e.g., "the Stripe API requires idempotency keys for all POST requests") but those learnings stay trapped in `progress.txt` and `AGENTS.md`. `/arnold:ralph-learn` pulls them back into Arnold's docs, making them part of the permanent source of truth. Next time someone (or Ralph) works on this feature, the docs reflect what was actually learned during implementation.

**Example:**

```
🦕 RALPH LEARNINGS IMPORT
━━━━━━━━━━━━━━━━━━━━━━━━━

Found 6 new learnings in progress.txt (3 actionable):

1. PATTERN: "Stripe API requires idempotency keys on all POST requests"
   → Propose adding to docs/payments/overview.md
   [approve/skip]

2. EDGE CASE: "Rate limiter doesn't apply to admin users"
   → Propose adding to docs/auth/edge-cases.md
   [approve/skip]

3. DECISION: "Used bcrypt over argon2 — argon2 had memory issues in container"
   → Propose new decision record: docs/decisions/004-bcrypt-over-argon2.md
   [approve/skip]

Skipped 3 story-specific entries (not worth documenting).

Hold on to your docs. 🦕
```

---

## Enhanced Existing Commands (Ralph-Aware)

When Ralph is enabled in config, several existing Arnold commands gain additional behavior. Users don't need to know about this — it just works.

### `/arnold:check` (enhanced)

When Ralph is enabled and `prd.json` exists:
- After the standard drift report, adds a section showing Ralph story completion status
- Cross-references drift items with Ralph stories — "This drift was introduced by [US-007]"
- Suggests running `/arnold:ralph-learn` if new progress.txt entries exist

### `/arnold:update` (enhanced)

When Ralph is enabled:
- Also reads `progress.txt` and `AGENTS.md` for learnings (in addition to git diff)
- Suggests learnings that should become documented — same as `/arnold:ralph-learn` but integrated into the standard update flow

### `/arnold:help` (enhanced)

When Ralph is enabled:
- Adds a "Ralph Integration" section to the help output showing all `/arnold:ralph-*` commands
- Shows the cycle diagram
- Links to Ralph installation if not installed

When Ralph is NOT enabled:
- No mention of Ralph commands
- Clean, standard Arnold help

### `/arnold:recap` (enhanced)

When Ralph is enabled:
- Includes Ralph loop status in the session briefing
- Shows: stories complete, last Ralph run, unprocessed learnings
- Suggests next step in the loop

---

## File Format Bridge: Arnold Docs → Ralph prd.json

This is the core translation logic that `/arnold:ralph-stories` performs. Here's how each Arnold doc type maps to Ralph stories:

### Feature Overview → Foundation Stories

```
docs/auth/overview.md contains:
  "Sessions expire after 24 hours (user-stated)"
  "Rate limit: 5 login attempts per minute (domain-derived)"
  "Uses JWT tokens (decided — see decisions/003)"

Becomes:
  US-001: "Implement 24-hour session expiry"
    criteria: ["Session TTL constant = 86400", "Expired sessions rejected",
               "{{ config.qualityGates.typecheck }} passes"]
    priority: 1 (user-stated)

  US-002: "Add login rate limiting"
    criteria: ["Rate limit = 5 per minute per IP", "6th attempt returns 429",
               "{{ config.qualityGates.typecheck }} passes"]
    priority: 2 (domain-derived)

  US-003: "Implement JWT-based authentication"
    criteria: ["Auth uses JWT tokens", "Token includes user ID and expiry",
               "{{ config.qualityGates.typecheck }} passes",
               "{{ config.qualityGates.test }} passes"]
    priority: 1 (decided)
```

### Flow Docs → Sequential Stories

```
docs/booking/reserve-spot.md contains:
  Happy Path:
    1. User selects class from schedule
    2. System checks capacity (max 20)
    3. System creates reservation
    4. User receives confirmation email

Becomes:
  US-004: "Display class schedule with available spots"
    criteria: ["Schedule page shows classes", "Each class shows remaining capacity",
               "{{ config.qualityGates.typecheck }} passes"]
    priority: 3

  US-005: "Enforce capacity limit on reservations"
    criteria: ["Reservations rejected when capacity = 20", "Error message shown to user",
               "{{ config.qualityGates.typecheck }} passes",
               "{{ config.qualityGates.test }} passes"]
    priority: 4
    ...etc
```

### Edge Cases → Defensive Stories

```
docs/booking/edge-cases.md contains:
  "Double booking: User cannot book the same class twice"
  "Cancelled class: Bookings for cancelled classes auto-refund"

Becomes:
  US-008: "Prevent double booking for same class"
    criteria: ["Second booking attempt for same class returns error",
               "Error message: 'Already booked'",
               "{{ config.qualityGates.typecheck }} passes",
               "{{ config.qualityGates.test }} passes"]
    priority: 7
```

### Drift Items → Fix Stories (with smart judgment)

```
.arnold-snapshot.json contains:
  "auth.session-timeout": { status: "drifted", doc_value: "24 hours", code_value: "72 hours" }
  "auth.token-format": { status: "drifted", doc_value: "JWT", code_value: "opaque session tokens" }

The command applies judgment:

  Session timeout (value mismatch — obvious fix, trust docs):
    US-010: "Fix drift: session timeout should be 24 hours"
      criteria: ["SESSION_TTL = 86400", "No other references to 72-hour timeout",
                 "{{ config.qualityGates.typecheck }} passes",
                 "{{ config.qualityGates.test }} passes"]
      priority: 1
      notes: "AUTO-RESOLVED: value drift, docs are source of truth"

  Token format (architectural mismatch — needs user input):
    ⚠️ SKIPPED: "auth.token-format" — docs say JWT, code uses opaque tokens.
    This is an architectural difference. Run /arnold:resolve to decide direction
    before generating a story.
```

**The heuristic for auto-resolution:**
- Numbers, config values, string constants → trust docs, generate fix story
- Library choices, architectural patterns, data model changes → ask the user
- Naming, formatting, comments → ignore (cosmetic)

---

## What Ralph's Agents See

When Ralph spawns a fresh agent for iteration N, that agent reads:

1. **prd.json** — finds the next `passes: false` story, sees the acceptance criteria (with language-appropriate quality gates) and notes linking to Arnold docs
2. **AGENTS.md** — sees the "Arnold Integration Rules" section telling it docs/ is read-only, plus project conventions from Arnold's decisions, plus quality gate commands
3. **progress.txt** — sees what previous iterations learned
4. **docs/[feature]/overview.md** — reads the full context for the feature it's implementing (the notes field tells it which doc to read)
5. **Git history** — sees previous Ralph commits

The agent implements the story, runs quality gates (language-specific commands from config), commits with `[US-XXX] Story title`, logs learnings to `progress.txt`, updates `AGENTS.md` if it discovered patterns, and marks the story `passes: true`.

It never touches `docs/`. That's Arnold's domain.

---

## Handling the Hard Parts

### Story sizing: what if a feature is too big?

Arnold's `/arnold:ralph-stories` command must enforce Ralph's constraint: each story fits in one context window. The rule of thumb is "if you can't describe the change in 2-3 sentences, split it."

The command should:
- Count acceptance criteria per story — if > 5, consider splitting
- Flag stories that touch more than 3 files as potentially too large
- Default to over-splitting (more small stories > fewer big ones)
- Include a `--granularity fine|normal|coarse` flag for user control

### What if Ralph builds something Arnold didn't ask for?

This is exactly what `/arnold:check` catches. After a Ralph batch, Arnold scans for:
- **Undocumented code** — new files/functions Ralph created that aren't in any doc
- **Over-implementation** — Ralph added features beyond what docs specified

`/arnold:update` can then document the new code (legitimizing it), or the user can revert it.

### What if docs change mid-build?

If you run `/arnold:resolve` or `/arnold:update` between Ralph batches, docs may change. The `--refresh` flag on `/arnold:ralph-stories` handles this:
- Preserves completed stories (`passes: true`)
- Updates acceptance criteria for incomplete stories if docs changed
- Adds new stories for new doc content
- Removes stories for deleted doc content (with warning)

### What about Ralph's AGENTS.md vs. Arnold's docs/?

Clear ownership boundary:
- `docs/` = Arnold's domain (the spec, read-only for Ralph)
- `AGENTS.md` = Ralph's domain (implementation patterns, read-write for Ralph)
- `progress.txt` = Ralph's domain (iteration logs, append-only for Ralph)
- `.arnold/` = Arnold's domain (config, read-only for Ralph)

`/arnold:ralph-handoff` seeds AGENTS.md with Arnold context, but after that, Ralph's agents own it and append their own learnings. `/arnold:ralph-learn` pulls learnings back from Ralph's files into Arnold's docs — that's the only direction knowledge flows back.

### What about quality gates for non-TypeScript projects?

Solved by `/arnold:ralph-setup` detecting the project language and storing quality gate commands in `.arnold/config.json`. The commands throughout the system read from config rather than hardcoding TypeScript assumptions.

Supported language detection:

| Language | Typecheck/Lint | Test |
|----------|---------------|------|
| TypeScript | `tsc --noEmit` | `npm test` or `jest` or `vitest` |
| JavaScript | `eslint .` | `npm test` or `jest` or `vitest` |
| Python | `mypy .` or `pyright` | `pytest` |
| Go | `go vet ./...` | `go test ./...` |
| Rust | `cargo check` | `cargo test` |
| Ruby | `rubocop` | `rspec` or `rails test` |
| Java | `mvn compile` | `mvn test` or `gradle test` |
| Custom | User specifies | User specifies |

Detection method: look for config files (`tsconfig.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`, `Gemfile`, `pom.xml`, `build.gradle`). If ambiguous or nothing found, ask the user.

### What if there are no tests yet?

For greenfield projects where Arnold just created docs and there's no code yet:
- `/arnold:ralph-stories` auto-generates priority-0 infrastructure stories: "Set up test framework," "Add typecheck/lint configuration"
- These run first so Ralph has quality gates from the start
- The specific infrastructure depends on the detected language (e.g., "Install pytest and create conftest.py" for Python, "Initialize Jest and create first test file" for JavaScript)

### What if Ralph is run but not installed?

Every `/arnold:ralph-*` command checks for Ralph's presence before doing anything. If Ralph isn't installed:
- Clear message: "Ralph is not installed. Install it from https://github.com/snarktank/ralph"
- Provides the install command for the user's platform
- Does not attempt to auto-install

---

## Implementation Order

### Phase 1: Configuration layer

1. Define `.arnold/config.json` schema
2. Write `commands/arnold/ralph-setup.md` — the setup/config command
3. Write `skills/ralph-setup/SKILL.md` — plugin version
4. Update `install.sh` to support `--with-ralph` flag
5. Update `install.sh` to copy Ralph command files when flag is present

### Phase 2: `/arnold:ralph-stories` (the bridge)

This is the critical piece. Without it, nothing else works.

1. Write `commands/arnold/ralph-stories.md` — the prompt that reads docs and outputs prd.json
2. Write `skills/ralph-stories/SKILL.md` — plugin version
3. Test: run `/arnold:init` on the fitness-studio example, then `/arnold:ralph-stories`, verify the prd.json is valid for multiple language configurations

### Phase 3: `/arnold:ralph-handoff` (the packager)

1. Write `commands/arnold/ralph-handoff.md`
2. Write `skills/ralph-handoff/SKILL.md`
3. Test: run `/arnold:ralph-handoff` and verify AGENTS.md + progress.txt are correct, tool preference is respected

### Phase 4: `/arnold:ralph-learn` (the feedback loop)

1. Write `commands/arnold/ralph-learn.md`
2. Write `skills/ralph-learn/SKILL.md`
3. Test: create mock progress.txt with learnings, run `/arnold:ralph-learn`, verify proposed doc updates are sensible

### Phase 5: `/arnold:ralph-loop` (the status tracker)

1. Write `commands/arnold/ralph-loop.md`
2. Write `skills/ralph-loop/SKILL.md`
3. Test: manually walk through the full cycle on the fitness-studio example

### Phase 6: Enhanced existing commands

1. Update `commands/arnold/check.md` — add Ralph-aware section (gated by config)
2. Update `commands/arnold/update.md` — add progress.txt reading (gated by config)
3. Update `commands/arnold/help.md` — add Ralph section (gated by config)
4. Update `commands/arnold/recap.md` — add Ralph status (gated by config)
5. Update `skills/` equivalents for all of the above

### Phase 7: Documentation and examples

1. Add `docs/ralph-integration/` to the fitness-studio example showing the full cycle
2. Write a `RALPH-INTEGRATION.md` guide in Arnold's docs/
3. Update the command table in README
4. Update CHANGELOG.md
5. Update CLAUDE.md template with Ralph integration notes

---

## What the User Experience Looks Like

### First time: enabling Ralph on an existing Arnold project

```
> /arnold:ralph-setup

🦕 Setting up Ralph integration...

Checking for Ralph... ✓ Found at ./ralph.sh
Detecting project language... Python (found pyproject.toml)

Quality gates detected:
  Typecheck: mypy .
  Tests: pytest
  Lint: ruff check .

Which tool should Ralph use?
  (a) amp
  (b) claude

> b

✓ Ralph integration enabled.
  Tool: claude
  Language: python
  Config saved to .arnold/config.json

Run /arnold:ralph-stories to generate your first prd.json.

Hold on to your docs. 🦕
```

### Generating stories

```
> /arnold:ralph-stories

🦕 Generating Ralph stories from your docs...

Read 4 features: auth, booking, payments, notifications
Skipped: notifications (has unresolved unknown: "Which email provider?")

Generated 18 stories across 3 features:
  auth:      5 stories (2 user-stated, 1 decided, 2 domain-derived)
  booking:   9 stories (4 from flows, 3 from edge cases, 2 from rules)
  payments:  4 stories (1 user-stated, 2 decided, 1 domain-derived)

Quality gates per story: mypy . + pytest (from config)

⚠️  1 drift item skipped (architectural — needs /arnold:resolve first):
    auth.token-format: docs say JWT, code uses opaque tokens

✓ 1 drift item auto-resolved (value mismatch):
    auth.session-timeout: generated fix story US-001

Written to: ./prd.json
Branch: ralph/initial-build

Next: /arnold:ralph-handoff

Hold on to your docs. 🦕
```

### After a Ralph batch — importing learnings

```
> /arnold:ralph-learn

🦕 RALPH LEARNINGS IMPORT
━━━━━━━━━━━━━━━━━━━━━━━━━

Found 6 new learnings in progress.txt (3 actionable):

1. PATTERN: "Stripe API requires idempotency keys on all POST requests"
   → Propose adding to docs/payments/overview.md
   [approve/skip]

2. EDGE CASE: "Rate limiter doesn't apply to admin users"
   → Propose adding to docs/auth/edge-cases.md
   [approve/skip]

3. DECISION: "Used bcrypt over argon2 — argon2 had memory issues in container"
   → Propose new decision record: docs/decisions/004-bcrypt-over-argon2.md
   [approve/skip]

Skipped 3 story-specific entries (not worth documenting).

Hold on to your docs. 🦕
```

### Checking loop status

```
> /arnold:ralph-loop

🦕 ARNOLD × RALPH LOOP STATUS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Cycle: 2 (second Ralph batch)
Tool: claude | Language: python | Quality: mypy + pytest
📋 Stories: 14/18 complete (4 remaining)
🔍 Last check: clean (drift resolved in cycle 1)
📝 Ralph progress: 14 iterations, 2 failed quality gates (retried)
📚 Unprocessed learnings: 3 (run /arnold:ralph-learn)

Remaining stories:
  US-015: Stripe webhook handling (payments)
  US-016: Refund flow (payments)
  US-017: Waitlist implementation (booking)
  US-018: Waitlist notification (booking)

NEXT STEP:
  1. /arnold:ralph-learn  (import 3 unprocessed learnings)
  2. ./ralph.sh --tool claude 6
  3. /arnold:check

Hold on to your docs. 🦕
```

### When Ralph isn't installed

```
> /arnold:ralph-stories

🦕 Ralph integration isn't set up yet.

Ralph is an autonomous build loop that implements stories from your docs.
Get it at: https://github.com/snarktank/ralph

Once installed, run /arnold:ralph-setup to configure the integration.

Hold on to your docs. 🦕
```

---

## Resolved Design Decisions

These were open questions in v1 that are now decided:

| # | Question | Decision |
|---|----------|----------|
| 1 | Non-TypeScript support? | **Yes.** `/arnold:ralph-setup` detects language and configures quality gates. All story generation uses config, not hardcoded TS assumptions. |
| 2 | Drift fixes require resolve first? | **Sometimes.** Smart judgment: value drift auto-resolves (trust docs). Architectural drift requires `/arnold:resolve`. Cosmetic drift is ignored. |
| 3 | Auto-install Ralph? | **No.** Tell the user to install it. Provide the link. Don't be magical. |
| 4 | Branch naming? | **Auto-generated.** `ralph/[feature-name]` for single-feature runs, `ralph/batch-YYYY-MM-DD` for multi-feature runs. |
| 5 | progress.txt → Arnold? | **Yes.** New `/arnold:ralph-learn` command imports Ralph's learnings into Arnold docs. Closes the knowledge loop. |
| 6 | Tool selection (amp/claude)? | **Asked during setup.** Stored in config. Used by handoff. Can be changed with `/arnold:ralph-setup` again. |

---

## Remaining Open Questions

1. **Should Ralph commands be installable as a separate plugin?** Currently they're bundled with Arnold. Could split into an `arnold-ralph` plugin that depends on both Arnold and Ralph. This adds complexity but makes the opt-in cleaner.

2. **Should `/arnold:ralph-loop` eventually support full automation?** Today it's a status dashboard. In the future, could it actually orchestrate the cycle? (Run Ralph → check → resolve obvious drift → learn → regenerate stories → run Ralph again.) This requires Arnold commands to be callable from bash, which they currently aren't.

3. **What happens when multiple people use Arnold + Ralph on the same repo?** The `prd.json` and `progress.txt` would conflict. Should these be branch-scoped? Ralph already uses branch names, but the handoff between Arnold and Ralph assumes a single operator.

4. **How does this interact with the Claude Code plugin marketplace?** If Arnold is installed as a plugin and Ralph is installed separately, do the Ralph commands detect Ralph's plugin installation or just the bash script?

---

## Summary

Five new commands, all clearly namespaced with `ralph`:

| Command | What it does | When to run it |
|---------|-------------|----------------|
| `/arnold:ralph-setup` | Enable Ralph, detect language, configure quality gates and tool | Once per project |
| `/arnold:ralph-stories` | Convert Arnold docs → Ralph prd.json (language-aware) | Before starting a Ralph batch |
| `/arnold:ralph-handoff` | Package AGENTS.md + progress.txt + run command | First time, or after major doc changes |
| `/arnold:ralph-learn` | Import Ralph's progress.txt learnings back into Arnold docs | After each Ralph batch |
| `/arnold:ralph-loop` | Show cycle status + next step | Between Ralph batches |

Four existing commands gain Ralph-awareness (gated by config): `check`, `update`, `help`, `recap`.

The knowledge flows both ways: Arnold → Ralph (via docs and prd.json) and Ralph → Arnold (via `/arnold:ralph-learn`).

Arnold writes the spec. Ralph builds it. Arnold checks it. Ralph's learnings flow back into docs. Repeat until done.

Hold on to your docs. 🦕
