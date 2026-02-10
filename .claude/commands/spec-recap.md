---
description: >
  Evaluate recent changes against specification.md. Combines session-recap
  (what changed?) with spec-analyst (does it align?). Use when returning
  to a session, after a teammate pushed commits, or before starting new
  work to verify the codebase hasn't drifted from spec.
argument-hint: "[optional: number of commits to check, default 5]"
---

## Step 1: Gather Context

Use the **session-recap** agent to analyze recent project activity.
Focus especially on:
- What files were modified in the last $1 commits (default: 5 if not specified)
- What behaviors changed (not just formatting or refactors)
- Any uncommitted work in progress

## Step 2: Spec Alignment Check

Then use the **spec-analyst** agent with the session-recap findings as input.
For each meaningful change identified in Step 1, check:
- Is this change covered by a SPEC item in specification.md?
- Does it contradict any SPEC item?
- Did the change include a spec update, or is spec drift accumulating?

## Step 3: Produce a Combined Report

Merge both outputs into a single report with this structure:

### 📋 Spec Recap

**🔄 What Changed** (from session-recap)
- [commit-level summary of behavioral changes]

**📐 Spec Alignment**
| Change | Spec Item | Status |
|--------|-----------|--------|
| [change] | SPEC-XXX-NNN | ✅ Aligned |
| [change] | SPEC-XXX-NNN | ⚠️ Changed but spec not updated |
| [change] | NONE | 🆕 New behavior, no spec item |
| [change] | SPEC-XXX-NNN | ❌ Contradicts spec |

**📊 Drift Score**
- Changes with spec coverage: N/M
- Spec updates included in commits: N/M
- Drift risk: Low / Medium / High

**➡️ Recommended Actions**
- [ ] Run `/spec-update` for: [list uncovered changes]
- [ ] Review contradiction: [specific item]
- [ ] Continue work — spec is in sync ✅

Keep the report concise. The developer wants to know "am I safe to keep
building, or do I need to sync the spec first?" in under 60 seconds.
