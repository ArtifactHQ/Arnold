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
