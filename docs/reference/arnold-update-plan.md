> **Reference document.** This update plan was fully implemented on 2026-04-01.
> All 13 workstreams completed. Arnold is now at v0.4.0 with 17 commands.
> See command files for current behavior. Kept for historical reference.

# Arnold Update Plan v3

**Date:** 2026-04-01
**Authors:** Chris Sotraidis + Claude
**Scope:** All planned changes to Arnold Lite based on CoinBank testing, team discussion, codebase review, and redundancy audit
**Current version:** 0.3.0

---

## How This Document Is Organized

Each workstream gets three sections: **What Exists** (what the codebase actually does today, citing specific files and line-level behavior), **What's Wrong or Missing** (the gap), and **What To Change** (the specific edits). No hand-waving. If I reference a behavior, I'll cite the file.

Eight workstreams (seven feature changes + one redundancy cleanup), then a priority matrix at the end.

---

## 1. `/arnold:spec` Should Auto-Archive the Source Document

### What Exists

`commands/arnold/spec.md` (356 lines). Step 3 says:

> **Critical: Preserve the original spec.** Do NOT delete, move, or modify the original spec document. It stays in `docs/` as the canonical reference.

Step 5 (the summary) reinforces this: "The original spec stays in docs/ as the source of truth."

`commands/arnold/archive.md` exists as a separate command with two modes: archive (stale) and reference (informational, not source of truth). It already has the exact headers, move logic, and cross-reference updates we'd need.

`skills/spec/SKILL.md` exists in the skills folder (contrary to what I said in v1 -- the directory listing shows `spec` is present in skills/).

### What's Wrong

The spec command was written defensively: "preserve the original." That made sense early on, but in practice (CoinBank test), it creates confusion. After decomposition, you have the original PRD sitting in `docs/` alongside all the feature folders Arnold just generated from it. Users don't know they should run `/arnold:archive --reference` on it. The original PRD isn't stale (so `archive/` is wrong), but it's also not the source of truth anymore (the feature docs are). It belongs in `docs/reference/`.

The fact that `archive.md` already has a `--reference` mode with the exact header format we need means we don't have to invent anything. We just need spec to call the archive logic at the end.

### What To Change

**In `commands/arnold/spec.md`:**

1. Change the "Critical: Preserve" note in Step 3. Replace the instruction to keep the file in `docs/` with: move it to `docs/reference/` after creation is complete.

2. Add a **Step 5.5: Archive Source** between the current Step 5 (summary) and the final output. The step should:
   - Create `docs/reference/` if it doesn't exist
   - Move the original spec to `docs/reference/[filename]`
   - Prepend the reference header (same format as `archive.md` uses):
     ```
     > **Reference document.** Decomposed into feature docs by Arnold on [date].
     > Feature folders in `docs/` are now the source of truth.
     ```
   - Update the `docs/overview.md` "Spec Reference" line to point to `docs/reference/[filename]`
   - Tell the user: "Moved [filename] to `docs/reference/`. Say 'undo' if you want it back."

3. Update the Step 5 summary output. Remove "The original spec stays in docs/ as the source of truth." Replace with: "Original spec archived to `docs/reference/[filename]`."

4. The soft-confirm approach is right here. Don't block on a confirmation dialog. Just move it and give a one-line undo option. This matches Arnold's personality: opinionated but flexible.

**In `skills/spec/SKILL.md`:** Mirror the same changes.

**In `commands/arnold/archive.md`:** No changes needed. The reference mode already does exactly what we need. Spec just needs to invoke the same pattern.

### What I Got Wrong in v1

- I said `skills/spec/SKILL.md` was missing. It's not. The directory listing shows `spec` in the skills folder. I was wrong.
- I over-complicated the confirm flow. Arnold's convention elsewhere (check, update) is to act and report, not to block. Spec should do the same.

---

## 2. Split Tech Stack from Product Requirements

### What Exists

This is the most architecturally significant change because it touches the output format of multiple commands.

**Current behavior in `spec.md`:**
Step 1 extracts "Tech stack (if mentioned)" as part of project identity. Step 2 presents it in the summary as `Stack: [tech stack if mentioned, or "not specified"]`. But then tech decisions get embedded directly into feature overview docs under "Core Rules" with provenance tags like `(spec-stated)`. There's no separate file for technical decisions.

**Current behavior in `init.md`:**
Path B (brownfield) scans the codebase and extracts tech stack in Step B2: "TECH STACK: [Language/framework], [database], [key libraries]". This also goes into feature overviews under Core Rules with `(code-derived)` provenance.

**Current behavior in `plan.md`:**
Proposes flow docs, edge cases, acceptance criteria. Doesn't distinguish between product requirements and technical implementation.

**Current behavior in `check.md`:**
Compares documented rules against code. Doesn't distinguish between "the product must do X" and "we chose Postgres to store X." Both are just rules.

**`docs/decisions/` exists** as a place for recording choices. Tech stack choices could go there, but individual decision records are about "why we chose X" -- not a consolidated manifest of the full stack.

### What's Wrong

Three problems from the CoinBank test and discussion:

1. **Tech decisions pollute requirements.** When "use Supabase for auth" sits next to "users must verify email before booking," the requirements doc becomes opinionated about implementation. If you want to swap Supabase for Postgres + custom auth, you have to edit every feature doc that mentions Supabase.

2. **No place for the coding agent to learn the full stack.** Decision records are scattered across `docs/decisions/001-*.md`, `002-*.md`, etc. There's no single file that says "here's the full technical picture." A coding agent starting a build session has to read N decision files and infer the stack.

3. **Users who don't care about stack still need one chosen.** If you just want to build, Claude should pick a reasonable stack. If you're opinionated, you should be able to specify. Currently there's no mechanism for either.

### What To Change

**New file: `docs/spec.md`** (the technical specification)

This is a new artifact in Arnold's document structure. It sits at the top level of `docs/`, alongside `overview.md` and `status.md`. It consolidates all implementation decisions into one manifest.

