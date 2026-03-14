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
