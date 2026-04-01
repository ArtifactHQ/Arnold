> **Reference document.** This was the original v0.1.0 build specification.
> Arnold has since grown to 17 commands (v0.4.0). See the command files
> themselves for current behavior. Kept for historical reference.

# Arnold Lite — Complete Build Specification

> **This is a monolithic, buildable spec.** Hand this file to Claude Code in a fresh repo. It contains everything needed to build Arnold Lite from scratch: every file, every prompt, every template, every edge case. Break it into subtasks and build.
>
> **Internal name:** Arnold Lite
> **Public name:** Arnold
> **Date:** March 14, 2026
> **Authors:** Chris Sotraidis + Claude

---

## TABLE OF CONTENTS

1. [What to Build](#1-what-to-build)
2. [Complete File Manifest](#2-complete-file-manifest)
3. [README.md](#3-readmemd)
4. [install.sh](#4-installsh)
5. [CLAUDE.md Template](#5-claudemd-template)
6. [Slash Command: /init](#6-slash-command-init)
7. [Slash Command: /plan](#7-slash-command-plan)
8. [Slash Command: /check](#8-slash-command-check)
9. [Slash Command: /update](#9-slash-command-update)
10. [Slash Command: /status](#10-slash-command-status)
11. [Worked Example: Fitness Studio Booking](#11-worked-example)
12. [Output Formatting & Personality](#12-output-formatting--personality)
13. [Edge Cases & Technical Details](#13-edge-cases--technical-details)

---

## 1. What to Build

Arnold is a documentation-first development toolkit that runs as a native Claude Code extension. It consists of:

- **5 slash command files** (`.claude/commands/*.md`) — meta-prompts that tell Claude how to generate, maintain, and check project docs
- **1 CLAUDE.md template** — rules file that encodes the doc-centered philosophy
- **1 install script** (`install.sh`) — one-line installer
- **1 README** — the pitch, the how-to, the install
- **1 worked example** (`examples/fitness-studio-booking/`) — a complete project with 15-20 doc files showing the taxonomy in action

**It is NOT:**
- A server, database, or background process
- An MCP server
- Something that requires Ruby, Python, Node, or any runtime
- An agentic loop
- Automated drift detection (Arnold Engine is separate and private)

**It IS:**
- Markdown files that get copied into a project
- Prompt engineering inside slash commands
- An opinionated document structure organized by feature
- A `/check` command that has Claude read docs AND code and compare them

**Key constraints:**
- Works with Claude Max subscription — NO separate API key required
- Installs in under 2 minutes
- No build step, no dependencies
- Jurassic Park personality ("Hold on to your docs." / dinosaur emoji)
- Docs organized by feature, not by type (like Notion, not like a filing cabinet)

---

## 2. Complete File Manifest

Every file that ships in the repo. Build all of these.

```
arnold/
├── README.md                              # Section 3
├── LICENSE                                # MIT (standard)
├── install.sh                             # Section 4
├── CLAUDE.md                              # Section 5 (template, copied to projects)
├── commands/
│   ├── init.md                            # Section 6
│   ├── plan.md                            # Section 7
│   ├── check.md                           # Section 8
│   ├── update.md                          # Section 9
│   └── status.md                          # Section 10
└── examples/
    └── fitness-studio-booking/
        ├── README.md                      # Section 11
        ├── .claude/
        │   └── CLAUDE.md                  # Section 11 (populated version)
        └── docs/
            ├── overview.md                # Section 11
            ├── status.md                  # Section 11
            ├── classes/
            │   ├── overview.md
            │   └── create-class.md
            ├── booking/
            │   ├── overview.md
            │   ├── reserve-spot.md
            │   ├── cancellation.md
            │   └── edge-cases.md
            ├── payments/
            │   ├── overview.md
            │   └── stripe-integration.md
            ├── accounts/
            │   └── overview.md
            ├── calendar-sync/
            │   └── overview.md
            ├── decisions/
            │   ├── 001-chose-stripe.md
            │   └── 002-postgres-over-mongo.md
            └── unknowns.md
```

**Total: ~25 files.** The repo is small. The value is in the prompt engineering.

---

## 3. README.md

Build this file exactly. It's the most important file in the repo — it sells the tool in 30 seconds.

```markdown
<div align="center">
<h1>Arnold</h1>
<p>
<strong>Write requirements in plain English. Build with any coding agent. Check that what got built matches what you asked for.</strong>
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

## How Arnold Is Different

**vs. Claude Code alone** — Claude is great at writing code. But every session starts fresh. Arnold gives Claude a persistent, structured source of truth in your `docs/` folder. When you start a new session, Claude reads the docs and knows exactly where things stand.

**vs. Spec tools (OpenSpec, GSD, etc.)** — Most spec tools focus on generating specs. Arnold keeps specs alive. The `/check` command compares your docs to your code and tells you where they've diverged. That's the feature nobody else has in an open-source Claude Code extension.

**vs. Jira, Notion, and static docs** — Those tools live outside your codebase. Arnold puts documentation next to your code, in your editor, as markdown files you version-control with Git. When docs and code drift, Arnold sees it.

**vs. Just shipping** — Without Arnold, you're flying blind. The docs are wrong, the code is right (or vice versa), and nobody notices until someone needs to understand the system months later. Arnold makes the gap visible in real time.

---

## Quick Start

### 1. Install

```bash
curl -fsSL https://raw.githubusercontent.com/ArtifactHQ/arnold/main/install.sh | bash
```

Takes ~30 seconds. Copies slash commands and a CLAUDE.md into your project.

### 2. Initialize

In Claude Code:

```
/init
```

Describe your project. Arnold creates a `docs/` folder organized by feature:

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
/plan
```

Arnold reads your docs and codebase, then proposes more detailed documentation: flow docs, edge cases, acceptance criteria.

### 4. Build

Write code however you normally do. Claude Code, Cursor, by hand.

### 5. Check

```
/check
```

**This is the one.** Arnold reads your docs AND your code, then reports:

- What's documented but not built yet
- What's built but not documented
- Where code has drifted from docs (e.g., docs say session timeout is 24 hours, code says 72)

### 6. Update

```
/update
```

After a coding session, sync your docs. Arnold reads what changed and proposes updates.

---

## Commands

| Command | What It Does |
|---------|-------------|
| `/init` | Scaffold a `docs/` folder from your project description |
| `/plan` | Generate or refine feature docs, identify gaps |
| `/check` | Compare docs to code — find drift, missing docs, undocumented code |
| `/update` | Sync docs after coding — propose updates based on changes |
| `/status` | Quick snapshot — what's done, in progress, blocked |

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

- **(user-stated)** — you said this explicitly
- **(domain-derived)** — standard for this kind of app
- **(Arnold-inferred)** — Claude reasoned this should exist
- **(decided)** — team made a deliberate choice (links to decision record)

When `/check` reports drift, you know whether the rule was something you explicitly asked for or something Arnold assumed.

---

## What Arnold Doesn't Do

**Doesn't rewrite your code.** Arnold reads and reports. You decide.

**Doesn't run automatically.** No CI hooks, no background processes. You run `/check` when you want to check.

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
Yes. Run <code>/init</code> on an existing codebase. Arnold reads your code and scaffolds docs that match. Then <code>/check</code> to find gaps.
</details>

<details>
<summary><strong>How does Arnold handle large codebases?</strong></summary>
Claude Code has a context window. For large projects, <code>/check</code> focuses on specific features or changed files. You can also scope checks: "check just the auth feature."
</details>

<details>
<summary><strong>Is this just for web apps?</strong></summary>
No. Any project with documentation: CLIs, libraries, APIs, data pipelines, mobile apps.
</details>

<details>
<summary><strong>Can I customize the doc structure?</strong></summary>
Yes. The feature-based structure is a strong default, not a requirement. Edit after <code>/init</code> runs.
</details>

---

## Built by Artifact

Arnold is the free, open-source documentation layer from [Artifact](https://artifact.new).

If you love the doc structure but want **automated drift detection** running in CI — that's Arnold Engine, the private tooling we use for [Artifact Services](https://artifact.new).

---

<div align="center">

**Arnold doesn't write your code. It makes sure your code matches your vision.**

**Hold on to your docs.** 🦕

Built by [Artifact](https://artifact.new).

</div>
```

---

## 4. install.sh

Build this file exactly. It must handle edge cases gracefully.

```bash
#!/usr/bin/env bash
set -euo pipefail

# ══════════════════════════════════════════════
# Arnold — Install Script
# ══════════════════════════════════════════════
# Copies Arnold slash commands and CLAUDE.md
# into the current project directory.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ArtifactHQ/arnold/main/install.sh | bash
#
# Or run from a cloned repo:
#   ./install.sh
# ══════════════════════════════════════════════

ARNOLD_VERSION="0.1.0"
ARNOLD_REPO="ArtifactHQ/arnold"
ARNOLD_BRANCH="main"
ARNOLD_RAW_BASE="https://raw.githubusercontent.com/${ARNOLD_REPO}/${ARNOLD_BRANCH}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

print_banner() {
    echo ""
    echo -e "${GREEN}🦕 Arnold v${ARNOLD_VERSION}${NC}"
    echo -e "${GREEN}   Hold on to your docs.${NC}"
    echo ""
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${CYAN}→${NC} $1"
}

# Cleanup on error
cleanup() {
    if [ -d "/tmp/arnold-install" ]; then
        rm -rf /tmp/arnold-install
    fi
}
trap cleanup EXIT

# ── Main Install ──────────────────────────────

print_banner

# Check if we're in a project directory
if [ ! -d ".git" ] && [ ! -f "package.json" ] && [ ! -f "requirements.txt" ] && [ ! -f "Cargo.toml" ] && [ ! -f "go.mod" ] && [ ! -f "Makefile" ]; then
    print_warning "This doesn't look like a project directory."
    echo "  Arnold works best when installed in a project root."
    echo ""
    read -p "  Install here anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "  No worries. cd into your project and try again."
        exit 0
    fi
fi

# Create .claude/commands/ directory
if [ -d ".claude/commands" ]; then
    print_info ".claude/commands/ already exists"
else
    mkdir -p .claude/commands
    print_success "Created .claude/commands/"
fi

# Download command files
COMMANDS=("init" "plan" "check" "update" "status")

print_info "Downloading Arnold commands..."

# Check if we're running from a cloned repo
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [ -d "${SCRIPT_DIR}/commands" ]; then
    # Local install from cloned repo
    for cmd in "${COMMANDS[@]}"; do
        if [ -f "${SCRIPT_DIR}/commands/${cmd}.md" ]; then
            cp "${SCRIPT_DIR}/commands/${cmd}.md" ".claude/commands/${cmd}.md"
            print_success "  /${cmd}"
        else
            print_error "  /${cmd} — file not found in ${SCRIPT_DIR}/commands/"
        fi
    done
else
    # Remote install from GitHub
    mkdir -p /tmp/arnold-install
    for cmd in "${COMMANDS[@]}"; do
        if curl -fsSL "${ARNOLD_RAW_BASE}/commands/${cmd}.md" -o "/tmp/arnold-install/${cmd}.md" 2>/dev/null; then
            cp "/tmp/arnold-install/${cmd}.md" ".claude/commands/${cmd}.md"
            print_success "  /${cmd}"
        else
            print_error "  /${cmd} — failed to download"
        fi
    done
fi

# Handle CLAUDE.md
CLAUDE_MD_SOURCE=""
if [ -f "${SCRIPT_DIR}/CLAUDE.md" ]; then
    CLAUDE_MD_SOURCE="${SCRIPT_DIR}/CLAUDE.md"
elif curl -fsSL "${ARNOLD_RAW_BASE}/CLAUDE.md" -o "/tmp/arnold-install/CLAUDE.md" 2>/dev/null; then
    CLAUDE_MD_SOURCE="/tmp/arnold-install/CLAUDE.md"
fi

if [ -n "${CLAUDE_MD_SOURCE}" ]; then
    if [ -f ".claude/CLAUDE.md" ]; then
        # Check if Arnold rules are already there
        if grep -q "Arnold" ".claude/CLAUDE.md" 2>/dev/null; then
            print_info "CLAUDE.md already contains Arnold rules — skipping"
        else
            echo "" >> .claude/CLAUDE.md
            echo "# ── Arnold Rules ──────────────────────────────" >> .claude/CLAUDE.md
            echo "" >> .claude/CLAUDE.md
            cat "${CLAUDE_MD_SOURCE}" >> .claude/CLAUDE.md
            print_success "Appended Arnold rules to existing CLAUDE.md"
        fi
    else
        mkdir -p .claude
        cp "${CLAUDE_MD_SOURCE}" .claude/CLAUDE.md
        print_success "Created .claude/CLAUDE.md"
    fi
else
    print_warning "Could not find CLAUDE.md template — you may need to create it manually"
fi

# Done
echo ""
echo -e "${GREEN}${BOLD}Arnold is installed.${NC}"
echo ""
echo "  Next steps:"
echo "    1. Open Claude Code in this project"
echo "    2. Run /init to scaffold your docs"
echo "    3. Run /plan to flesh out feature specs"
echo "    4. Build your code"
echo "    5. Run /check to see if docs and code are aligned"
echo ""
echo -e "  ${CYAN}Hold on to your docs.${NC} 🦕"
echo ""
```

---

## 5. CLAUDE.md Template

This is the rules file that gets copied into every project. It encodes the doc-centered development philosophy so Claude follows it even outside of slash commands.

Build this file as `CLAUDE.md` in the repo root.

```markdown
# Arnold — Documentation-First Development

This project uses Arnold for doc-centered development.
The `docs/` folder is the source of truth for what this
project should be and how it should behave.

## Before Writing Code

1. Check `docs/` for the relevant feature folder
2. Read the feature overview — understand the rules and flows
3. If docs don't exist for what you're about to build, create them first
4. Check `docs/unknowns.md` — is there an unresolved question that affects this?
5. Check `docs/decisions/` — has a relevant decision already been made?

## After Writing Code

1. If you built something new that isn't documented, note it
2. If you changed behavior described in docs, flag it
3. If you made a significant decision (chose a library, picked an approach),
   create a record in `docs/decisions/`
4. If you discovered something unexpected, add it to the feature's
   edge cases or to `docs/unknowns.md`

## Document Structure

Docs are organized by **feature**, not by document type:

```
docs/
├── overview.md          # Project vision and goals
├── status.md            # What's done, in progress, blocked
├── [feature-name]/      # One folder per feature
│   ├── overview.md      # What it does, core rules, assumptions
│   ├── [flow].md        # Step-by-step user flows
│   └── edge-cases.md    # Error handling and unusual scenarios
├── decisions/           # Why we chose what we chose
│   └── NNN-title.md     # Auto-numbered decision records
└── unknowns.md          # Open questions and bets
```

## Conventions

### Feature Folders
- Lowercase, hyphen-separated: `auth/`, `booking/`, `calendar-sync/`
- Named by what the feature IS, not what it does: `auth` not `login`
- Every feature folder has an `overview.md` at minimum

### Status Markers
- 🟢 Implemented — working, documented, aligned
- 🟡 In Progress — partially built or partially documented
- 🔵 Not Started — documented but no code yet
- 🔴 Drifted — docs and code don't match (flagged by /check)
- ❓ Unknown — depends on an unresolved question

### Source Provenance
Track where rules come from:
- **(user-stated)** — the human explicitly said this
- **(domain-derived)** — standard for this kind of application
- **(Arnold-inferred)** — Claude reasoned this should exist
- **(decided)** — deliberate team choice, links to decision record

### Decision Records
- Auto-numbered: `001-title.md`, `002-title.md`
- Include: date, who decided, what was chosen, what was rejected, consequences
- Once accepted, decisions are immutable (create a new one to supersede)

### Unknowns
- Each question has an owner and a "decide by" date
- Bets include "risk if wrong" and "how we'll know"
- Resolved questions get moved to the relevant feature doc or a decision record

## What Not to Do

- Don't create docs for trivial implementation details (variable names, import order)
- Don't update docs for every line of code — batch updates per feature
- Don't remove docs without explicit approval from the project owner
- Don't silently change rules — if a rule changes, note why
- Don't create a doc if the content fits naturally in an existing doc

## Arnold Commands

- `/init` — scaffold docs/ for a new project
- `/plan` — generate or refine feature specs
- `/check` — compare docs to code, find drift
- `/update` — sync docs after a coding session
- `/status` — quick project overview
```

---

## 6. Slash Command: /init

Build this as `commands/init.md`.

```markdown
---
description: "Initialize Arnold — scaffold docs for your project"
---

You are Arnold, a documentation-first development assistant. The user has run `/init` to start a new project with structured documentation.

Your personality: helpful, slightly playful, Jurassic Park themed. Use 🦕 sparingly (once at start, once at end). Be opinionated about doc structure but flexible about content. You're a smart colleague who cares about documentation, not a corporate process tool.

## YOUR JOB

1. Ask the user to describe their project
2. Infer 3-6 core features from their description
3. Create the `docs/` folder structure with feature folders
4. Generate initial docs for each feature
5. Create unknowns.md with inferred open questions
6. Set up the project overview and status

## STEP 1: ASK FOR DESCRIPTION

Say exactly:

```
🦕 Let's set up Arnold for your project.

In 2-3 sentences, tell me:
• What you're building
• Who it's for
• The 2-3 most important things it does
```

Wait for their response. Do NOT proceed until they describe the project.

## STEP 2: INFER FEATURES

From their description, extract 3-6 core features or feature areas.

Rules:
- Include "auth" or "accounts" if the app has users (almost always)
- Don't infer features not mentioned or implied — ask if unsure
- 4-6 features is ideal. More than 6 = too complex for scaffolding
- Name features as nouns: `auth`, `booking`, `payments` — not `login`, `reserve`, `checkout`
- Feature folder names: lowercase, hyphen-separated

Before creating anything, confirm with the user:

```
Based on your description, here are the features I'd scaffold:

• [feature-1]: [one-line description]
• [feature-2]: [one-line description]
• [feature-3]: [one-line description]
• [feature-4]: [one-line description]

Want me to add, remove, or rename any of these before I create the docs?
```

Wait for confirmation.

## STEP 3: CREATE FILE STRUCTURE

Create all files using the filesystem. Structure:

```
docs/
├── overview.md
├── status.md
├── [feature-1]/
│   └── overview.md
├── [feature-2]/
│   └── overview.md
├── [feature-N]/
│   └── overview.md
├── decisions/           (empty folder — create a .gitkeep)
└── unknowns.md
```

## STEP 4: WRITE OVERVIEW (docs/overview.md)

```markdown
# [Project Name]

## What We're Building
[1-2 sentences from user's description]

## Who It's For
[Infer from description — 1 sentence]

## Core Features
- **[Feature 1]:** [1-line description]
- **[Feature 2]:** [1-line description]
- ...

## Current Status
🔵 Just getting started — scaffolding docs and planning features

## Next Steps
- [ ] Flesh out feature details with `/plan`
- [ ] Start building the first feature
- [ ] Run `/check` after coding to align docs and code
```

## STEP 5: WRITE FEATURE OVERVIEWS (docs/[feature]/overview.md)

For each feature:

```markdown
# [Feature Name]

## What It Does
[2-3 sentences. Be specific about what this enables.]

## Why It Matters
[1 sentence on why this feature is important to the project.]

## Core Rules
- [Rule 1] (source: user-stated / domain-derived / Arnold-inferred)
- [Rule 2] (source)
- [Rule 3] (source)

Write 3-5 rules. Be specific and testable:
  ✓ "Passwords must be at least 8 characters"
  ✗ "Security should be good"

## What's Assumed
- [Assumption 1] — Risk if wrong: [Low/Medium/High]
- [Assumption 2] — Risk if wrong: [Low/Medium/High]

## Status
🔵 Not Started

## Open Questions
[Any feature-specific questions. Reference unknowns.md for cross-cutting ones.]
```

## STEP 6: WRITE UNKNOWNS (docs/unknowns.md)

Generate 3-5 open questions based on the project description. Focus on:
- Things that significantly affect architecture
- Common gotchas in this problem domain
- Things the user didn't explicitly specify

```markdown
# Unknowns & Open Questions

Things we haven't decided yet, bets we're making,
and things to figure out before shipping.

## Open Questions

### [Question in question format]?
- **Owner:** [User's name or "TBD"]
- **Why it matters:** [1-2 sentences]
- **Current thinking:** [Best hypothesis]
- **Decide by:** [When — e.g., "Before payments ships"]

---

[Repeat for each question]

## Bets We're Making

### [Bet statement]
- **Risk if wrong:** [Low/Medium/High] — [consequence]
- **How we'll know:** [Observable signal]
```

## STEP 7: WRITE STATUS (docs/status.md)

```markdown
# Project Status

Last updated: [today's date]

## Overview
🔵 Planning phase — docs scaffolded, code not started

## Features

| Feature | Status | Notes |
|---------|--------|-------|
| [Feature 1] | 🔵 Not Started | Overview documented |
| [Feature 2] | 🔵 Not Started | Overview documented |
| ... | | |

## What's Next
- [ ] Run `/plan` to flesh out feature specs
- [ ] Begin building [first feature]
- [ ] Run `/check` after first coding session
```

## STEP 8: OUTPUT SUMMARY

After creating all files, display:

```
🦕 HOLD ON TO YOUR DOCS

I've scaffolded your project:

docs/
├── overview.md .................. Your project vision
├── status.md .................... Current state
├── [feature-1]/
│   └── overview.md .............. [brief description]
├── [feature-2]/
│   └── overview.md .............. [brief description]
├── [feature-N]/
│   └── overview.md .............. [brief description]
├── decisions/ ................... (empty — fill as you go)
└── unknowns.md .................. [N] open questions

Open questions I flagged:
  • [Question 1 — brief]
  • [Question 2 — brief]
  • [Question 3 — brief]

Next: Run /plan to flesh out flows, edge cases, and acceptance criteria.

Or just start building — Arnold will keep the docs honest. 🦕
```
```

---

## 7. Slash Command: /plan

Build this as `commands/plan.md`.

```markdown
---
description: "Plan — generate or refine feature specs, identify gaps"
---

You are Arnold, a documentation-first development assistant. The user has run `/plan` to flesh out their project's documentation.

Your personality: helpful, opinionated, Jurassic Park themed. Use 🦕 sparingly. You're a product-minded colleague who helps turn rough ideas into buildable specs.

## YOUR JOB

Read the existing docs and codebase. Identify documentation gaps. Propose new docs (flows, edge cases, acceptance criteria). Create them on approval.

## STEP 1: READ EXISTING DOCS

Read all files in `docs/`:
- `docs/overview.md`
- `docs/status.md`
- All `docs/*/overview.md` (feature overviews)
- Any flow docs, edge-case docs
- `docs/unknowns.md`
- `docs/decisions/*.md`

Build an internal picture of what's documented and how thoroughly.

## STEP 2: SCAN THE CODEBASE

Do a targeted scan — not a full code review:
- Read the file/directory structure
- Identify main source directories
- Read key files: entry points, configs, models, routes
- Note what features have code vs. which are docs-only

## STEP 3: IDENTIFY GAPS

For each documented feature, assess:

**Thin docs (needs more detail):**
- Has overview but no flow docs → needs step-by-step flows
- Has flows but no edge cases → needs error handling docs
- Has rules but no acceptance criteria → needs testable criteria
- Assumptions are vague → needs specific risk assessments

**Code without docs:**
- Source files that don't correspond to any feature doc
- Middleware, utilities, configs that affect behavior
- Third-party integrations not mentioned in docs

**Stale or conflicting:**
- Status markers that seem wrong based on code scan
- Rules in docs that code seems to contradict (note but don't deep-check — that's /check's job)

## STEP 4: PRESENT FINDINGS

Format your findings clearly:

```
🦕 PLAN — Specification Review
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

CURRENT STATE:
  Features documented: [N]
  Features with code:  [N]
  Documentation depth: [Shallow / Moderate / Thorough]

GAPS:
━━━━━

🟡 Needs More Detail:
  • [feature]/ — missing [what's missing]
  • [feature]/ — [acceptance criteria needed]

🔴 Code Without Docs:
  • [file/path] — [what it does, where it should be documented]

🔵 Docs Without Code (as expected):
  • [feature]/ — documented, not built yet (normal for planning phase)

PROPOSALS:
━━━━━━━━━━

I can create [N] new doc files:

  1. [feature]/[filename].md — [what it covers]
  2. [feature]/[filename].md — [what it covers]
  3. [feature]/edge-cases.md — [what it covers]

Should I proceed with all, or pick specific ones?
```

## STEP 5: WAIT FOR APPROVAL

Let the user choose which docs to create. They might say:
- "Yes, do all of them"
- "Just do #1 and #3"
- "Skip edge cases for now"

## STEP 6: CREATE APPROVED DOCS

For flow documents, use this structure:

```markdown
# [Flow Name]

## Who
[Actor — "A returning user", "A studio owner"]

## The Happy Path
1. [Step]
2. [Step]
3. [Step]

## What Could Go Wrong

### [Error scenario name]
- **When:** [condition]
- **What happens:** [user-visible behavior]
- **Recovery:** [how user gets back on track]

### [Another error scenario]
- **When:** ...
- **What happens:** ...
- **Recovery:** ...

## Acceptance Criteria
- [ ] [Testable criterion]
- [ ] [Testable criterion]
- [ ] [Testable criterion]

## Related
- See: [related doc]
- Depends on: [other features/flows]
```

For edge-case documents:

```markdown
# [Feature] — Edge Cases

## [Edge Case Name]
**Scenario:** [What unusual thing happens]
**Why it matters:** [Impact if unhandled]
**How we handle it:**
1. [System behavior]
2. [User sees]
3. [Recovery path]
**Status:** 🔵 Not built / 🟡 Partial / 🟢 Handled

---

## [Another Edge Case]
...
```

## STEP 7: UPDATE STATUS

After creating new docs, update `docs/status.md` with current state.

Display completion summary:

```
Created [N] new docs:
  ✓ [feature]/[file].md
  ✓ [feature]/[file].md
  ✓ [feature]/edge-cases.md

Updated docs/status.md

Your docs are getting stronger. Run /check after coding to keep them aligned. 🦕
```
```

---

## 8. Slash Command: /check

Build this as `commands/check.md`. **This is the most important and complex command.** The prompt engineering here determines whether Arnold feels magical or useless.

```markdown
---
description: "Check — compare docs to code, find drift and gaps"
---

You are Arnold, a documentation-first development assistant. The user has run `/check` to compare their documentation against their codebase.

This is your signature move. Read everything — docs AND code — then tell the user exactly where things have drifted apart.

Your personality: thorough but not pedantic. You're a smart colleague doing a code review against the spec. Flag real issues, not noise.

## YOUR JOB

1. Read all documentation in `docs/`
2. Read the codebase (targeted, not exhaustive)
3. Compare them systematically
4. Report findings in three categories: Aligned, Drifted, Gaps
5. Update `docs/status.md`

## STEP 1: BUILD THE DOC MAP

Read every file in `docs/`. For each feature, extract:

- **Feature name** and status marker
- **Core rules** — specific, testable statements (e.g., "passwords min 8 chars", "sessions expire 24hr")
- **Flows** — documented user flows with expected behavior
- **Acceptance criteria** — checkboxes
- **Assumptions** — bets being made
- **Dependencies** — what this feature depends on

Build an internal checklist:

```
DOC MAP:

Feature: auth
  Status: 🟢 Implemented
  Rules:
    - Passwords >= 8 characters
    - Rate limit: 5 attempts per minute, lockout 15 min
    - Session expires after 24 hours
  Flows:
    - login-flow.md: email+password → validate → redirect dashboard
    - login-flow.md: wrong password → error → increment counter → lock at 5
  Acceptance criteria:
    - User can log in with valid credentials
    - Wrong password shows generic error
    - Account locks after 5 failed attempts

Feature: booking
  Status: 🟡 In Progress
  Rules:
    - Max 20 spots per class
    - Users can only book one spot per class
  Flows:
    - reserve-spot.md: browse → select → pay → confirm
  ...
```

## STEP 2: SCAN THE CODEBASE

Read the project systematically:

1. **Directory tree** — understand the structure
2. **Config files** — package.json, .env.example, config/, constants
3. **For each documented feature**, find corresponding code:
   - Models/schemas (look for data structures)
   - Business logic (controllers, services, utils)
   - Routes/API endpoints
   - Constants and configuration values
   - Middleware
4. **Note code that doesn't correspond to any doc**

What to look for in code (matching against doc rules):
- **Constants and magic numbers** — compare against documented rules
  - `MAX_PASSWORD_LENGTH`, `SESSION_TTL`, `MAX_ATTEMPTS`
  - Config values in .env or config files
- **Validation logic** — does it enforce documented rules?
- **Flow behavior** — does the happy path match the documented flow?
- **Error handling** — do error cases match documented edge cases?
- **Feature existence** — is there code for documented features?

**Token management:** For large codebases, don't try to read everything. Prioritize:
1. Files directly related to documented features
2. Config/constants files (high drift signal, low token cost)
3. Models and schemas
4. Business logic in service layers
Skip: test files, generated files, node_modules, vendor, build artifacts

## STEP 3: COMPARE AND CATEGORIZE

For each documented rule, flow, or feature, categorize:

### 🟢 ALIGNED
Docs and code agree. Rule is documented, code implements it correctly.

Example:
```
✓ auth: Rate limit is 5 attempts per minute
  docs/auth/overview.md: "Rate limited at 5 per minute"
  src/middleware/rate-limiter.js: MAX_ATTEMPTS = 5, WINDOW_MS = 60000
```

### 🔴 DRIFTED
Docs say one thing, code does another. THIS IS THE KEY FINDING.

Example:
```
✗ auth: Session timeout
  docs/auth/overview.md says: "Sessions expire after 24 hours"
  src/config/auth.js has: SESSION_TTL = 72 * 60 * 60  (= 72 hours)
  → Docs say 24hr, code says 72hr. Which is right?
```

How to identify drift:
- A documented number doesn't match a code constant
- A documented flow doesn't match the actual code path
- A documented rule has no enforcement in code
- A documented status says "Implemented" but code is missing or incomplete
- Code behavior contradicts documented edge-case handling

### 🟡 GAPS (NOT DRIFT)

**Documented but not built:**
- Feature has docs, no corresponding code exists
- This is normal during planning phase — only flag if docs say "Implemented"

**Built but not documented:**
- Code exists for something not in docs
- New files, middleware, utilities, integrations

**Documentation gaps:**
- Features with thin docs (overview only, no flows)
- Rules without specific values
- Missing acceptance criteria

## STEP 4: PRESENT THE REPORT

Format your report clearly:

```
🦕 ARNOLD CHECK REPORT
━━━━━━━━━━━━━━━━━━━━━━

Scanned: [N] feature docs, [N] source files
Date: [today]

ALIGNMENT SUMMARY
━━━━━━━━━━━━━━━━━
  🟢 Aligned:    [N] rules / [N] features match
  🔴 Drifted:    [N] mismatches found
  🟡 Gaps:       [N] documentation gaps

🔴 DRIFT DETECTED
━━━━━━━━━━━━━━━━━

1. [Feature]: [Rule that drifted]
   📄 Docs say: [what docs say] (source: [file])
   💻 Code has: [what code does] (source: [file:line])
   → [Brief recommendation: "Update docs to match code" or "Fix code to match docs" or "Decide which is correct"]

2. [Feature]: [Another drift]
   📄 Docs say: ...
   💻 Code has: ...
   → ...

🟡 GAPS
━━━━━━━

Built but not documented:
  • [code file/path] — [what it does, where to document it]
  • [code file/path] — [what it does]

Documented but not built:
  • [feature]/ — [status: expected if planning, unexpected if "Implemented"]

Doc health:
  • [feature]/ — needs [flow docs / edge cases / acceptance criteria]
  • unknowns.md — [N] questions overdue

🟢 ALIGNED
━━━━━━━━━━

  ✓ [feature]: [N] rules match code
  ✓ [feature]: [N] rules match code
  ...

RECOMMENDED ACTIONS
━━━━━━━━━━━━━━━━━━━

  1. [Most important action — usually fixing a drift]
  2. [Second action]
  3. [Third action]

Run /update to sync docs after making changes. 🦕
```

## STEP 5: UPDATE STATUS

Update `docs/status.md` with findings:
- Change status markers for features based on check results
- Note when the last check was run
- Flag any features that changed status (e.g., 🟢 → 🔴)

## IMPORTANT NOTES

- **Don't fix anything automatically.** Report findings. The user decides what to fix.
- **Distinguish drift from gaps.** Drift = docs say X, code does Y. Gap = docs or code is missing entirely.
- **Be specific.** "Session timeout mismatch" is good. "Something seems off in auth" is useless.
- **Include file references.** Always cite both the doc file and the code file/line.
- **Prioritize drift over gaps.** Drift is actively wrong. Gaps are just incomplete.
- **If the codebase is too large,** tell the user and ask them to scope the check: "Want me to check a specific feature? (e.g., 'check auth')"
- **If there's no code yet,** say so and skip to doc health only. No code = no drift to check.
```

---

## 9. Slash Command: /update

Build this as `commands/update.md`.

```markdown
---
description: "Update — sync docs after a coding session"
---

You are Arnold, a documentation-first development assistant. The user has run `/update` to sync their documentation after making code changes.

## YOUR JOB

1. Figure out what changed in the code
2. Cross-reference against existing docs
3. Propose documentation updates
4. Apply on approval
5. Update status.md

## STEP 1: IDENTIFY CHANGES

Try these approaches in order:

**Option A: Git diff** (preferred if Git is available)
- Run or read `git diff --name-only` and `git diff --stat` to see changed files
- Read `git log --oneline -5` to see recent commits
- Focus on files that touch feature logic, not formatting/config changes

**Option B: Ask the user**
If Git isn't available or diff is too large, ask:
```
What did you work on in this coding session?
• Which features did you touch?
• Did you add anything new or change existing behavior?
```

## STEP 2: CROSS-REFERENCE WITH DOCS

For each changed area:
- Does a feature doc exist for this? → Might need updating
- Is this a new feature/module? → Might need a new doc
- Did behavior change? → Check if docs describe the old behavior
- Was a decision made? → Should it be recorded in decisions/?

## STEP 3: PROPOSE UPDATES

Present proposals clearly:

```
🦕 UPDATE — Doc Sync
━━━━━━━━━━━━━━━━━━━━

Based on your recent changes, here's what I'd update:

📝 UPDATE EXISTING:
  1. auth/overview.md — session timeout changed from 24hr to 72hr in code
     → Update Core Rules section to reflect 72hr timeout
  2. booking/overview.md — status should be 🟡 In Progress (code exists now)

📄 CREATE NEW:
  3. booking/reserve-spot.md — new booking flow is in code but not documented
  4. decisions/003-switched-to-redis.md — you replaced in-memory sessions with Redis

🔍 VERIFY:
  5. unknowns.md — "cancellation refund policy" — was this resolved?
     (I see refund logic in payments/refund.js)

Apply all? Or pick specific ones? (e.g., "just 1 and 3")
```

## STEP 4: APPLY ON APPROVAL

For each approved update:
- Edit existing docs in place (preserve structure, update content)
- Create new docs following Arnold's templates
- For decision records, auto-number (check existing files, increment)
- Move resolved unknowns to the relevant feature doc

## STEP 5: UPDATE STATUS

Update `docs/status.md` with:
- New/changed feature statuses
- "Last updated" date
- Any new items in "What's Next"

```
Updated [N] docs:
  ✓ auth/overview.md — session timeout now 72hr
  ✓ booking/overview.md — status: 🟡 In Progress
  + booking/reserve-spot.md (new)
  + decisions/003-switched-to-redis.md (new)

Updated docs/status.md

Docs are synced. Run /check anytime to verify alignment. 🦕
```
```

---

## 10. Slash Command: /status

Build this as `commands/status.md`.

```markdown
---
description: "Status — quick project overview"
---

You are Arnold, a documentation-first development assistant. The user has run `/status` for a quick project overview.

## YOUR JOB

Read `docs/overview.md` and `docs/status.md`. Present a concise summary of where the project stands.

## HOW TO DO IT

1. Read `docs/overview.md` for project context
2. Read `docs/status.md` for current state
3. Quickly scan `docs/*/overview.md` for feature statuses
4. Check `docs/unknowns.md` for overdue questions
5. Present a compact summary

## OUTPUT FORMAT

```
🦕 PROJECT STATUS
━━━━━━━━━━━━━━━━━

[Project Name]
[1-line description from overview.md]

FEATURES:
  🟢 [feature] — [brief status]
  🟡 [feature] — [what's in progress]
  🔵 [feature] — not started
  🔴 [feature] — drifted (if flagged by previous /check)

UNKNOWNS:
  [N] open questions ([N] overdue)
  Most urgent: "[question text]" — due [date]

DECISIONS:
  [N] recorded decisions

LAST CHECK:
  [Date of last /check, or "Never — run /check to compare docs and code"]

QUICK ACTIONS:
  • /plan — flesh out thin feature docs
  • /check — see if docs and code are aligned
  • /update — sync docs after coding
```

Keep it SHORT. This command is for orientation, not analysis. The user should be able to read this in 10 seconds and know where they stand.
```

---

## 11. Worked Example: Fitness Studio Booking

Build all of these files under `examples/fitness-studio-booking/`.

### examples/fitness-studio-booking/README.md

```markdown
# Example: Fitness Studio Booking Platform

This is a worked example showing Arnold's documentation structure
for a fitness studio booking platform.

Browse the `docs/` folder to see how features, flows, decisions,
and unknowns are organized. This is what Arnold generates when
you run `/init` and `/plan` on a real project.

No code is included — this example focuses on documentation only.
```

### examples/fitness-studio-booking/.claude/CLAUDE.md

Use the CLAUDE.md template from Section 5, with the project context filled in:

Add to the bottom:
```markdown
## Project Context

This is a fitness studio booking platform. Studio owners list classes,
users browse and book spots, payments are handled via Stripe, and
users can sync booked classes to their calendars.

Core features: Classes, Booking, Payments, Accounts, Calendar Sync

## Current Focus

Building the booking flow (reserve spot, cancellation, capacity management).
```

### examples/fitness-studio-booking/docs/overview.md

```markdown
# Fitness Studio Booking Platform

## What We're Building

A platform that lets fitness studio owners manage their class schedules and
lets users discover, book, and pay for fitness classes. Think ClassPass but
for independent studios.

## Who It's For

- **Studio owners:** Small fitness studios (yoga, CrossFit, pilates, cycling)
  who need a simple way to manage classes and bookings
- **Users:** People looking for fitness classes in their area

## Core Features

- **Classes:** Studio owners create and manage class schedules
- **Booking:** Users browse available classes and reserve spots
- **Payments:** Process bookings through Stripe
- **Accounts:** User profiles, saved payment methods, booking history
- **Calendar Sync:** Sync booked classes to Google/Apple calendars

## Why This Matters

Independent studios are stuck with expensive platforms (Mindbody at $159/mo)
or scattered tools (Google Sheets + Venmo). This gives them a modern booking
system at a fraction of the cost.

## Current Status

🟡 In Progress — core features documented, booking flow partially built

## Next Steps

- [ ] Complete booking flow (reserve + cancel)
- [ ] Integrate Stripe payments
- [ ] Build studio owner dashboard
- [ ] Run /check to verify docs match code
```

### examples/fitness-studio-booking/docs/status.md

```markdown
# Project Status

Last updated: 2026-03-14
Last /check: 2026-03-13

## Features

| Feature | Status | Notes |
|---------|--------|-------|
| Classes | 🟡 In Progress | CRUD for classes works, schedule view incomplete |
| Booking | 🟡 In Progress | Reserve works, cancellation not built |
| Payments | 🔵 Not Started | Stripe integration planned |
| Accounts | 🟢 Implemented | Login, signup, profile, password reset |
| Calendar Sync | 🔵 Not Started | Documented, deferred to v1.1 |

## Recent Changes

- 2026-03-13: Completed accounts feature (auth, profiles)
- 2026-03-12: Built class CRUD for studio owners
- 2026-03-10: Scaffolded project with /init

## What's Next

- [ ] Build cancellation flow for booking
- [ ] Integrate Stripe (decision: 001-chose-stripe.md)
- [ ] Resolve: refund vs. credit policy (unknowns.md)
```

### examples/fitness-studio-booking/docs/classes/overview.md

```markdown
# Classes

## What It Does

Studio owners can create, edit, and manage fitness classes. Each class has a
schedule, capacity, price, and description. Users browse these to find
classes to book.

## Why It Matters

Classes are the core unit of the platform. Without them, there's nothing to book.

## Core Rules

- Each class has: name, description, instructor, datetime, duration, capacity, price (user-stated)
- Capacity is enforced — no overbooking (decided, see decisions/002-no-overbooking.md)
- Classes can be recurring (weekly) or one-off (domain-derived)
- Only the studio owner who created a class can edit/delete it (Arnold-inferred)
- Deleting a class with active bookings triggers refunds for all booked users (domain-derived)

## What's Assumed

- Most classes are 45-60 minutes (domain-derived) — Risk: Low
- Studios offer 5-20 classes per week (assumed) — Risk: Low
- Class categories (yoga, cycling, etc.) are a fixed list for v1 (assumed) — Risk: Medium, studios may want custom categories

## Status

🟡 In Progress — CRUD works, schedule view incomplete

## Open Questions

- Should we support waitlists for full classes? (see unknowns.md)
```

### examples/fitness-studio-booking/docs/classes/create-class.md

```markdown
# Create Class

## Who

A studio owner setting up their class schedule.

## The Happy Path

1. Studio owner navigates to Dashboard → Classes → "New Class"
2. Fills in: name, description, instructor, date/time, duration, capacity, price
3. Optionally sets recurrence (weekly on specific days)
4. Clicks "Create Class"
5. System validates inputs and creates the class
6. Class appears on the public schedule immediately
7. Studio owner sees confirmation with a link to share

## What Could Go Wrong

### Overlapping schedule
- **When:** New class overlaps with another class at the same studio
- **What happens:** Warning shown: "This overlaps with [Class] at [Time]. Create anyway?"
- **Recovery:** Owner can adjust time or confirm overlap (some studios run parallel classes)

### Missing required fields
- **When:** Owner submits without filling name, datetime, or capacity
- **What happens:** Inline validation errors on required fields
- **Recovery:** Owner fills in missing fields and resubmits

### Capacity set to zero
- **When:** Owner accidentally sets capacity to 0
- **What happens:** Validation error: "Capacity must be at least 1"
- **Recovery:** Owner corrects the value

## Acceptance Criteria

- [ ] Studio owner can create a class with all required fields
- [ ] Validation prevents missing required fields
- [ ] Recurring classes generate future instances automatically
- [ ] New class appears on public schedule within seconds
- [ ] Only the studio owner can create classes for their studio
- [ ] Overlapping classes show a warning (not a block)

## Related

- See: booking/reserve-spot.md (depends on classes existing)
- See: booking/edge-cases.md (what happens when class is canceled after bookings)
```

### examples/fitness-studio-booking/docs/booking/overview.md

```markdown
# Booking

## What It Does

Users browse available classes and reserve spots. The system manages capacity,
prevents double-booking, and handles cancellations with the configured refund policy.

## Why It Matters

This is the core transaction. Users pay money to attend classes. Getting this
right is existential for the platform.

## Core Rules

- Users can reserve a spot if capacity is available (user-stated)
- Users cannot book the same class twice (domain-derived)
- Booking requires payment at time of reservation (user-stated)
- Maximum capacity is set per class and strictly enforced (decided — see decisions/002-no-overbooking.md)
- Cancellation > 24 hours out: full refund (user-stated)
- Cancellation < 24 hours out: credit for future class (user-stated)

## What's Assumed

- No waitlisting for v1 — if full, show "Class Full" (assumed) — Risk: Medium
- Bookings are non-transferable (Arnold-inferred) — Risk: Low
- No group bookings for v1 (assumed) — Risk: Low

## Status

🟡 In Progress — reserve flow works, cancellation not built

## Open Questions

- Should the refund policy be configurable per studio? (see unknowns.md)
```

### examples/fitness-studio-booking/docs/booking/reserve-spot.md

```markdown
# Reserve a Spot

## Who

A registered user who wants to attend a class.

## The Happy Path

1. User browses class schedule (filtered by date, type, studio)
2. Clicks on a class to see details (description, instructor, spots remaining)
3. Clicks "Reserve Spot" (only visible if spots remain)
4. Payment form appears (pre-filled if user has saved card)
5. User confirms payment
6. System processes payment via Stripe
7. Booking is created, spot count decremented
8. User sees confirmation page with class details
9. Confirmation email sent with calendar invite attachment

## What Could Go Wrong

### Class fills up during checkout
- **When:** Another user books the last spot while this user is on the payment page
- **What happens:** After payment, system checks capacity again. If full: payment is refunded, user sees "Sorry, this class just filled up."
- **Recovery:** User can browse other classes. Refund is automatic.

### Payment fails
- **When:** Card declined, insufficient funds, network error
- **What happens:** "Payment failed" message with reason. No booking created.
- **Recovery:** User can edit payment info and retry.

### User already booked this class
- **When:** User navigates back and tries to book again
- **What happens:** "Reserve Spot" button shows "Already Booked" (disabled)
- **Recovery:** User can cancel existing booking first if they want to rebook.

## Acceptance Criteria

- [ ] User can browse and filter available classes
- [ ] "Reserve Spot" only appears when spots are available
- [ ] Payment is processed before booking is confirmed
- [ ] Capacity is re-checked at payment time (race condition protection)
- [ ] Confirmation email is sent with calendar invite
- [ ] User cannot book the same class twice
- [ ] Payment failures show clear error messages
- [ ] Booking appears in user's dashboard

## Related

- Depends on: accounts (user must be logged in), classes (must exist), payments
- See: booking/cancellation.md for cancellation flow
- See: booking/edge-cases.md for unusual scenarios
```

### examples/fitness-studio-booking/docs/booking/cancellation.md

```markdown
# Cancellation

## Who

A user who has a booking and wants to cancel.

## The Happy Path

1. User goes to Dashboard → My Bookings
2. Clicks "Cancel" on a booking
3. System checks: is the class more than 24 hours away?
   - Yes → "You'll receive a full refund. Cancel?"
   - No → "This class is within 24 hours. You'll receive a credit for a future class. Cancel?"
4. User confirms cancellation
5. Booking is marked as canceled, spot is released
6. Refund or credit is issued
7. Confirmation email sent

## What Could Go Wrong

### User cancels after class already started
- **When:** User tries to cancel after the class start time
- **What happens:** "This class has already started. Cancellation is not available."
- **Recovery:** User can contact support for exceptions.

### Refund processing fails
- **When:** Stripe refund fails (rare)
- **What happens:** Booking is canceled, refund is queued for retry. User sees "Your refund is being processed."
- **Recovery:** System retries refund. If still failing after 3 attempts, flag for manual review.

## Acceptance Criteria

- [ ] User can cancel a booking from their dashboard
- [ ] Cancellation > 24hr out triggers full refund
- [ ] Cancellation < 24hr out triggers credit
- [ ] Canceled bookings release the spot (capacity increments)
- [ ] Confirmation email sent on cancellation
- [ ] Cannot cancel a class that has already started

## Related

- See: payments/overview.md for refund processing
- Policy decision: user-stated (refund > 24hr, credit < 24hr)
```

### examples/fitness-studio-booking/docs/booking/edge-cases.md

```markdown
# Booking — Edge Cases

## Studio cancels a class with active bookings

**Scenario:** Studio owner deletes a class that has 12 users booked.

**Why it matters:** 12 users expecting a class, paid money, may have adjusted their schedules.

**How we handle it:**
1. All bookings are marked "Canceled by studio"
2. Full refunds issued to all users (regardless of 24hr policy)
3. Each user receives email: "[Class] on [Date] was canceled by the studio. Full refund issued."
4. Studio owner sees confirmation: "12 bookings were refunded."

**Status:** 🔵 Not built

---

## User books, card expires before class

**Scenario:** User booked and paid on March 1. Card expires March 15. Class is March 20.

**Why it matters:** For single bookings, not an issue (already charged). For future subscription model, could be a problem.

**How we handle it:**
1. Single bookings: No action needed — payment already processed at booking time
2. Future (subscriptions): Email user 30 days before card expiry

**Status:** 🟢 Not applicable for v1 (single charge at booking)

---

## Concurrent booking race condition

**Scenario:** Two users try to book the last spot simultaneously.

**Why it matters:** Could result in overbooking if not handled.

**How we handle it:**
1. Capacity check happens inside a database transaction
2. First to complete the transaction gets the spot
3. Second user gets "Class just filled up" + automatic refund if payment was processed

**Status:** 🟡 Partially handled — needs DB transaction locking
```

### examples/fitness-studio-booking/docs/payments/overview.md

```markdown
# Payments

## What It Does

Users pay for class bookings. Studios receive revenue minus platform fee.
All payments are processed through Stripe.

## Why It Matters

Revenue and trust. Users expect secure, reliable payments. Studios need
timely payouts to keep running.

## Core Rules

- Stripe is the payment processor (decided — see decisions/001-chose-stripe.md)
- Users pay at booking time, not at class time (user-stated)
- Platform fee: 5% per transaction (assumed — TBD, see unknowns.md)
- Refunds follow the cancellation policy (full > 24hr, credit < 24hr)
- All payment amounts shown include fees (no surprise charges) (Arnold-inferred)

## What's Assumed

- Stripe handles PCI compliance (domain-derived) — Risk: None (Stripe's core purpose)
- Studios are paid out weekly (assumed) — Risk: Low, can adjust
- Single currency (USD) for v1 (assumed) — Risk: Medium if international studios join

## Status

🔵 Not Started

## Open Questions

- What's the platform fee percentage? (see unknowns.md)
- Do studios set their own prices freely? (see unknowns.md)
```

### examples/fitness-studio-booking/docs/payments/stripe-integration.md

```markdown
# Stripe Integration

## How It Works

We use Stripe Checkout for the payment flow and Stripe Connect for studio payouts.

## User Payment Flow

1. User clicks "Reserve Spot"
2. We create a Stripe Checkout Session with:
   - Line item: class name, price, quantity: 1
   - Metadata: user_id, class_id, booking_id
   - Success URL: /bookings/[id]/confirmed
   - Cancel URL: /classes/[id]
3. User completes payment on Stripe-hosted page
4. Stripe webhook fires `checkout.session.completed`
5. We confirm the booking in our database
6. Confirmation email sent

## Studio Payout Flow

1. Studios onboard via Stripe Connect (Standard accounts)
2. When a user books, payment goes to platform, minus Stripe fees
3. Weekly payout to studio's connected Stripe account, minus platform fee
4. Studio sees payout history in their dashboard

## Acceptance Criteria

- [ ] Stripe Checkout Session is created with correct metadata
- [ ] Webhook handler confirms bookings on success
- [ ] Failed payments do not create bookings
- [ ] Studios can connect their Stripe accounts
- [ ] Weekly payouts are calculated correctly (gross - Stripe fees - platform fee)

## Related

- See: decisions/001-chose-stripe.md
- See: booking/reserve-spot.md (triggers payment)
- See: booking/cancellation.md (triggers refund)
```

### examples/fitness-studio-booking/docs/accounts/overview.md

```markdown
# Accounts

## What It Does

Users and studio owners create accounts, log in, and manage their profiles.
The system supports email/password authentication with role-based access.

## Why It Matters

Everything depends on accounts: bookings, payments, preferences, history.

## Core Rules

- Two account types: user and studio_owner (user-stated)
- Email/password authentication (user-stated)
- Passwords: minimum 8 characters (Arnold-inferred — security best practice)
- Sessions expire after 24 hours of inactivity (domain-derived)
- Rate limiting: 5 failed login attempts per minute, 15 min lockout (Arnold-inferred)
- Password reset via email link, valid for 1 hour (domain-derived)

## What's Assumed

- No OAuth/social login for v1 (assumed) — Risk: Low, easy to add later
- No enterprise SSO (assumed) — Risk: Low, not our market
- Email verification required before booking (Arnold-inferred) — Risk: Low

## Status

🟢 Implemented — login, signup, profile, password reset all working

## Related

- See: booking/ (requires user to be logged in)
- See: payments/ (saved cards linked to account)
```

### examples/fitness-studio-booking/docs/calendar-sync/overview.md

```markdown
# Calendar Sync

## What It Does

After booking a class, users can sync it to their personal calendar
(Google Calendar, Apple Calendar, Outlook). One-click "Add to Calendar"
with automatic updates if the class is canceled or rescheduled.

## Why It Matters

Users forget about classes. Calendar sync reduces no-shows and improves
user experience. It's table stakes for booking platforms.

## Core Rules

- Booking confirmation includes an .ics calendar invite (domain-derived)
- If class is canceled, calendar event is updated/removed (domain-derived)
- Support Google Calendar and Apple Calendar at minimum (user-stated)

## What's Assumed

- .ics files are sufficient for v1 (no direct API integration) — Risk: Low
- Users download the .ics; we don't push to their calendar — Risk: Medium, push would be better UX

## Status

🔵 Not Started — deferred to v1.1

## Open Questions

- Do we push events to calendars via API, or just provide downloadable .ics? (see unknowns.md)
```

### examples/fitness-studio-booking/docs/decisions/001-chose-stripe.md

```markdown
# Decision: Use Stripe for Payments

**Date:** 2026-03-10
**Who Decided:** Chris, Garren
**Status:** Accepted

## The Situation

We need payment processing for class bookings. Users pay, studios receive
payouts, refunds need to be handled.

## What We Chose

**Stripe** — Stripe Checkout for user payments, Stripe Connect for studio payouts.

## What We Rejected

- **Square** — Better for physical POS. Less suited to online-only marketplace.
- **PayPal** — Higher fees, worse developer experience, less trust with younger users.
- **Direct bank integration** — Too much compliance overhead for a two-person team.

## Why Stripe

- Best-in-class API documentation and Claude Code support
- Handles PCI compliance entirely
- Stripe Connect solves the marketplace payout problem
- Transparent pricing (2.9% + 30¢ per transaction)
- Stripe Checkout provides a hosted payment page (less code for us)

## Consequences

- We're locked into Stripe's fee structure
- Refund handling follows Stripe's refund model (5-10 business days)
- If we need invoicing later, Stripe Billing is the natural path
- International expansion requires Stripe's supported countries
```

### examples/fitness-studio-booking/docs/decisions/002-no-overbooking.md

```markdown
# Decision: Strict Capacity Enforcement (No Overbooking)

**Date:** 2026-03-11
**Who Decided:** Chris
**Status:** Accepted

## The Situation

When a class reaches max capacity, do we allow overbooking (with a waitlist)
or strictly enforce the cap?

## What We Chose

**Strict enforcement.** When a class is full, it's full. No waitlisting in v1.

## What We Rejected

- **Overbooking with waitlist** — Better UX, but adds complexity: notification
  system, automatic promotion from waitlist, partial refunds if not promoted.
- **Soft cap with warning** — Confusing. Either it's full or it's not.

## Why Strict

- Simpler to build and reason about
- Studios know exactly how many people are coming
- No edge cases around waitlist promotion timing
- We can add waitlisting in v1.1 if demand exists

## Consequences

- Some users will be frustrated when classes are full
- Studios can't gauge demand beyond capacity (no waitlist signal)
- If 50 users want a 20-person class, we have no data on that unmet demand
```

### examples/fitness-studio-booking/docs/unknowns.md

```markdown
# Unknowns & Open Questions

## Open Questions

### What should the platform fee be?
- **Owner:** Chris
- **Why it matters:** Affects studio adoption and platform revenue. Too high and studios won't join. Too low and we can't sustain.
- **Current thinking:** 5% per transaction. Competitors charge 10-20% but we're targeting price-sensitive independent studios.
- **Decide by:** Before payments feature ships

---

### Should studios be able to set their own cancellation policies?
- **Owner:** Garren
- **Why it matters:** Current policy (full refund > 24hr, credit < 24hr) is platform-wide. Some studios may want stricter or more lenient policies.
- **Current thinking:** Platform-wide policy for v1. Per-studio policies in v2.
- **Decide by:** Before opening to multiple studios

---

### Do we need real-time class availability?
- **Owner:** Chris
- **Why it matters:** If two users see "1 spot left" at the same time, one will be disappointed. Real-time (WebSocket) is complex. Near-real-time (refresh on load) is simpler.
- **Current thinking:** Near-real-time for v1. Capacity is checked server-side at booking time regardless.
- **Decide by:** Before beta launch

---

### Should we support waitlists for full classes?
- **Owner:** TBD
- **Why it matters:** Without waitlists, full classes are dead ends for interested users. With waitlists, we capture demand signal and can auto-fill cancellations.
- **Current thinking:** No waitlist for v1 (decided — see decisions/002-no-overbooking.md). Revisit for v1.1.
- **Decide by:** After v1 launch based on user feedback

## Bets We're Making

### Most users will book on mobile
- **Risk if wrong:** Low — responsive design handles both, but we're prioritizing mobile-first layouts
- **How we'll know:** Analytics after launch

### Studios prefer simplicity over features
- **Risk if wrong:** High — if studios want Mindbody-level features, our simple approach won't cut it
- **How we'll know:** Studio owner feedback during beta

### One timezone per studio is enough for v1
- **Risk if wrong:** Medium — multi-location studios may span timezones
- **How we'll know:** Whether any beta studios have multiple locations
```

---

## 12. Output Formatting & Personality

These rules should be followed by all slash commands.

### Personality

Arnold has a Jurassic Park theme. Playful but professional. Smart colleague, not corporate tool.

- Use 🦕 exactly twice per command output: once at the start (header), once at the end (sign-off)
- Tagline: "Hold on to your docs."
- Never use more than 2 emoji per output (besides status markers)
- Tone: confident, helpful, slightly wry. Like a friend who's really into documentation.

### Status Markers (use consistently everywhere)

```
🟢 Implemented / Aligned / Done
🟡 In Progress / Partial / Warning
🔵 Not Started / Planned
🔴 Drifted / Broken / Blocked
❓ Unknown / Needs Decision
```

### Output Structure

Every command output follows:

```
🦕 [COMMAND NAME] — [Brief description]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[Content organized in clear sections]

[ACTION ITEMS or NEXT STEPS]

[Sign-off line] 🦕
```

### File Tree Display

When showing created/affected files, use annotated trees:

```
docs/
├── overview.md .................. Your project vision
├── status.md .................... Current state
├── auth/
│   └── overview.md .............. Login, sessions, permissions
├── booking/
│   └── overview.md .............. Reservations, cancellations
└── unknowns.md .................. 3 open questions
```

---

## 13. Edge Cases & Technical Details

### Brownfield Projects (Existing Codebase, No Docs)

When `/init` is run on a project with existing code but no `docs/` folder:

1. Scan the codebase structure
2. Infer features from the directory structure and file contents
3. Ask the user to confirm inferred features
4. Generate docs that reflect the existing code state (mark features as 🟡 or 🟢, not 🔵)
5. The initial `/check` will likely show "built but not documented" for many things — that's expected

### Existing docs/ Folder

If `docs/` already exists when `/init` runs:

1. Read existing docs
2. Ask: "You already have docs. Want me to reorganize them into Arnold's feature-based structure, or add Arnold alongside what you have?"
3. If reorganize: move existing files into feature folders, preserving content
4. If alongside: add Arnold's overview.md, status.md, and unknowns.md without touching existing files

### Auto-Numbering Decisions

Decision records are numbered sequentially: `001-title.md`, `002-title.md`, etc.

To auto-number:
1. Read `docs/decisions/` directory
2. Find the highest existing number
3. Increment by 1
4. Format with 3-digit zero-padding

### Large Codebases and Token Limits

For `/check` on large projects:
1. Start with config/constants files (high signal, low tokens)
2. Read models/schemas next
3. Read business logic for features that docs claim are "Implemented"
4. Skip test files, generated code, dependencies
5. If still too large, tell the user: "This is a big codebase. Want me to focus on a specific feature? (e.g., '/check auth')"

### Scoped Commands

All commands should support an optional scope argument:
- `/check auth` — only check the auth feature
- `/plan booking` — only plan the booking feature
- `/update payments` — only update payment docs

Implementation: if the user includes text after the command, treat it as a feature scope. Read only the relevant feature folder and corresponding code.

### Git Integration

`/update` should try to use git diff when available:
- `git diff --name-only` to find changed files
- `git log --oneline -5` to understand recent work
- If git is not available, ask the user what they changed

### Status Consistency

Status markers should be consistent across all docs:
- `docs/status.md` should match individual feature overview statuses
- `/check` updates status markers based on findings
- If a feature's overview says 🟢 but code doesn't exist, `/check` should flag this as drift

---

## BUILD INSTRUCTIONS

### For Claude Code:

1. Create the repo structure from the file manifest (Section 2)
2. Build each file using the exact content in this spec
3. For slash commands (Sections 6-10): the content between the outer triple-backticks is the file content
4. For the worked example (Section 11): create every file listed
5. Test by installing in a fresh project and running each command

### Suggested Build Order:

1. `README.md` + `LICENSE` (MIT boilerplate)
2. `install.sh` (get install working first)
3. `CLAUDE.md` (rules template)
4. `commands/init.md` (test scaffolding)
5. `commands/status.md` (simplest command)
6. `commands/plan.md` (test doc generation)
7. `commands/check.md` (most complex — spend time here)
8. `commands/update.md` (test doc syncing)
9. `examples/fitness-studio-booking/` (all doc files)
10. Final test: install → init → plan → check → update on a real project

### Quality Bar:

- Every command should produce useful output on first run
- `/check` should find real drift when docs and code disagree
- The worked example should be realistic enough that a developer says "oh, I get it"
- The README should sell the tool in 30 seconds
- Install should take under 2 minutes

---

*This spec was compiled from: the Arnold Lite PRD v0.2, the build gaps analysis, GSD competitive research, the old Arnold Engine README, Arnold Spec v0.1 (Notion), Arnold Experimentation notes (Notion), Arnold Product Strategy meetings (Feb 25 & March 2), and the March 14 team call transcript.*

*Internal name: Arnold Lite. Public name: Arnold.*

*Hold on to your docs.* 🦕
