---
description: Show overall spec-to-code alignment status
agent: spec-analyst
---

## Current State
Spec document: !`wc -l specification.md` lines
Spec items: !`grep -cE "SPEC-[A-Z]+-[0-9]+" specification.md 2>/dev/null || echo "unknown"` items
Test count: !`bundle exec rake test 2>&1 | tail -1`
Last spec update: !`git log -1 --format="%ar" -- specification.md 2>/dev/null || echo "unknown"`
Last code update: !`git log -1 --format="%ar" -- lib/ app/ 2>/dev/null || echo "unknown"`

## Task

Produce a high-level alignment status report:

1. How many spec items exist vs how many features are implemented?
2. When was the spec last updated vs when was code last changed?
3. Are there any obvious gaps (features in code not in spec, or spec items not in code)?
4. What's the overall health: Aligned / Drifting / Stale?

Keep it concise — this is a dashboard check, not a full review.
