---
description: Create a spec-grounded implementation plan
argument-hint: <feature, issue, or ISSUE-NNN from the review>
agent: spec-planner
---

## Context

Current specification: !`head -100 specification.md`
Recent review issues: !`grep -E "^\\| ISSUE-" spec-to-code-review.md 2>/dev/null | head -30`

## Task

Create an implementation plan for:

$ARGUMENTS

The plan must trace every change to a spec item and flag any spec updates needed.
