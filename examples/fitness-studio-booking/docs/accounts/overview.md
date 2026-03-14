# Accounts

## What It Does

Users and studio owners create accounts, log in, and manage their profiles.
The system supports email/password authentication with role-based access.

## Why It Matters

Everything depends on accounts: bookings, payments, preferences, history.

## Core Rules

- Two account types: user and studio_owner (user-stated)
- Email/password authentication (user-stated)
- Passwords: minimum 8 characters (Arnold-inferred — security best practice)
- Sessions expire after 24 hours of inactivity (domain-derived)
- Rate limiting: 5 failed login attempts per minute, 15 min lockout (Arnold-inferred)
- Password reset via email link, valid for 1 hour (domain-derived)

## What's Assumed

- No OAuth/social login for v1 (assumed) — Risk: Low, easy to add later
- No enterprise SSO (assumed) — Risk: Low, not our market
- Email verification required before booking (Arnold-inferred) — Risk: Low

## Status

🟢 Implemented — login, signup, profile, password reset all working

## Related

- See: booking/ (requires user to be logged in)
- See: payments/ (saved cards linked to account)
