# Reserve a Spot

## Who

A registered user who wants to attend a class.

## The Happy Path

1. User browses class schedule (filtered by date, type, studio)
2. Clicks on a class to see details (description, instructor, spots remaining)
3. Clicks "Reserve Spot" (only visible if spots remain)
4. Payment form appears (pre-filled if user has saved card)
5. User confirms payment
6. System processes payment via Stripe
7. Booking is created, spot count decremented
8. User sees confirmation page with class details
9. Confirmation email sent with calendar invite attachment

## What Could Go Wrong

### Class fills up during checkout
- **When:** Another user books the last spot while this user is on the payment page
- **What happens:** After payment, system checks capacity again. If full: payment is refunded, user sees "Sorry, this class just filled up."
- **Recovery:** User can browse other classes. Refund is automatic.

### Payment fails
- **When:** Card declined, insufficient funds, network error
- **What happens:** "Payment failed" message with reason. No booking created.
- **Recovery:** User can edit payment info and retry.

### User already booked this class
- **When:** User navigates back and tries to book again
- **What happens:** "Reserve Spot" button shows "Already Booked" (disabled)
- **Recovery:** User can cancel existing booking first if they want to rebook.

## Acceptance Criteria

- [ ] User can browse and filter available classes
- [ ] "Reserve Spot" only appears when spots are available
- [ ] Payment is processed before booking is confirmed
- [ ] Capacity is re-checked at payment time (race condition protection)
- [ ] Confirmation email is sent with calendar invite
- [ ] User cannot book the same class twice
- [ ] Payment failures show clear error messages
- [ ] Booking appears in user's dashboard

## Related

- Depends on: accounts (user must be logged in), classes (must exist), payments
- See: booking/cancellation.md for cancellation flow
- See: booking/edge-cases.md for unusual scenarios
