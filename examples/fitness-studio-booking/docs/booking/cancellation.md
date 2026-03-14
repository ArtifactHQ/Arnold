# Cancellation

## Who

A user who has a booking and wants to cancel.

## The Happy Path

1. User goes to Dashboard → My Bookings
2. Clicks "Cancel" on a booking
3. System checks: is the class more than 24 hours away?
   - Yes → "You'll receive a full refund. Cancel?"
   - No → "This class is within 24 hours. You'll receive a credit for a future class. Cancel?"
4. User confirms cancellation
5. Booking is marked as canceled, spot is released
6. Refund or credit is issued
7. Confirmation email sent

## What Could Go Wrong

### User cancels after class already started
- **When:** User tries to cancel after the class start time
- **What happens:** "This class has already started. Cancellation is not available."
- **Recovery:** User can contact support for exceptions.

### Refund processing fails
- **When:** Stripe refund fails (rare)
- **What happens:** Booking is canceled, refund is queued for retry. User sees "Your refund is being processed."
- **Recovery:** System retries refund. If still failing after 3 attempts, flag for manual review.

## Acceptance Criteria

- [ ] User can cancel a booking from their dashboard
- [ ] Cancellation > 24hr out triggers full refund
- [ ] Cancellation < 24hr out triggers credit
- [ ] Canceled bookings release the spot (capacity increments)
- [ ] Confirmation email sent on cancellation
- [ ] Cannot cancel a class that has already started

## Related

- See: payments/overview.md for refund processing
- Policy decision: user-stated (refund > 24hr, credit < 24hr)
