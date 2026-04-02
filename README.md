<div align="center">
<h1>Arnold</h1>
<p>
<strong>Write requirements in plain English. Build with any coding agent. Check that what got built matches what you asked for.</strong>
</p>
<p>
<a href="https://github.com/ArtifactHQ/arnold"><img src="https://img.shields.io/github/stars/ArtifactHQ/Arnold?style=for-the-badge&logo=github&color=181717" alt="GitHub stars" /></a>
<a href="https://discord.gg/m6sTcWSbZm"><img src="https://img.shields.io/badge/Discord-Join-5865F2?style=for-the-badge&logo=discord&logoColor=white" alt="Discord" /></a>
<a href="https://x.com/madebyartifact"><img src="https://img.shields.io/badge/X-@madebyartifact-000000?style=for-the-badge&logo=x&logoColor=white" alt="X (Twitter)" /></a>
<a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=for-the-badge" alt="License" /></a>
</p>
<br>
<pre><code>curl -fsSL https://raw.githubusercontent.com/ArtifactHQ/arnold/main/install.sh | bash</code></pre>
<p><strong>No API key. No database. Runs inside Claude Code, Cursor, Windsurf, and 30+ AI coding agents.</strong></p>
<br>
<p>
<a href="#why-we-built-this">Why We Built This</a> · <a href="#how-it-works">How It Works</a> · <a href="#what-drift-detection-looks-like">Drift Detection</a> · <a href="#your-first-5-minutes">First 5 Minutes</a> · <a href="#commands">Commands</a> · <a href="#doc-structure-organized-by-feature">Doc Structure</a>
</p>
</div>

---

> **Arnold is a set of commands for AI coding agents.** It works inside Claude Code, Cursor, Windsurf, Gemini CLI, and other tools that support slash commands or Agent Skills. Arnold is not a standalone CLI. You need an AI coding agent to use it.

## Why We Built This

You describe a product. A coding agent builds it. But it doesn't build everything you described, or it builds things you didn't ask for, or your spec goes stale the moment someone makes a manual edit.

That gap between "what I said to build" and "what actually got built" grows quietly over time. That's **documentation drift**, and most teams just live with it.

In AI-assisted development, it's worse. Claude forgets between sessions. Cursor loses context. Your coding agent doesn't know that the docs say one thing and the code does another, unless you check.

Arnold checks. It reads your docs and your code, then tells you where they've drifted apart. Not with automated pipelines or CI hooks, but with a conversation. You ask Arnold to check. Arnold tells you what's off. You decide what to fix.

The complexity is in the prompts, not your workflow. What you see: describe your product, write docs, build code, check the gap.

---

## How It Works

```
  You describe your product
          |
          v
  Arnold scaffolds structured docs
  (organized by feature, like a wiki)
          |
          v
  You build with Claude Code, Cursor, whatever
  (or let Arnold guide the build with /arnold:build)
          |
          v
  Arnold checks: does the code match the docs?
          |
     +----+----+
     |         |
   Aligned   Drifted
     |         |
     |         v
     |    Arnold shows you exactly
     |    what's off and where
     |         |
     v         v
  Keep building. Docs stay honest.
```

Arnold doesn't rewrite your code. It doesn't run tests. It reads, compares, and reports. You're always in control.

---

## What Drift Detection Looks Like

When you run `/arnold:check`, Arnold reads your docs and your code, then shows you exactly where they disagree:

```
🦕 ARNOLD CHECK REPORT
━━━━━━━━━━━━━━━━━━━━━━

Scanned: 4 feature docs, 23 source files

🔴 DRIFT DETECTED
━━━━━━━━━━━━━━━━━

1. auth: Session timeout
   📄 Docs say: "Sessions expire after 24 hours" (docs/auth/auth-overview.md)
   💻 Code has: SESSION_TTL = 72 * 60 * 60 (src/config/auth.js)
   → Docs say 24hr, code says 72hr. Which is right?

2. booking: Capacity limit
   📄 Docs say: "Maximum 20 spots per class" (docs/booking/booking-overview.md)
   💻 Code has: MAX_CAPACITY = 30 (src/models/class.js)
   → Docs say 20, code says 30.

🟢 ALIGNED
━━━━━━━━━━

  ✓ auth: Rate limit is 5 attempts per minute
  ✓ payments: Stripe is the payment processor
  ✓ booking: Users cannot book the same class twice

Run /arnold:resolve to fix drift items.
```

