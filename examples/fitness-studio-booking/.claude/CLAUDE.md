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
- 🔴 Drifted — docs and code don't match (flagged by /arnold:check)
- ❓ Unknown — depends on an unresolved question

### Source Provenance
Track where rules come from:
- **(user-stated)** — the human explicitly said this
- **(domain-derived)** — standard for this kind of application
- **(Arnold-inferred)** — Claude reasoned this should exist
- **(decided)** — deliberate team choice, links to decision record
- **(code-derived)** — extracted from reading the existing codebase

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

- `/arnold:init` — scaffold docs/ for a new project
- `/arnold:plan` — generate or refine feature specs
- `/arnold:check` — compare docs to code, find drift
- `/arnold:update` — sync docs after a coding session
- `/arnold:status` — quick project overview

## Project Context

This is a fitness studio booking platform. Studio owners list classes,
users browse and book spots, payments are handled via Stripe, and
users can sync booked classes to their calendars.

Core features: Classes, Booking, Payments, Accounts, Calendar Sync

## Current Focus

Building the booking flow (reserve spot, cancellation, capacity management).
