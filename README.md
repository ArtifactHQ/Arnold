<div align="center">
<h1>Arnold</h1>
<p>
<strong>Write requirements in plain English. Build with any coding agent.<br>Check that what got built matches what you asked for.</strong>
</p>
<p>
<a href="https://github.com/ArtifactHQ/arnold"><img src="https://img.shields.io/github/stars/ArtifactHQ/arnold?style=for-the-badge&logo=github&color=181717" alt="GitHub stars" /></a>
<a href="https://discord.gg/m6sTcWSbZm"><img src="https://img.shields.io/badge/Discord-Join-5865F2?style=for-the-badge&logo=discord&logoColor=white" alt="Discord" /></a>
<a href="https://x.com/madebyartifact"><img src="https://img.shields.io/badge/X-@madebyartifact-000000?style=for-the-badge&logo=x&logoColor=white" alt="X (Twitter)" /></a>
<a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=for-the-badge" alt="License" /></a>
</p>
<br>
<pre><code>curl -fsSL https://raw.githubusercontent.com/ArtifactHQ/arnold/main/install.sh | bash</code></pre>
<p><strong>No API key. No database. No Ruby. Works with Claude Code out of the box.</strong></p>
<br>
<p>
<a href="#why-we-built-this">Why We Built This</a> · <a href="#how-it-works">How It Works</a> · <a href="#quick-start">Quick Start</a> · <a href="#commands">Commands</a> · <a href="#doc-structure">Doc Structure</a>
</p>
</div>

---

## Why We Built This

You describe a product. A coding agent builds it. But it doesn't build everything you described, or it builds things you didn't ask for, or your spec goes stale the moment someone makes a manual edit.

That gap between "what I said to build" and "what actually got built" grows quietly over time. That's **documentation drift**, and most teams just live with it.

In AI-assisted development, it's worse. Claude forgets between sessions. Cursor loses context. Your coding agent doesn't know that the docs say one thing and the code does another — unless you check.

Arnold checks. It reads your docs and your code, then tells you where they've drifted apart. Not with automated pipelines or CI hooks — with a conversation. You ask Arnold to check. Arnold tells you what's off. You decide what to fix.

The complexity is in the prompts, not your workflow. What you see: describe your product, write docs, build code, check the gap.

— **Artifact**

---

## What Arnold Does

**Write product requirements through conversation.** Describe what you want in plain language. Arnold turns that into structured, feature-organized documentation: overviews, user flows, edge cases, acceptance criteria, decision records. Product-focused documents, not technical specifications.

**Keep docs next to your code.** Arnold puts a `docs/` folder in your project, organized by feature the way you actually think about your product. Auth in one place. Payments in another. Versioned with Git, readable by anyone.

**Check for drift between docs and code.** This is the big one. After code is written, run `/check` and Arnold reads both your docs and your codebase. It finds what's documented but not built, what's built but not documented, and where the code has diverged from the spec. You decide what to fix.

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
  You review and refine
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

Arnold doesn't rewrite your code or run tests. It reads, compares, and reports. You're always in control.

---

## How Arnold Is Different

**vs. Claude Code alone** — Claude is great at writing code. But every session starts fresh. Arnold gives Claude a persistent, structured source of truth in your `docs/` folder. Start a new session, Claude reads the docs, knows where things stand.

**vs. Spec tools (OpenSpec, GSD, etc.)** — Most spec tools focus on generating specs. Arnold keeps specs alive. The `/check` command compares your docs to your code and surfaces where they've diverged. That's the feature nobody else has in an open-source Claude Code extension.

**vs. Jira, Notion, static docs** — Those tools live outside your codebase. Arnold puts documentation right next to your code, in your editor, as markdown files you version-control with Git. When docs and code drift, Arnold sees it.

**vs. Just shipping** — Without Arnold, you're flying blind. The docs are wrong, the code is right (or vice versa), and nobody notices until someone needs to understand the system months later. Arnold makes the gap visible now.

---

## Quick Start

### 1. Install

```bash
curl -fsSL https://raw.githubusercontent.com/ArtifactHQ/arnold/main/install.sh | bash
```

Takes ~30 seconds. Copies slash commands into `.claude/commands/` and sets up your CLAUDE.md.

### 2. Initialize

In Claude Code:

```
/init
```

Describe your project. Arnold creates a `docs/` folder organized by feature:

```
docs/
├── overview.md           # Project north star
├── status.md             # What's done, in progress, blocked
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
/plan
```

Arnold reads your docs and codebase, then proposes more detailed documentation: step-by-step flows, edge cases, acceptance criteria. Approve what looks useful.

### 4. Build

Write code however you normally do. Claude Code, Cursor, by hand.