That gap between docs and code? Arnold finds it.

Arnold gets smarter with each check. After your first `/arnold:check`, Arnold saves a snapshot of every comparison it made. Future checks and `/arnold:diff` scans use that snapshot to detect changes instantly, only re-reading files that changed since the last check.

---

## How Arnold Is Different

**vs. Claude Code alone:** Claude is great at writing code, but every session starts fresh. Arnold gives Claude a persistent, structured source of truth in your `docs/` folder. When you start a new session, Claude reads the docs and knows exactly where things stand.

**vs. Spec tools (OpenSpec, GSD, etc.):** Most spec tools focus on generating specs. Arnold keeps specs alive. The `/arnold:check` command compares your docs to your code and tells you where they've diverged. That's the feature nobody else has in an open-source Claude Code extension.

**vs. Jira, Notion, and static docs:** Those tools live outside your codebase. Arnold puts documentation next to your code, in your editor, as markdown files you version-control with Git. When docs and code drift, Arnold sees it.

**vs. Just shipping:** Without Arnold, you're flying blind. The docs are wrong, the code is right (or vice versa), and nobody notices until someone needs to understand the system months later. Arnold makes the gap visible in real time.

---

## Install

Run this from your project's root directory:

```bash
curl -fsSL https://raw.githubusercontent.com/ArtifactHQ/arnold/main/install.sh | bash
```

That's it. Arnold's commands are now available as `/arnold:init`, `/arnold:check`, etc.

