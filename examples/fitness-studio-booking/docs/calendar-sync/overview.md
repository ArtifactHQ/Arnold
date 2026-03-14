# Calendar Sync

## What It Does

After booking a class, users can sync it to their personal calendar
(Google Calendar, Apple Calendar, Outlook). One-click "Add to Calendar"
with automatic updates if the class is canceled or rescheduled.

## Why It Matters

Users forget about classes. Calendar sync reduces no-shows and improves
user experience. It's table stakes for booking platforms.

## Core Rules

- Booking confirmation includes an .ics calendar invite (domain-derived)
- If class is canceled, calendar event is updated/removed (domain-derived)
- Support Google Calendar and Apple Calendar at minimum (user-stated)

## What's Assumed

- .ics files are sufficient for v1 (no direct API integration) — Risk: Low
- Users download the .ics; we don't push to their calendar — Risk: Medium, push would be better UX

## Status

🔵 Not Started — deferred to v1.1

## Open Questions

- Do we push events to calendars via API, or just provide downloadable .ics? (see unknowns.md)
