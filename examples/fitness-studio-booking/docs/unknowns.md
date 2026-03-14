# Unknowns & Open Questions

## Open Questions

### What should the platform fee be?
- **Owner:** Chris
- **Why it matters:** Affects studio adoption and platform revenue. Too high and studios won't join. Too low and we can't sustain.
- **Current thinking:** 5% per transaction. Competitors charge 10-20% but we're targeting price-sensitive independent studios.
- **Decide by:** Before payments feature ships

---

### Should studios be able to set their own cancellation policies?
- **Owner:** Garren
- **Why it matters:** Current policy (full refund > 24hr, credit < 24hr) is platform-wide. Some studios may want stricter or more lenient policies.
- **Current thinking:** Platform-wide policy for v1. Per-studio policies in v2.
- **Decide by:** Before opening to multiple studios

---

### Do we need real-time class availability?
- **Owner:** Chris
- **Why it matters:** If two users see "1 spot left" at the same time, one will be disappointed. Real-time (WebSocket) is complex. Near-real-time (refresh on load) is simpler.
- **Current thinking:** Near-real-time for v1. Capacity is checked server-side at booking time regardless.
- **Decide by:** Before beta launch

---

### Should we support waitlists for full classes?
- **Owner:** TBD
- **Why it matters:** Without waitlists, full classes are dead ends for interested users. With waitlists, we capture demand signal and can auto-fill cancellations.
- **Current thinking:** No waitlist for v1 (decided — see decisions/002-no-overbooking.md). Revisit for v1.1.
- **Decide by:** After v1 launch based on user feedback

## Bets We're Making

### Most users will book on mobile
- **Risk if wrong:** Low — responsive design handles both, but we're prioritizing mobile-first layouts
- **How we'll know:** Analytics after launch

### Studios prefer simplicity over features
- **Risk if wrong:** High — if studios want Mindbody-level features, our simple approach won't cut it
- **How we'll know:** Studio owner feedback during beta

### One timezone per studio is enough for v1
- **Risk if wrong:** Medium — multi-location studios may span timezones
- **How we'll know:** Whether any beta studios have multiple locations

---

### Should we push calendar events via API or provide downloadable .ics files?
- **Owner:** TBD
- **Why it matters:** Push integration (Google Calendar API) is better UX but adds complexity and OAuth requirements. Downloadable .ics is simpler but requires manual user action.
- **Current thinking:** .ics files for v1. API push for v1.1 if users request it.
- **Decide by:** Before calendar sync feature ships

---

### Do studios set their own prices freely?
- **Owner:** Chris
- **Why it matters:** If we restrict pricing (e.g., minimum price, approved tiers), it affects the studio onboarding flow and payment processing. Free pricing is simpler but could lead to $0 classes or pricing abuse.
- **Current thinking:** Studios set prices freely. Minimum price of $1 to avoid Stripe fee issues.
- **Decide by:** Before payments feature ships
