<div align="center">
<h1>Arnold</h1>
<p>
<strong>Write requirements in plain English. Build with any coding agent. Check that what got built matches what you asked for.</strong>
</p>
<p>
<a href="https://github.com/ArtifactHQ/Arnold-Lite"><img src="https://img.shields.io/github/stars/ArtifactHQ/Arnold-Lite?style=for-the-badge&logo=github&color=181717" alt="GitHub stars" /></a>
<a href="https://discord.gg/m6sTcWSbZm"><img src="https://img.shields.io/badge/Discord-Join-5865F2?style=for-the-badge&logo=discord&logoColor=white" alt="Discord" /></a>
<a href="https://x.com/madebyartifact"><img src="https://img.shields.io/badge/X-@madebyartifact-000000?style=for-the-badge&logo=x&logoColor=white" alt="X (Twitter)" /></a>
<a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=for-the-badge" alt="License" /></a>
</p>
<br>
<pre><code>curl -fsSL https://raw.githubusercontent.com/ArtifactHQ/Arnold-Lite/main/install.sh | bash</code></pre>
<p><strong>No API key. No database. No Ruby. Works with Claude Code out of the box.</strong></p>
<br>
<p>
<a href="#why-we-built-this">Why We Built This</a> · <a href="#how-it-works">How It Works</a> · <a href="#what-drift-detection-looks-like">Drift Detection</a> · <a href="#quick-start">Quick Start</a> · <a href="#commands">Commands</a> · <a href="#doc-structure">Doc Structure</a>
</p>
</div>

---

## Why We Built This

You describe a product. A coding agent builds it. But it doesn't build everything you described, or it builds things you didn't ask for, or your spec goes stale the moment someone makes a manual edit.

That gap between "what I said to build" and "what actually got built" grows quietly over time. That's **documentation drift**, and most teams just live with it.

In AI-assisted development, it's worse. Claude forgets between sessions. Cursor loses context. Your coding agent doesn't know that the docs say one thing and the code does another, unless you check.

Arnold checks. It reads your docs and your code, then tells you where they've drifted apart. Not with automated pipelines or CI hooks, but with a conversation. You ask Arnold to check. Arnold tells you what's off. You decide what to fix.

The complexity is in the prompts, not your workflow. What you see: describe your product, write docs, build code, check the gap.

— **Artifact**

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
   📄 Docs say: "Sessions expire after 24 hours" (docs/auth/overview.md)
   💻 Code has: SESSION_TTL = 72 * 60 * 60 (src/config/auth.js)
   → Docs say 24hr, code says 72hr. Which is right?

2. booking: Capacity limit
   📄 Docs say: "Maximum 20 spots per class" (docs/booking/overview.md)
   💻 Code has: MAX_CAPACITY = 30 (src/models/class.js)
   → Docs say 20, code says 30.

🟢 ALIGNED
━━━━━━━━━━

  ✓ auth: Rate limit is 5 attempts per minute
  ✓ payments: Stripe is the payment processor
  ✓ booking: Users cannot book the same class twice

Run /arnold:resolve to fix drift items. 🦕
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

## Quick Start

### 1. Install

**Claude Code plugin** (recommended):

```
/plugin marketplace add ArtifactHQ/Arnold-Lite
/plugin install arnold@arnold-marketplace
```

Auto-updates, clean uninstall, automatic `/arnold:` namespacing. To uninstall:

```
/plugin uninstall arnold@arnold-marketplace
```

**Shell script** (works with any AI coding tool):

```bash
curl -fsSL https://raw.githubusercontent.com/ArtifactHQ/Arnold-Lite/main/install.sh | bash
```

Run this from your project's root directory. To uninstall: `./install.sh --uninstall` or re-run curl with `bash -s -- --uninstall`. To update, just re-run the install command.

Arnold commands live in `.claude/commands/arnold/` inside your project. Commit them to Git so team members who clone the repo get Arnold automatically.

**Works with other AI tools too.** Arnold's commands follow the [Agent Skills](https://agentskills.io) standard. Copy the skill folders from `skills/` into `.agents/skills/` in your project. Note: skill names like `init`, `check` are generic. Consider renaming to `arnold-init`, `arnold-check` to avoid conflicts with other tools.

The `skills/arnold-rules/` skill contains Arnold's documentation-first development rules. In Claude Code, it loads automatically as background context. In other tools, you can ignore it or reference it manually when needed.

Arnold's development rules are in `CLAUDE.md`. For other tools, copy this content to your tool's equivalent:
- **Cursor:** `.cursor/rules/arnold.md`
- **Windsurf:** `.windsurf/rules/arnold.md`
- **Gemini CLI:** `GEMINI.md`
- **Codex:** `AGENTS.md`

### 2. Initialize

In Claude Code:

```
/arnold:init
```

