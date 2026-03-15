# Project Status

Last updated: 2026-03-14
Last /arnold:check: 2026-03-13

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
- 2026-03-10: Scaffolded project with /arnold:init

## What's Next

- [ ] Build cancellation flow for booking
- [ ] Integrate Stripe (decision: decisions/001-chose-stripe.md)
- [ ] Resolve: refund vs. credit policy (unknowns.md)
