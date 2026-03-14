# Stripe Integration

## How It Works

We use Stripe Checkout for the payment flow and Stripe Connect for studio payouts.

## User Payment Flow

1. User clicks "Reserve Spot"
2. We create a Stripe Checkout Session with:
   - Line item: class name, price, quantity: 1
   - Metadata: user_id, class_id, booking_id
   - Success URL: /bookings/[id]/confirmed
   - Cancel URL: /classes/[id]
3. User completes payment on Stripe-hosted page
4. Stripe webhook fires `checkout.session.completed`
5. We confirm the booking in our database
6. Confirmation email sent

## Studio Payout Flow

1. Studios onboard via Stripe Connect (Standard accounts)
2. When a user books, payment goes to platform, minus Stripe fees
3. Weekly payout to studio's connected Stripe account, minus platform fee
4. Studio sees payout history in their dashboard

## Acceptance Criteria

- [ ] Stripe Checkout Session is created with correct metadata
- [ ] Webhook handler confirms bookings on success
- [ ] Failed payments do not create bookings
- [ ] Studios can connect their Stripe accounts
- [ ] Weekly payouts are calculated correctly (gross - Stripe fees - platform fee)

## Related

- See: decisions/001-chose-stripe.md
- See: booking/reserve-spot.md (triggers payment)
- See: booking/cancellation.md (triggers refund)