Describe your project. Arnold creates a `docs/` folder organized by feature. On existing codebases, Arnold scans your code and generates docs from what it finds.

For a fully automatic scan with no prompts, use `/arnold:init --auto`.

Make sure to commit your `docs/` folder to version control.

```
docs/
├── overview.md           # Your project vision
├── status.md             # What's done, what's next
├── auth/                 # Feature: authentication
│   └── overview.md
├── booking/              # Feature: booking system
│   └── overview.md
├── payments/             # Feature: payments
│   └── overview.md
├── decisions/            # Why you chose what you chose
└── unknowns.md           # Open questions and bets
```

### 3. Plan

```
/arnold:plan
```

Arnold reads your docs and codebase, then proposes more detailed documentation: flow docs, edge cases, acceptance criteria.

### 4. Build

Write code however you normally do. Claude Code, Cursor, by hand.

### 5. Check

```
/arnold:check
```

**This is the one.** Arnold reads your docs AND your code, then reports:

- What's documented but not built yet
- What's built but not documented
- Where code has drifted from docs (e.g., docs say session timeout is 24 hours, code says 72)

### 6. Update

```
/arnold:update
```

After a coding session, sync your docs. Arnold reads what changed and proposes updates.

---

## Commands

| Command | What It Does |
|---------|-------------|
| `/arnold:init` | Scaffold a `docs/` folder from your project description |
| `/arnold:plan` | Generate or refine feature docs, identify gaps |
| `/arnold:check` | Compare docs to code. Find drift, missing docs, undocumented code |
| `/arnold:update` | Sync docs after coding. Propose updates based on changes |
| `/arnold:status` | Quick snapshot: what's done, in progress, blocked |
| `/arnold:decide` | Record an architectural or product decision |
| `/arnold:resolve` | Fix drift items interactively. Choose docs or code for each |
| `/arnold:recap` | Start-of-session briefing: where you left off, what to do next |
| `/arnold:diff` | Quick drift scan. Fast summary without a full check |
| `/arnold:help` | Show all commands, when to use them, and doc structure |

Start with `/arnold:init`. The core loop is **init -> check -> resolve -> update**. Other commands are there when you need them.

---

## Doc Structure: Organized by Feature

Arnold organizes docs by feature, the way you think about your product. Not by document type.

```
docs/
├── overview.md              # Project north star
├── status.md                # Current state
│
├── auth/                    # One folder per feature
│   ├── overview.md          # What auth does, core rules
│   ├── login-flow.md        # Step-by-step happy path + errors
│   └── edge-cases.md        # Session expiry, lockouts, etc.
│
├── booking/
│   ├── overview.md
│   ├── reserve-spot.md
│   └── cancellation.md
│
├── decisions/               # Cross-cutting decisions
│   ├── 001-chose-stripe.md
│   └── 002-went-serverless.md
│
└── unknowns.md              # Open questions, bets, risks
```

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

When `/arnold:check` reports drift, you know whether the rule was something you explicitly asked for or something Arnold assumed.

---

## What Arnold Doesn't Do

**Doesn't rewrite your code.** Arnold reads and reports. You decide.

**Doesn't run automatically.** No CI hooks, no background processes. You run `/arnold:check` when you want to check.

**Doesn't require an API key.** It's Claude Code slash commands. If you have Claude Code, you have Arnold.

**Doesn't store data.** No database. Docs are markdown files in your repo, versioned with Git.

**Doesn't replace human judgment.** Sometimes docs are right and code is draft. Sometimes code diverged intentionally. Arnold flags the gap. You decide what to do about it.

---

## FAQ

<details>
<summary><strong>Do I need an API key?</strong></summary>
No. Arnold runs in Claude Code. No backend, no separate API key.
</details>

<details>
<summary><strong>Can I use Arnold on an existing project?</strong></summary>
Yes. Run <code>/arnold:init</code> on an existing codebase. Arnold reads your code and scaffolds docs that match. Then <code>/arnold:check</code> to find gaps.
</details>

<details>
<summary><strong>How does Arnold handle large codebases?</strong></summary>
Claude Code has a context window. For large projects, <code>/arnold:check</code> focuses on specific features or changed files. You can also scope checks: "check just the auth feature."
</details>

<details>
<summary><strong>Is this just for web apps?</strong></summary>
No. Any project with documentation: CLIs, libraries, APIs, data pipelines, mobile apps.
</details>

<details>
<summary><strong>Can I customize the doc structure?</strong></summary>
Yes. The feature-based structure is a strong default, not a requirement. Edit after <code>/arnold:init</code> runs.
</details>

---

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for version history.

---

## Built by Artifact

Arnold is the free, open-source documentation layer from [Artifact](https://artifact.new).

---

<div align="center">

**Arnold doesn't write your code. It makes sure your code matches your vision.**

**Hold on to your docs.** 🦕

Built by [Artifact](https://artifact.new).

</div>
