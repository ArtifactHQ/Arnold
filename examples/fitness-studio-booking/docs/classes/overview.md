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