**What does install.sh do?** It copies 17 command files into `.claude/commands/arnold/` inside your project, and appends Arnold's development rules to your project's `CLAUDE.md` (creating one if it doesn't exist). No binaries, no dependencies, no background processes. Commit the `.claude/commands/arnold/` folder to Git so team members who clone the repo get Arnold automatically.

**Updating:** Re-run the same curl command. The script detects your current version and upgrades to the latest. Your `docs/` folder stays untouched — only the command files in `.claude/commands/arnold/` are replaced.

<details>
<summary><strong>Other install methods</strong></summary>

**From a cloned repo:**

If you downloaded or cloned Arnold, `cd` into your target project directory and run:

```bash
cd /path/to/your-project
bash /path/to/arnold/install.sh
```

The script detects it's running from a local repo and copies the commands directly — no network required.

**Works with other AI coding agents too.** Arnold's commands follow the [Agent Skills](https://agentskills.io) standard. Copy the skill folders from `skills/` into `.agents/skills/` in your project. Arnold's development rules are in `CLAUDE.md`. For other tools, copy this content to your tool's equivalent:
- **Cursor:** `.cursor/rules/arnold.md`
- **Windsurf:** `.windsurf/rules/arnold.md`
- **Gemini CLI:** `GEMINI.md`
- **Codex:** `AGENTS.md`

</details>

---

## Your First 5 Minutes

After installing, here's exactly what to do:

**Starting a new project (no code yet):**

```
/arnold:init
```

Arnold asks what you're building, who it's for, and what the core features are. Then it creates a `docs/` folder with an overview, feature folders, and open questions. Done — you're set up.

**Adding Arnold to an existing codebase:**

```
/arnold:init
```

Same command. Arnold detects existing code, scans your files, extracts features and rules, and generates docs that match what you've already built. Use `/arnold:init --auto` to skip the prompts entirely.

**Already have a spec or PRD:**

```
/arnold:spec docs/my-spec.md
```

Arnold reads your document, pulls out features, rules, decisions, and open questions, and creates structured docs from it. The original spec gets archived to `docs/reference/`.

**After setup, your next steps are:**

1. **Review** — look at the docs Arnold created in `docs/`. Are the features right? Any rules missing?
2. **Plan** — run `/arnold:plan` to flesh out thin docs with flows, edge cases, and acceptance criteria
3. **Build** — write code however you normally do (or run `/arnold:build` to let Arnold guide the build)
4. **Check** — run `/arnold:check` to see if what you built matches what the docs say

That's the loop: **build → check → fix → repeat.**

Commit your `docs/` folder to Git. That way it persists between sessions and teammates can see it.

---

## Commands

### The ones you'll use most

| Command | What it does |
|---------|-------------|
| `/arnold:init` | Set up docs for a new project, or scan an existing codebase and generate docs from it |
| `/arnold:check` | **The signature feature.** Compares every documented rule against your code. Finds where they disagree. |
| `/arnold:update` | After coding, sync your docs. Arnold reads your git diff and proposes updates. |
| `/arnold:plan` | Flesh out thin docs with flow docs, edge cases, and acceptance criteria |

These four commands cover 90% of daily use.

### The full set

<details>
<summary><strong>Setup commands</strong></summary>

| Command | When to use it |
|---------|---------------|
| `/arnold:init` | Starting a new project, or adding Arnold to an existing codebase. Use `--auto` to skip prompts. |
| `/arnold:spec` | You have a spec, PRD, or research document. Arnold decomposes it into feature-based docs. |

</details>

<details>
<summary><strong>Core loop — build, check, fix, sync</strong></summary>

| Command | When to use it |
|---------|---------------|
| `/arnold:check` | After coding. Compares every documented rule against your code. Finds drift. |
| `/arnold:resolve` | After check finds drift. Walks through each mismatch: "docs say X, code says Y, which is right?" |
| `/arnold:update` | After coding. Reads your git diff, proposes doc updates for anything new or changed. |
| `/arnold:diff` | Quick version of check. Only checks files that changed since the last check. |
| `/arnold:update --quick` | Batch mode. Scans recent git changes, proposes status updates in bulk. |

</details>

<details>
<summary><strong>Planning and management</strong></summary>

| Command | When to use it |
|---------|---------------|
| `/arnold:plan` | Docs are thin. Proposes flow docs, edge cases, and acceptance criteria. |
| `/arnold:feature` | See a completeness matrix for all features. Drill into one: `/arnold:feature auth`. Deep-plan: `/arnold:feature plan auth`. |
| `/arnold:decide` | Record a decision (e.g., "chose Stripe over Square") with context and trade-offs. |
| `/arnold:status` | Quick snapshot: feature statuses, open questions, last check date. |
| `/arnold:recap` | Start-of-session briefing. What changed since your last session, what to do next. |
| `/arnold:help` | Full command reference with troubleshooting. |
| `/arnold:bug` | Record a bug in docs/issues/ with severity, repro steps, and affected feature. |
| `/arnold:milestone` | Group features into phases with rollup status (e.g., "3/5 features complete"). |
| `/arnold:archive` | Move stale docs to docs/archive/ or legacy docs to docs/reference/. |

</details>

<details>
<summary><strong>Build and review</strong></summary>

| Command | When to use it |
|---------|---------------|
| `/arnold:build` | Build code from your docs. Reads acceptance criteria, guides the coding agent through the build, verifies each criterion is met before moving on. Scope to one feature: `/arnold:build auth`. |
| `/arnold:review` | Critique your docs for quality and correctness. Three lenses: usability, product, technical. Run `/arnold:review usability` for one lens, or `/arnold:review` for all. |

</details>

Most commands accept a feature name to scope them: `/arnold:check auth`, `/arnold:plan payments`, `/arnold:update booking`.

---

## Doc Structure: Organized by Feature

Arnold organizes docs by feature, the way you think about your product. Not by document type.

```
docs/
├── overview.md              # Project north star
├── spec.md                  # Technical specification (stack, architecture)
├── status.md                # Current state
├── milestones.md            # Phase tracking (optional)
│
├── auth/                    # One folder per feature
│   ├── auth-overview.md     # What auth does, core rules, acceptance criteria
│   ├── auth-login-flow.md   # Step-by-step happy path + errors
│   └── auth-edge-cases.md   # Session expiry, lockouts, etc.
│
├── booking/
│   ├── booking-overview.md
│   ├── booking-reserve-spot.md
│   └── booking-cancellation.md
│
├── issues/                  # Bug reports
│   └── 001-session-timeout-crash.md
│
├── decisions/               # Cross-cutting decisions
│   ├── 001-chose-stripe.md
│   └── 002-went-serverless.md
│
├── requests.md              # Feature requests
├── unknowns.md              # Open questions, bets, risks
├── archive/                 # Stale docs (historical)
└── reference/               # Legacy docs, original specs
```

**Product requirements live in feature folders (tech-agnostic). Technical decisions live in `docs/spec.md`.**

**Why this works:**
- When building login, `auth/` is all you need
- When someone asks "how do refunds work?" → `booking/cancellation.md`
- It scales: add features by adding folders
- It reads naturally: a developer or PM can browse `docs/` and understand the project in 5 minutes

### Source Provenance

Arnold tracks where rules come from:

- **(user-stated):** you said this explicitly
- **(domain-derived):** standard for this kind of app
- **(Arnold-inferred):** Claude reasoned this should exist
- **(decided):** team made a deliberate choice (links to decision record)
- **(code-derived):** extracted from reading an existing codebase

When `/arnold:check` reports drift, you know whether the rule was something you explicitly asked for or something Arnold assumed.

---

## Uninstalling

```bash
curl -fsSL https://raw.githubusercontent.com/ArtifactHQ/arnold/main/install.sh | bash -s -- --uninstall
```

Or if you installed from a cloned repo:
```bash
bash install.sh --uninstall
```

---

## What Arnold Doesn't Do

**Doesn't write code itself.** Arnold is prompts, not a runtime. It instructs your coding agent (Claude, Cursor, etc.) on what to build and how to check it. The agent does the work.

**Doesn't run automatically.** No CI hooks, no background processes. You run `/arnold:check` when you want to check.

**Doesn't require an API key.** It's slash commands for your coding agent. If you have Claude Code, you have Arnold.

**Doesn't store data.** No database. Docs are markdown files in your repo, versioned with Git.

**Doesn't replace human judgment.** Sometimes docs are right and code is draft. Sometimes code diverged intentionally. Arnold flags the gap. You decide what to do about it.

---

## FAQ

<details>
<summary><strong>I cloned/downloaded Arnold. How do I install it into my project?</strong></summary>

<code>cd</code> into your target project directory, then run <code>bash /path/to/Arnold/install.sh</code>. The script detects it's running from a local repo and copies the commands directly — no internet needed. You do NOT install Arnold inside the Arnold repo itself; you install it into the project you want to document.

</details>

<details>
<summary><strong>Do I need an API key?</strong></summary>

No. Arnold runs inside your coding agent (Claude Code, Cursor, etc.). No backend, no separate API key.

</details>

<details>
<summary><strong>Can I use Arnold on an existing project?</strong></summary>

Yes. Run <code>/arnold:init</code> on an existing codebase. Arnold reads your code and scaffolds docs that match. Then <code>/arnold:check</code> to find gaps.

</details>

<details>
<summary><strong>How does Arnold handle large codebases?</strong></summary>

For large projects, <code>/arnold:check</code> focuses on specific features or changed files. You can scope checks: <code>/arnold:check auth</code> to check just one feature.

</details>

<details>
<summary><strong>Is this just for web apps?</strong></summary>

No. Any project with documentation: CLIs, libraries, APIs, data pipelines, mobile apps.

</details>

<details>
<summary><strong>Can I customize the doc structure?</strong></summary>

Yes. The feature-based structure is a strong default, not a requirement. Edit after <code>/arnold:init</code> runs.

</details>

<details>
<summary><strong>What's the difference between /arnold:check and /arnold:diff?</strong></summary>

<code>/arnold:check</code> does a full comparison of all docs against all code. <code>/arnold:diff</code> only checks files that changed since your last check — faster, but less thorough. Use <code>diff</code> for quick sanity checks, <code>check</code> for a full audit.

</details>

<details>
<summary><strong>What's docs/spec.md?</strong></summary>

A technical specification file that Arnold generates to separate tech decisions (database, framework, hosting) from product requirements (features, flows, rules). Feature docs stay tech-agnostic so you can swap your stack without rewriting requirements.

</details>

---

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for version history.

---

## Built by Artifact

Arnold is the free, open-source documentation layer from [Artifact](https://artifact.new).

---

<div align="center">
<p><strong>Arnold doesn't write your code. It makes sure your code matches your vision.</strong></p>
<p><strong>Hold on to your docs.</strong> 🦕</p>
<p>Built by <a href="https://artifact.new">Artifact</a>.</p>
</div>