```markdown
# Technical Specification

<!-- Generated by Arnold. Edit directly or run /arnold:decide to update. -->
<!-- Mode: recommended | opinionated -->

## Stack

| Layer | Choice | Rationale | Source |
|-------|--------|-----------|--------|
| Language | Python 3.12 | Broad ecosystem, team familiarity | (Claude-recommended) |
| Framework | FastAPI | Async, auto-docs, lightweight | (Claude-recommended) |
| Database | PostgreSQL | Relational, proven, free | (user-stated) |
| ORM | SQLAlchemy | Standard for Python + Postgres | (Claude-recommended) |
| Frontend | React + Vite | Fast dev loop, large ecosystem | (Claude-recommended) |
| Auth | Custom JWT | No paid auth service required | (decided) - see decisions/003 |
| Hosting | Docker | Isolation, reproducibility | (user-stated) |
| CI/CD | GitHub Actions | Already using GitHub | (Claude-recommended) |

## Architecture

[2-3 paragraphs on how components fit together. Service boundaries if any.
Data flow. Deployment model.]

## Constraints

- Must run in Docker (user-stated)
- No paid third-party services unless explicitly approved (user-stated)
- Target SQLite for dev, Postgres for prod (decided)

## Open Technical Questions

- [Any unresolved technical choices, linked to docs/unknowns.md entries]
```

**Commands that need changes:**

**`/arnold:spec`** (largest change):
- Step 1: When extracting from the spec, separate product requirements from tech decisions. Product requirements go into feature overviews. Tech decisions go into `docs/spec.md`.
- Step 2: Present the extraction summary with a separate "TECH STACK" section showing what will go into spec.md vs. what goes into feature docs.
- Add a new step between Step 3 and Step 4: "STEP 3.5: GENERATE TECHNICAL SPEC"
  - If the source spec mentions technologies, extract them into `docs/spec.md`
  - If no tech is mentioned, ask: "Your spec doesn't specify technologies. Want me to recommend a stack based on your requirements, or leave it for later?"
  - If recommending: Claude picks a stack, explains why, writes spec.md with mode: `recommended`
  - If user has preferences: gather them conversationally, write spec.md with mode: `opinionated`
  - If "leave it for later": skip spec.md creation

**`/arnold:init`** (brownfield path):
- Step B2 already extracts tech stack from codebase. Instead of putting it into feature overviews, generate `docs/spec.md` with `(code-derived)` provenance.
- Feature overviews should reference spec.md for tech context: "See `docs/spec.md` for technical decisions."

**`/arnold:plan`**:
- When proposing new docs, don't add tech details to feature docs. If it detects tech decisions mixed into feature docs, flag it: "Found tech decisions in feature docs that should be in `docs/spec.md`. Want me to move them?"

**`/arnold:check`**:
- Add a new check category: verify that code uses the stack specified in `docs/spec.md`. If spec.md says Postgres but code uses SQLite, that's drift.
- When checking feature docs against code, don't flag tech-stack-level mismatches in feature docs (those belong in spec.md checks).

**`/arnold:decide`**:
- If the decision is about technology (detected by keywords: database, framework, language, hosting, etc.), offer to update `docs/spec.md` in addition to creating a decision record.

**`/arnold:help`**:
- Add spec.md to the doc structure diagram.
- Add a note: "Tech decisions live in `docs/spec.md`. Product requirements live in feature folders."

**`arnold-rules/SKILL.md` and root `CLAUDE.md` template:**
- Add `spec.md` to the document structure.
- Add a convention: "Product requirements are tech-agnostic. Technical decisions live in `docs/spec.md`."

### Naming: spec.md, Not agents.md

The notes reference the `agents.md` pattern. But `agents.md` is about agent behavior and tool configuration. Arnold's file is about stack decisions and architecture. `spec.md` is the right name because:
- It's a technical *specification*, not an agent manifest
- It's descriptive to non-AI-native users
- It sits naturally alongside `overview.md` (the what) and `status.md` (the where)
- The trio becomes: overview.md (vision), spec.md (implementation plan), status.md (current state)

### Release Toggle

For public release, the behavior should be:
- **Default:** Feature docs are tech-agnostic. spec.md is generated.
- **No toggle needed.** If a user doesn't want spec.md, they just don't use it. Arnold won't break without it. Commands that reference spec.md should gracefully skip if it doesn't exist: "No `docs/spec.md` found. Tech decisions will be included in feature docs."

This is simpler than a config toggle and more Arnold-like: opinionated defaults, easy to override.

---

## 3. `/arnold:feature` -- New Command

### What Exists

There is no feature-level management command. The closest things are:

- **`/arnold:status`**: Shows per-feature status markers (one line each) but no completeness detail. It reads `status.md` and feature overviews but only reports the status emoji and a brief note.
- **`/arnold:milestone`**: Groups features into phases with rollup status. Shows progress tables. But it's phase-level, not feature-level.
- **`/arnold:plan`**: Can be scoped to a single feature (`/arnold:plan booking`). Identifies gaps and proposes docs. But it's a planning tool, not a status/management tool.

The CoinBank test generated a table that showed per-feature completeness (overview, flows, edge cases, acceptance criteria counts). That table was generated ad-hoc by `/arnold:status` -- it's not a repeatable, first-class output.

### What's Missing

No way to:
1. See a completeness matrix for all features at a glance
2. Drill into one feature's full status (related decisions, unknowns, bugs, drift)
3. Deep-plan a single feature with completion enforcement

### What To Change

**New command: `/arnold:feature`** with natural language subcommands.

The meta-prompt should detect intent from the user's input:

- `/arnold:feature` or `/arnold:feature list` --> completeness matrix
- `/arnold:feature [name]` or `/arnold:feature status [name]` --> single feature detail
- `/arnold:feature plan [name]` --> deep plan with completion enforcement

