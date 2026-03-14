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