### 5. Check

```
/check
```

**This is the one.** Arnold reads your docs AND your code, then reports:

- What's documented but not built yet
- What's built but not documented
- Where code has drifted from docs

Use `/check` after every significant coding session.

### 6. Update

```
/update
```

After coding, sync your docs. Arnold reads what changed and proposes updates to keep things aligned.

---

## Commands

| Command | What It Does |
|---------|-------------|
| `/init` | Scaffold a `docs/` folder from your project description |
| `/plan` | Generate or refine feature docs, identify gaps |
| `/check` | Compare docs to code — find drift, missing docs, undocumented code |
| `/update` | Sync docs after coding — propose updates based on what changed |
| `/status` | Quick snapshot — what's done, in progress, blocked |

---

## Doc Structure

Arnold organizes docs **by feature**, the way you actually think about your product. Not by document type.

```
docs/
├── overview.md
│     Project mission, core features, current status.
│
├── status.md
│     What's done, in progress, blocked, unknown.
│
├── auth/
│   ├── overview.md          What auth does, core rules, assumptions
│   ├── login-flow.md        Step-by-step happy path + errors
│   └── edge-cases.md        Session expiry, lockouts, token handling
│
├── booking/
│   ├── overview.md
│   ├── reserve-spot.md
│   ├── cancellation.md
│   └── edge-cases.md
│
├── payments/
│   ├── overview.md
│   └── stripe-integration.md
│
├── decisions/
│   ├── 001-chose-stripe.md
│   └── 002-no-overbooking.md
│
└── unknowns.md
      Open questions, bets we're making, risks.
```

**Why this works:**

- When building login, `auth/` is all you need
- When someone asks "how do refunds work?" → `booking/cancellation.md`
- It scales — add features by adding folders, not by reorganizing everything
- A developer or PM can browse `docs/` and understand the project in 5 minutes

---

## Provenance: Where Did This Rule Come From?

Arnold tracks where requirements originate:

```markdown
## Core Rules

- Passwords must be at least 8 characters (Arnold-inferred — security best practice)
- Sessions expire after 24 hours (domain-derived — web app standard)
- Users can only book one spot per class (user-stated — Chris, kickoff meeting)
- Stripe is the payment processor (decided — see decisions/001-chose-stripe.md)
```

When `/check` reports drift, knowing the source matters. A user-stated rule that drifted is a bigger deal than an Arnold-inferred default.

---

## What Arnold Doesn't Do

**Doesn't rewrite your code.** Arnold reads and reports. You decide what to fix.

**Doesn't run automatically.** No CI hooks, no background processes. You run `/check` when you want.

**Doesn't require an API key.** If you have Claude Code, you have Arnold.

**Doesn't store data.** No database. Docs are markdown files in your repo.

**Doesn't replace your judgment.** Sometimes docs are right and code is draft. Sometimes code diverged intentionally. Arnold flags the gap. You decide.

---

## FAQ

<details>
<summary><strong>Do I need an API key?</strong></summary>

No. Arnold runs inside Claude Code. No backend, no separate API key, no authentication.

</details>

<details>
<summary><strong>Can I use Arnold on an existing project?</strong></summary>

Yes. Run `/init` on an existing codebase. Arnold reads your code and scaffolds docs to match. Then `/check` to find gaps.

</details>

<details>
<summary><strong>How does Arnold handle large codebases?</strong></summary>

Claude Code has a context window. For large projects, `/check` focuses on specific features or recent changes. You can scope it: "check just the auth feature."

</details>

<details>
<summary><strong>Is this just for web apps?</strong></summary>

No. Any project where documentation matters: CLIs, libraries, APIs, data pipelines, mobile apps.

</details>

<details>
<summary><strong>Can I customize the doc structure?</strong></summary>

Yes. Feature-based organization is a strong default, not a requirement. Rearrange after `/init` runs.

</details>

---

## Contributing

Arnold is open source. We welcome bug reports, feature requests, doc improvements, and new slash command ideas.

```bash
git clone https://github.com/ArtifactHQ/arnold.git
cd arnold
# Edit commands/ and CLAUDE.md, test in Claude Code
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

---

## Built by Artifact

Arnold is the free, open-source documentation layer from [Artifact](https://artifact.new).

If you love the doc structure but want **automated drift detection running in CI** — that's Arnold Engine, the private tooling behind [Artifact Services](https://artifact.new).

---

<div align="center">
<p><strong>Arnold doesn't write your code. It makes sure your code matches your vision.</strong></p>
<p>Hold on to your docs. 🦕</p>
<p>Built by <a href="https://artifact.new">Artifact</a>.</p>
</div>