**`list` behavior:**

Scan all `docs/[feature-name]/` folders. For each feature, count:
- Overview exists? (y/n)
- Flow doc count (count files matching `[feature]-*.md` excluding overview and edge-cases)
- Edge cases doc exists? (y/n)
- Acceptance criteria count (grep for `- [ ]` across all docs in the feature folder)
- Status marker (from the overview's Status section)

Output a table:

```
FEATURE COMPLETENESS
| Feature | Overview | Flows | Edge Cases | Criteria | Status |
|---------|----------|-------|------------|----------|--------|
| auth    | yes      | 2     | yes        | 8/12     | 🟡     |
| booking | yes      | 1     | no         | 0/5      | 🔵     |
| payments| yes      | 0     | no         | 0/0      | 🔵     |

Doc Depth: Moderate (3/3 overviews, 3/5 flows, 1/3 edge cases)
Build Readiness: 1/3 features ready to build (has flows + criteria)
```

This is the table the team loved during CoinBank. Making it a first-class command means you can pull it up anytime.

**`status [name]` behavior:**

Deep status for one feature. Read the feature folder plus cross-reference:
- `docs/decisions/*.md` -- any that mention this feature
- `docs/unknowns.md` -- any questions about this feature
- `docs/issues/*.md` -- any bugs for this feature
- `.arnold-snapshot.json` -- any drift items for this feature

Output:

```
FEATURE: auth
Status: 🟡 In Progress

DOCUMENTATION:
  auth-overview.md ........... 5 rules, 2 assumptions
  auth-login-flow.md ......... 6 steps, 3 error cases, 4 acceptance criteria
  auth-registration-flow.md .. (missing)
  auth-edge-cases.md ......... (missing)

RELATED:
  Decisions: 001-chose-jwt.md
  Unknowns: "Should we support SSO?" (due: before beta)
  Bugs: none
  Drift: session timeout drifted (72hr code vs 24hr docs)

COMPLETENESS: 60% (missing registration flow, edge cases)
```

**`plan [name]` behavior:**

This is `/arnold:plan` scoped to one feature, but with a completion loop. The key difference from just running `/arnold:plan auth` is:

1. After generating the first round of docs, re-scan the feature folder
2. Check: does every flow doc have acceptance criteria? Does the edge cases doc exist? Are there gaps?
3. If gaps remain, fill them without asking. (This is where the "Claude laziness" fix lives.)
4. Report only when the completeness check passes

The meta-prompt needs the completion gate pattern (see Workstream 5).

**Implementation files:**
- `commands/arnold/feature.md` (new)
- `skills/feature/SKILL.md` (new)

**Changes to existing commands:**
- `/arnold:help`: Add feature command to the reference
- `arnold-rules/SKILL.md`: Add feature command to the command list
- Root `CLAUDE.md` template: Add feature command

---

## 4. `/arnold:build` -- New Command

### What Exists

Arnold has no build command. The documented workflow is: init/spec --> plan --> (build code manually) --> check --> update. The "build code manually" step is a gap Arnold punts on.

The build spec (`docs/ARNOLD-LITE-BUILD-SPEC.md`) explicitly says Arnold is "Not an agentic loop." That was a design constraint for v0.3. But the team wants to cross that line now.

### What's Missing

There's no way to say "Arnold, build what's in the docs" and have it iterate until the code matches the requirements. Users have to manually start Claude Code, point it at the docs, build, then run `/arnold:check` to see if it worked. The check-build-check loop is manual.

### What To Change

**New command: `/arnold:build`**

This is the most ambitious addition and the most token-intensive. It needs careful scoping.

**Pre-flight (always runs):**

1. Check: does `docs/overview.md` exist? If not, stop.
2. Read all feature overviews to get the full feature list
3. Read `docs/spec.md` if it exists (for tech stack decisions)
4. Read `docs/milestones.md` if it exists (for build order)
5. Assess: are the docs complete enough to build?
   - If any feature has no acceptance criteria at all, warn: "Feature [X] has no acceptance criteria. I'll build it but can't verify correctness. Run `/arnold:feature plan [X]` first for better results."
6. Present build plan:

```
BUILD PLAN

Stack: [from spec.md, or "no spec.md -- I'll make reasonable choices"]
Order: [from milestones, or by dependency analysis]

Features to build:
  1. auth (6 acceptance criteria, 2 flows)
  2. booking (4 acceptance criteria, 1 flow)
  3. payments (0 acceptance criteria -- thin docs, will best-effort)

Estimated scope: [small/medium/large based on feature count and criteria count]

Proceed? (Or scope to a single feature: /arnold:build auth)
```

**Build loop (per feature):**

1. Read the feature's full doc set (overview, flows, edge cases)
2. Enumerate acceptance criteria as a checklist
3. Write code for the feature
4. Self-check: for each acceptance criterion, verify the code satisfies it
   - Read the code back
   - Compare against the criterion
   - If not met, identify what's missing, fix it
5. When all criteria pass for this feature, update `docs/status.md` to 🟢
6. Move to next feature

**The anti-laziness mechanism:**

This is the critical design decision. Claude will try to declare victory early. The meta-prompt must:

```
COMPLETION GATE (per feature):
Before marking any feature as built, you MUST:
1. List every acceptance criterion from the feature's docs
2. For each criterion, cite the specific code (file:line) that satisfies it
3. If you cannot cite code for a criterion, you are not done

Do not say "I believe this is complete" or "this should satisfy."
Show the mapping: criterion --> code. If there's no mapping, keep building.
```

This is different from a vague "make sure it's done" instruction. It forces Claude to produce a verifiable artifact (the criterion-to-code mapping) before it can proceed.

**Post-build:**

1. Run `/arnold:check` logic on the features that were built
2. Present a build report:

```
BUILD COMPLETE

Features built: 2/3
  auth: 6/6 criteria met
  booking: 4/4 criteria met
  payments: skipped (no acceptance criteria in docs)

Files created: [list]
Drift: none detected (code matches docs)

Next: review the code, then /arnold:check for a full verification.
```

**Scoping options (ship in phases):**

- **v1:** Single-feature build only. `/arnold:build auth` builds one feature.
- **v2:** Multi-feature with milestone ordering.
- **v3:** Watch mode (rebuild on doc changes). This is future and probably belongs in Arnold Engine, not Lite.

**Token budget reality check:**

From the discussion notes, token limits are 16,000-20,000. A build loop for a non-trivial feature will easily exceed this. The meta-prompt should:
- Focus on one feature at a time
- Not re-read all docs every iteration
- Cache the acceptance criteria at the start and reference them throughout
- If the build is too large, suggest breaking it into sub-features

**Implementation files:**
- `commands/arnold/build.md` (new)
- `skills/build/SKILL.md` (new)

---

## 5. Documentation Completeness Enforcement

### What Exists

This is where the deep read changed my thinking the most.

**`/arnold:spec` (Step 4):** Already creates flow docs "if the spec describes flows." The instruction is: "Only create flow docs if the spec describes them in enough detail. Don't invent flows the spec doesn't describe -- that's /arnold:plan's job." This is the root cause of incomplete docs. Spec intentionally defers completeness to plan.

**`/arnold:plan` (Step 3):** Has real gap detection. It checks: "Has overview but no flow docs? Has flows but no edge cases? Has rules but no acceptance criteria?" This is the right logic. But the execution (Steps 5-7) waits for user approval, creates approved docs, and reports. There's no verification step. It doesn't re-scan after creating to check if the created docs are actually complete.

**`/arnold:check` (Step 1):** Has a quality gate: "If most Core Rules are vague summaries without testable values, note this." But this is about rule specificity, not doc completeness.

**Feature overview template (in spec.md and init.md):** Has Core Rules, What's Assumed, Status. Does NOT have acceptance criteria as a required section. Acceptance criteria only appear in flow docs.

### What's Wrong

The laziness problem isn't purely Claude being lazy. The meta-prompts actually instruct Arnold to defer completeness:

1. **Spec defers to plan.** "Don't invent flows the spec doesn't describe -- that's plan's job." So spec creates thin overviews by design.
2. **Plan has no completion loop.** It creates docs and reports, but never re-checks whether those docs are themselves complete.
3. **No command enforces "every flow must have acceptance criteria."** The flow template includes an Acceptance Criteria section, but nothing checks that the section was actually populated.
4. **The feature overview template doesn't include acceptance criteria.** Criteria only exist in flow docs. If a feature has no flows (just an overview), it has zero acceptance criteria.

This is a structural issue, not just a prompting issue. Adding "try harder" language won't fix it if the workflow inherently defers completeness.

### What To Change

**Three changes, layered:**

**Change 5A: Add acceptance criteria to feature overviews.**

Currently, acceptance criteria only appear in flow docs. But many features get created with just an overview (spec creates overviews; plan creates flows later; if plan gets lazy, no flows means no criteria).

Add an "Acceptance Criteria" section to the feature overview template. This gives every feature a baseline set of criteria even before flows are written:

```markdown
## Acceptance Criteria
- [ ] [High-level criterion derived from core rules]
- [ ] [Another criterion]
```

These aren't flow-specific criteria (those live in flow docs). These are feature-level: "this feature works if and only if these things are true." Think of them as the minimum bar.

**Files to update:** Feature overview template in `spec.md` (Step 3), `init.md` (STEP CREATE), `plan.md` (flow template).

**Change 5B: Add a completion gate to `/arnold:spec`.**

After Step 4 (creating flow docs), add a verification step:

```
STEP 4.5: VERIFY COMPLETENESS

Before proceeding to the summary, scan every feature folder you just created.
For each feature, check:
  - Overview exists with Core Rules? (required)
  - Overview has Acceptance Criteria section with at least 2 checkboxes? (required)
  - If the spec described flows for this feature, do flow docs exist? (required)
  - If flow docs exist, do they each have Acceptance Criteria? (required)

If any required item is missing, create it now. Do not proceed to the summary
until this check passes.

Then add to the summary output:
  COMPLETENESS:
    [N]/[N] features have overview with criteria
    [N]/[N] documented flows have acceptance criteria
    [N] features need /arnold:plan for deeper planning
```

**Change 5C: Add a completion gate to `/arnold:plan`.**

After Step 6 (creating approved docs), add:

```
STEP 6.5: VERIFY CREATED DOCS

Re-read every file you just created. For each:
  - Does it have all required sections per the template?
  - If it's a flow doc, does it have:
    - Who section?
    - Happy Path with numbered steps?
    - What Could Go Wrong with at least one scenario?
    - Acceptance Criteria with at least 2 checkboxes?
  - If it's an edge cases doc, does each case have:
    - Scenario?
    - Why it matters?
    - How we handle it?

If any section is missing or empty, fill it now. Then proceed to Step 7.
```

**Why this works better than "try harder" prompting:**

1. It's structural: the verification step is a discrete step in the flow, not a vague instruction
2. It's specific: it names exact sections and counts (at least 2 checkboxes)
3. It's verifiable: the output includes a completeness report that the user can see
4. It creates accountability: if the report says "3/5 features have criteria," the gap is visible

---

## 6. Meta-Prompt Critique Passes

### What Exists

Arnold has no review or critique command. `/arnold:check` compares docs to code. `/arnold:plan` identifies doc gaps. But neither critiques the *quality or correctness* of the requirements themselves.

The team discussion identified three review angles that would catch real problems:
- **Usability:** The CoinBank "kids don't have email addresses" problem. A usability pass would ask "who are the actual users and what can they actually do?"
- **Product:** Are requirements complete? Conflicting? Missing states?
- **Technical:** Is this buildable? Are there impossible constraints?

### What To Change

**New command: `/arnold:review`**

This is a read-only command. It reads all docs and critiques them without editing.

```
/arnold:review              (all perspectives)
/arnold:review usability    (usability only)
/arnold:review product      (product only)
/arnold:review technical    (technical only)
```

**The meta-prompt structure:**

Each perspective is a "lens" -- a set of questions the reviewer asks while reading docs. The meta-prompt should:

1. Read all feature docs, overview, spec.md, unknowns, decisions
2. Apply the selected lens(es)
3. Report findings with severity

**Usability lens:**
- Who are the actual end users? What devices do they use? What's their technical skill level?
- For each flow: how many steps? Can any be eliminated? Are there dead ends?
- Are there user groups with different capabilities (children, elderly, non-English speakers)?
- For each error state: does the user know what went wrong and how to recover?
- Are there accessibility assumptions? (Can all users see the UI? Use a mouse?)

**Product lens:**
- For each feature: what's the entry state? What's the exit state? What happens in between?
- Are there missing states? (What if the user abandons mid-flow? What if data is partially saved?)
- Do any features conflict? (Feature A says X, Feature B assumes not-X)
- Are acceptance criteria actually testable? ("User has a good experience" is not testable)
- Are there implicit features not documented? (Every app with accounts needs password reset, but is it documented?)

**Technical lens (only runs if spec.md exists):**
- Can the chosen stack actually support the requirements?
- Are there performance implications? (Real-time features on a serverless stack?)
- Are there security gaps? (Auth flows without rate limiting? Sensitive data without encryption?)
- Are third-party dependencies risky? (Single points of failure, pricing changes, deprecation)
- Are there scaling assumptions that should be explicit?

**Output format:**

```
REVIEW FINDINGS

CRITICAL (must fix before building):
  1. [Usability] auth: Children are users but auth requires email.
     Kids under 13 typically don't have email addresses.
     Suggestion: Parent-managed sub-accounts with PIN access.
     Affects: auth-overview.md, auth-login-flow.md

IMPORTANT (should fix):
  2. [Product] booking: No documented behavior for partial payment failure.
     What happens if Stripe charges but the booking DB write fails?
     Suggestion: Add "payment succeeded, booking failed" edge case.

MINOR (consider):
  3. [Technical] spec.md: SQLite for dev, Postgres for prod.
     Behavioral differences (e.g., case sensitivity) may cause
     bugs that only appear in production.

Want me to create doc updates for any of these? (e.g., "fix 1 and 2")
```

**Implementation files:**
- `commands/arnold/review.md` (new)
- `skills/review/SKILL.md` (new)

**Why this is separate from check and plan:**

- `/arnold:check` compares docs to code. It's a mechanical comparison.
- `/arnold:plan` fills structural gaps (missing files). It's about coverage.
- `/arnold:review` critiques the substance. It's about quality and correctness.

These are three different activities. Combining them would make each worse.

---

## 7. Version Collision Bug

### What Exists

The `install.sh` script installs commands to `.claude/commands/arnold/`. The plugin installs skills to `skills/`. When both exist, Claude Code shows duplicate entries for commands like `/arnold:status`, and neither works correctly.

`install.sh` has `--uninstall` support (it removes `.claude/commands/arnold/` and strips Arnold rules from CLAUDE.md). But this isn't documented prominently.

### What's Wrong

1. No collision detection in either direction (installer doesn't check for plugin, plugin doesn't check for installer)
2. `--uninstall` is hidden. The README mentions it once, buried in the install section.
3. The team hit this in the CoinBank test and couldn't fix it during the session

### What To Change

**In `install.sh`:**
1. Before installing, check for plugin: `if [ -d ".claude-plugin" ] || [ -d "skills/init" ]; then` warn about potential collision
2. Add `--uninstall` to the help text that prints when no args are given

**In `/arnold:help`:**
Add a troubleshooting section:
```
TROUBLESHOOTING:
  If commands show up twice or fail to run, you may have both
  the shell-installed and plugin versions active.

  To remove the shell version:
    bash install.sh --uninstall

  To remove the plugin version:
    /plugin uninstall arnold
```

**In `README.md`:**
Add a visible "Uninstalling" section (not buried in install details).

**In `arnold-rules/SKILL.md`:**
No changes needed. This is a distribution/install problem, not a rules problem.

---

## 8. Redundancy Audit and Simplification

I went through the full codebase file by file. Here's every redundancy found, whether it matters, and what to do about it.

### 8A. The Dual Distribution Problem: commands/ vs skills/

**What exists:** Every command lives in two places: `commands/arnold/[name].md` and `skills/[name]/SKILL.md`. That's 14 commands x 2 locations = 28 prompt files. The CONTRIBUTING.md explicitly says: "When adding a new command, you must add it to BOTH."

**Current drift between them:** The skills versions are slightly ahead. Every skill has a "Command format note" that commands don't have. `skills/spec/SKILL.md` additionally has a `<context>` block for auto-scanning the docs folder that `commands/arnold/spec.md` lacks. These are minor but they're already diverging, and we're about to add 3 new commands (build, feature, review) which doubles the maintenance surface.

**The real cost:** Every change to a prompt has to be made twice. Every future contributor has to remember to edit both. The CONTRIBUTING.md warns about this, but it's a process solution to a structural problem. And the CoinBank test showed that when both install paths are active simultaneously, they collide.

**What to change:**

Option 1 (recommended): **Make commands/ the canonical source. Generate skills/ from commands/ with a script.**

Add a simple script (`sync-skills.sh` or a Makefile target) that:
1. For each `.md` in `commands/arnold/`, copies it to `skills/[name]/SKILL.md`
2. Prepends the skills YAML frontmatter
3. Adds the "Command format note" paragraph
4. For commands that need `<context>` blocks (status, diff, recap, spec), adds them

This eliminates manual dual-maintenance. One source, one generated copy. The script is 30-40 lines of bash and can run as a pre-commit hook or manually.

Option 2: **Drop commands/ entirely. Ship skills-only.**

The plugin path (`skills/`) works with Claude Code, Cursor, Windsurf, and Gemini CLI. The only thing `commands/` supports that `skills/` doesn't is the `install.sh` path, which copies commands to `.claude/commands/`. But `install.sh` could be updated to copy from `skills/` instead.

Downside: breaking change for anyone who's already installed via `install.sh`. The files would move from `.claude/commands/arnold/init.md` to `.claude/commands/arnold/init.md` (same path, different source). Actually, the paths wouldn't change for the user -- only the source.

**Recommendation:** Option 1 for now. It's non-breaking and solves the maintenance problem. Consider Option 2 for a major version bump.

### 8B. Three Copies of the Same Rules

**What exists:** The Arnold philosophy (Before Writing Code, After Writing Code, Document Structure, Conventions, Status Markers, etc.) appears in three places:

1. **Root `CLAUDE.md`** (103 lines) -- the template that gets installed into user projects
2. **`skills/arnold-rules/SKILL.md`** (109 lines) -- the background skill for the plugin path
3. **`.claude/CLAUDE.md`** (156 lines) -- Arnold's own project instructions

Files 1 and 2 are nearly identical (the skill has YAML frontmatter + one bug fix in the tree diagram where root CLAUDE.md has a doubled `[feature]-` prefix). File 3 is different by design -- it describes Arnold the project, not Arnold the tool.

**What's wrong:**

The root CLAUDE.md has a *bug* in its document structure diagram. Line 39 shows:
```
│   ├── [feature]-[feature]-overview.md   # What it does, core rules, assumptions
```
That doubled `[feature]-` prefix is wrong. The skills/arnold-rules version has it correct: `[feature-name]-overview.md`.

More importantly: when we update the philosophy (adding spec.md to the doc structure, adding new commands to the list, adding the tech-agnostic convention), we have to update it in all three files. That's the same dual-maintenance problem as commands/skills.

**What to change:**

1. **Fix the bug** in root CLAUDE.md (doubled `[feature]-` prefix)
2. **Make arnold-rules/SKILL.md the canonical source** for the tool philosophy. Have `install.sh` generate the root CLAUDE.md from the SKILL.md content (stripping the YAML frontmatter). This way there's one source of truth for the rules.
3. **Keep `.claude/CLAUDE.md` separate.** It serves a different purpose (project docs for Arnold itself) and should stay independent.

### 8C. The Build Spec Is Stale

**What exists:** `docs/ARNOLD-LITE-BUILD-SPEC.md` is the original monolithic build specification. It was written when Arnold had 5 commands (init, plan, check, update, status). It describes a `COMMANDS` array with only those 5. It contains the full `install.sh` source code from v0.1.0 (the build spec version says `ARNOLD_VERSION="0.1.0"` while the actual shipped install.sh is at 0.3.0). It contains the full README.md text from v0.1.0 (5 commands listed, no mention of spec, diff, decide, resolve, recap, help, bug, milestone, or archive).

The build spec served its purpose: it was the PRD that built Arnold v0.1. But Arnold has grown from 5 commands to 14, and the build spec hasn't been updated.

**What to change:**

Move it to `docs/reference/` using the pattern from workstream 1 (auto-archive). It's a historical document, not a current spec. Prepend a reference header:

```
> **Reference document.** This was the original v0.1.0 build specification.
> Arnold has since grown to 14 commands (v0.3.0). See the command files
> themselves for current behavior. Kept for historical reference.
```

Do NOT try to update it. The individual command `.md` files are now the source of truth for what each command does. The build spec would just be a third place to maintain the same information.

### 8D. install.sh Is Stale

**What exists:** The build spec contains the v0.1.0 install script. The actual shipped `install.sh` is 401 lines and at v0.3.0 with features the build spec version doesn't have (uninstall, verify, upgrade, plugin detection, marker-based CLAUDE.md injection). But there's a more fundamental problem:

The shipped `install.sh` only installs 5 commands:
```bash
COMMANDS=("init" "plan" "check" "update" "status")
```

Arnold has 14 commands. The other 9 (decide, resolve, recap, diff, spec, help, bug, milestone, archive) are NOT installed by the shell script. They're only available through the plugin path.

This is a silent feature gap. Anyone using `install.sh` instead of the plugin gets less than half of Arnold's functionality, and they have no way to know.

**What to change:**

Update the `COMMANDS` array in `install.sh`:
```bash
COMMANDS=("init" "plan" "check" "update" "status" "help" "decide" "resolve" "recap" "diff" "spec" "bug" "milestone" "archive")
```

Also update the install destination. Currently it installs to `.claude/commands/` (flat). But the actual command files are in `commands/arnold/` (namespaced). The installer should either:
- Install to `.claude/commands/arnold/` (preserving the namespace), or
- Rename files to include the `arnold:` prefix

This is related to the collision bug (workstream 7). The flat install path without namespacing is why commands collide with the plugin.

### 8E. README Documents 5 Commands; Arnold Has 14

**What exists:** The README's command table lists 5 commands:

```
| Command | What It Does |
|---------|-------------|
| `/init` | Scaffold a docs/ folder from your project description |
| `/plan` | Generate or refine feature docs, identify gaps |
| `/check` | Compare docs to code — find drift, missing docs, undocumented code |
| `/update` | Sync docs after coding — propose updates based on changes |
| `/status` | Quick snapshot — what's done, in progress, blocked |
```

The Quick Start section also only mentions these 5. The README was written for v0.1.0 and not updated when v0.2.0 added spec, diff, help, and v0.3.0 added decide, resolve, recap, bug, milestone, archive.

**What to change:**

Update the README command table and Quick Start to reflect all 14 (soon 17) commands. Group them logically (the `/arnold:help` output already has good groupings: Core Loop, Other Commands). Use that structure.

### 8F. Personality Boilerplate Is Repeated in Every Command

**What exists:** Every single command file starts with nearly identical boilerplate:

```
You are Arnold, a documentation-first development assistant. The user has run `/arnold:[X]` to [do Y].

Your personality: [adjective], [adjective], Jurassic Park themed. Use 🦕 exactly twice: once at start, once at end.
```

Then every command has the same STEP 0:
```
If `docs/overview.md` does not exist, say: "No docs/overview.md found. Run /arnold:init first." Stop.
```

That's ~50-80 tokens per command spent on the same identity and guard clause, repeated 14 times.

**What's wrong:**

This isn't a bug -- it's a design choice for independence. Each command file must work standalone because Claude Code loads only the invoked command, not all of them. The personality block ensures Arnold stays in character regardless of which command is called. The guard clause prevents crashes.

But `arnold-rules/SKILL.md` exists as a background skill (the plugin loads it automatically). If the plugin path is active, the personality and philosophy are already in context when any command runs. The per-command boilerplate is redundant for plugin users.

**What to change:**

For now: nothing. The repetition costs ~50 tokens per invocation, which is negligible. And it's necessary for the `install.sh` path where there's no background skill.

However, if we go with Option 2 from 8A (skills-only), we could extract the shared boilerplate into `arnold-rules/SKILL.md` and remove it from individual commands. That would save ~700 tokens across a typical session where a user runs several commands. File this under "future simplification."

### 8G. check vs. diff Overlap

**What exists:** `/arnold:check` and `/arnold:diff` both compare docs to code. Check is the full scan. Diff is the fast scan.

But the overlap is more specific than that:

- **Check Step 2** says: "If docs/.arnold-snapshot.json exists, read the commit field. Use git log to see all files changed since the last check. Focus your scan on these files first."
- **Diff Path A** says: "Read docs/.arnold-snapshot.json, get the commit hash. Run git diff to find changed files. Re-read ONLY that value."

So check already does incremental scanning when a snapshot exists. The difference is that check still reads the full codebase after the incremental pass, while diff stops after the targeted check.

**What's wrong:**

The functional gap between check and diff is smaller than it appears. If you've run check once (creating a snapshot), running check again is already partially incremental. Diff's main value is "don't read the full codebase at all," which saves tokens but gives lower confidence.

This isn't a problem to fix right now. Both commands serve distinct purposes. But as token budgets grow (larger context windows), the case for diff gets weaker. Monitor whether users actually use diff separately from check.

**No change recommended.** Just flagging the overlap for awareness.

### 8H. Recap vs. Status Overlap

**What exists:** Both commands read the same files and produce similar output:

**Status reads:** overview.md, status.md, feature overviews, unknowns.md, issues/, milestones.md, requests.md
**Recap reads:** overview.md, status.md, unknowns.md, git log, git diff

**Status outputs:** Project name, feature list with statuses, milestones, issues, requests, unknowns, decisions, last check date, quick actions
**Recap outputs:** Project name, changes since last check, feature list with statuses, unresolved drift, overdue decisions, suggested next action

The overlap: both show the feature list with status markers. Both show unknowns. Both suggest next actions.

The distinction: status is a reference view (what's the project state?). Recap is a session-start view (what changed since I was last here?). Recap uses git history; status doesn't.

**What's wrong:**

During the CoinBank test, the team ran status expecting to see the kind of detail that recap provides (changes since last session). The commands' names don't clearly signal the difference. "Status" sounds like "what's new" but it's really "what's current."

**What to change:**

Don't merge them. But improve the differentiation:

1. In `/arnold:help`, add explicit guidance: "Use `status` for a snapshot. Use `recap` at the start of a coding session."
2. If a user runs `status` and there's git history showing recent changes, add a one-line hint: "Tip: Run /arnold:recap to see what changed since your last session."
3. Consider renaming `recap` to `session` or `morning` in a future version to make the use case clearer. (Just a thought, not a v0.4 change.)

### Summary: What To Do About Redundancies

| ID | Issue | Action | Priority | Effort |
|----|-------|--------|----------|--------|
| 8A | commands/ vs skills/ dual maintenance | Add sync script (generate skills from commands) | P1 | S |
| 8B | Three copies of Arnold rules | Fix CLAUDE.md bug, make arnold-rules canonical | P1 | S |
| 8C | Build spec is stale (v0.1 content) | Move to docs/reference/ | P1 | S |
| 8D | install.sh only installs 5 of 14 commands | Update COMMANDS array, fix namespace | P0 | S |
| 8E | README lists 5 commands, Arnold has 14 | Update README command table and Quick Start | P1 | M |
| 8F | Personality boilerplate repeated 14x | No change now; future simplification if skills-only | P3 | - |
| 8G | check vs diff functional overlap | No change; monitor usage | - | - |
| 8H | recap vs status overlap | Improve differentiation in help, add hint | P2 | S |

---

## Priority and Build Order

| # | Workstream | Effort | Impact | Dependencies |
|---|-----------|--------|--------|-------------|
| 1 | install.sh installs 5/14 commands (8D) | S | Blocks all shell-install users from 9 commands | None |
| 2 | Version collision fix (7) | S | Unblocks testing | None |
| 3 | Fix CLAUDE.md bug + rules canonicalization (8B) | S | Prevents wrong file names in user projects | None |
| 4 | Add commands/skills sync script (8A) | S | Prevents future drift, reduces maintenance | None |
| 5 | Move stale build spec to reference (8C) | S | Reduces confusion about source of truth | None |
| 6 | Completeness enforcement (5) | M | Fixes the #1 quality complaint | None |
| 7 | Spec auto-archive (1) | S | Quick UX win | None |
| 8 | Update README to reflect all commands (8E) | M | Users can discover features they're paying for | None |
| 9 | Tech stack split (2) | L | Architectural, enables build | Should land before build |
| 10 | Feature command (3) | M | High visibility, loved in testing | Benefits from #6 |
| 11 | Improve recap vs status differentiation (8H) | S | Reduces user confusion | None |
| 12 | Build command (4) | XL | The big new thing | Depends on #6 and #9 |
| 13 | Review command (6) | M | Quality multiplier | Benefits from #6 |

**Recommended sequence:**

**Sprint 0 (housekeeping, do first):** Items 1-5. All small effort. Fixes the install.sh gap (9 missing commands is bad), the collision bug, the CLAUDE.md tree diagram bug, sets up the sync script, and archives the stale build spec. These are all existing file edits. Half a day of work, zero risk, and it cleans the foundation before we build on it.

**Sprint 1 (quality):** Items 6-8, 11. Completeness enforcement in spec and plan (the #1 complaint from testing), spec auto-archive (quick UX win), README update, and the recap/status clarification. These improve what Arnold already does before we add new things.

**Sprint 2 (architecture + visibility):** Items 9-10. Tech stack split (spec.md) is the biggest architectural change and should land before build. Feature command gives users the completeness matrix they loved in the CoinBank test.

**Sprint 3 (new capabilities):** Items 12-13. Build command and review command. These are the headline features for the next version. Build depends on spec.md (Sprint 2) and completeness enforcement (Sprint 1). Review is independent but benefits from complete docs.

---

## Files Changed Summary

### New Files (7)
| File | Command | Both locations |
|------|---------|------|
| `commands/arnold/build.md` | /arnold:build | + `skills/build/SKILL.md` |
| `commands/arnold/feature.md` | /arnold:feature | + `skills/feature/SKILL.md` |
| `commands/arnold/review.md` | /arnold:review | + `skills/review/SKILL.md` |

(That's 6 files total: 3 commands + 3 skills. Plus spec.md is a new file in user projects, generated by commands.)

### Modified Files (12)
| File | What Changes |
|------|-------------|
| `commands/arnold/spec.md` | Auto-archive step, spec.md generation, completeness gate, tech-agnostic feature docs |
| `commands/arnold/plan.md` | Completeness gate after doc creation, don't add tech to feature docs |
| `commands/arnold/check.md` | Check spec.md for tech drift, separate from feature doc checks |
| `commands/arnold/init.md` | Extract tech stack to spec.md (brownfield), completeness flags |
| `commands/arnold/decide.md` | Offer to update spec.md for tech decisions |
| `commands/arnold/help.md` | Add new commands, troubleshooting section, spec.md in doc structure |
| `commands/arnold/status.md` | Reference spec.md, show build readiness |
| `skills/arnold-rules/SKILL.md` | Add spec.md to doc structure, new commands to list, tech-agnostic convention |
| `CLAUDE.md` (template) | Same as arnold-rules |
| `install.sh` | Collision detection, better uninstall docs |
| `README.md` | New commands, uninstall section, spec.md documentation |
| `.claude/CLAUDE.md` | Update command table |

Plus mirror changes: every `commands/arnold/*.md` change gets mirrored to the corresponding `skills/*/SKILL.md`.

### Unchanged Commands (6)
`resolve.md`, `recap.md`, `diff.md`, `bug.md`, `milestone.md`, `archive.md` -- no changes needed.

---

## Open Questions

1. **Token budget for build loops.** The CoinBank session ran at 16-20k token limits. A single-feature build loop could easily hit that. Should `/arnold:build` auto-pause and say "token budget reached, run me again to continue"? Or should it just be scoped to small features?

2. **Should spec.md support multiple environments?** (dev stack vs. prod stack vs. staging). The current design has one Stack table. Real projects often have SQLite for dev, Postgres for prod. Could add an "Environments" section, but that's scope creep for v1.

3. **Review command: should it edit docs or just report?** Current design is report-only with an opt-in to apply. But if the usability review finds a critical issue, should it create the doc update automatically? Leaning toward report-only -- Arnold's convention is to propose and wait for approval.

4. **Build command: where does it live philosophically?** The build spec says Arnold is "Not an agentic loop." Adding `/arnold:build` crosses that line. Is this OK? The team says yes. But it changes Arnold's identity from "documentation toolkit" to "documentation-driven development toolkit." The README and positioning need to reflect this.

5. **Feature command vs. expanding status.** Could we just add `--features` to `/arnold:status` instead of a whole new command? The counter-argument: status is meant to be a 10-second glance. Feature-level completeness is a deeper view. Separate commands for separate depths. I lean toward the new command.

6. **What does "build readiness" actually mean?** The feature list table shows a "build readiness" line. What's the threshold? Proposal: a feature is "ready to build" if it has an overview with rules, at least one flow doc, and at least 3 acceptance criteria. Below that, it's "buildable but thin."

---

## What I Changed from v1

1. **Corrected the spec/SKILL.md claim.** It exists. I was wrong. Removed the "create skills/spec/SKILL.md" action item.
2. **Identified the structural cause of the laziness problem.** It's not just Claude being lazy -- the meta-prompts actively defer completeness from spec to plan, and plan has no verification loop. The fix is structural (completion gates), not motivational ("try harder").
3. **Made the tech stack split more concrete.** Showed the actual spec.md format, listed every command that needs changes and what specifically changes in each, and explained why it's spec.md not agents.md.
4. **Added acceptance criteria to feature overviews.** v1 didn't address that acceptance criteria only live in flow docs. If flows don't get created (laziness), there are zero criteria. Adding them to overviews gives a baseline.
5. **Cut the "agnostic mode toggle."** Replaced with graceful degradation: if spec.md doesn't exist, commands just skip it. No config needed.
6. **Separated the feature command design into three clear behaviors** (list, status, plan) instead of the vaguer "list, plan, status" from v1.
7. **Added the anti-laziness mechanism for build.** The criterion-to-code mapping requirement is more concrete than "explicit checklist gating."
8. **Reordered sprints.** v1 put collision fix and completeness in the same priority but didn't group them into a sprint. Now there's a clear 3-sprint sequence with rationale.
