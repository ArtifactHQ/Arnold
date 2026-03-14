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
