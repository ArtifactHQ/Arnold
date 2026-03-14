# Booking — Edge Cases

## Studio cancels a class with active bookings

**Scenario:** Studio owner deletes a class that has 12 users booked.

**Why it matters:** 12 users expecting a class, paid money, may have adjusted their schedules.

**How we handle it:**
1. All bookings are marked "Canceled by studio"
2. Full refunds issued to all users (regardless of 24hr policy)
3. Each user receives email: "[Class] on [Date] was canceled by the studio. Full refund issued."
4. Studio owner sees confirmation: "12 bookings were refunded."

**Status:** 🔵 Not built

---

## User books, card expires before class

**Scenario:** User booked and paid on March 1. Card expires March 15. Class is March 20.

**Why it matters:** For single bookings, not an issue (already charged). For future subscription model, could be a problem.

**How we handle it:**
1. Single bookings: No action needed — payment already processed at booking time
2. Future (subscriptions): Email user 30 days before card expiry

**Status:** 🔵 Not applicable for v1 — single charge at booking time eliminates this scenario

---

## Concurrent booking race condition

**Scenario:** Two users try to book the last spot simultaneously.

**Why it matters:** Could result in overbooking if not handled.

**How we handle it:**
1. Capacity check happens inside a database transaction
2. First to complete the transaction gets the spot
3. Second user gets "Class just filled up" + automatic refund if payment was processed

**Status:** 🟡 Partially handled — needs DB transaction locking
