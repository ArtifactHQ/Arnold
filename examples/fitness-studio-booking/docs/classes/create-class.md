# Create Class

## Who

A studio owner setting up their class schedule.

## The Happy Path

1. Studio owner navigates to Dashboard → Classes → "New Class"
2. Fills in: name, description, instructor, date/time, duration, capacity, price
3. Optionally sets recurrence (weekly on specific days)
4. Clicks "Create Class"
5. System validates inputs and creates the class
6. Class appears on the public schedule immediately
7. Studio owner sees confirmation with a link to share

## What Could Go Wrong

### Overlapping schedule
- **When:** New class overlaps with another class at the same studio
- **What happens:** Warning shown: "This overlaps with [Class] at [Time]. Create anyway?"
- **Recovery:** Owner can adjust time or confirm overlap (some studios run parallel classes)

### Missing required fields
- **When:** Owner submits without filling name, datetime, or capacity
- **What happens:** Inline validation errors on required fields
- **Recovery:** Owner fills in missing fields and resubmits

### Capacity set to zero
- **When:** Owner accidentally sets capacity to 0
- **What happens:** Validation error: "Capacity must be at least 1"
- **Recovery:** Owner corrects the value

## Acceptance Criteria

- [ ] Studio owner can create a class with all required fields
- [ ] Validation prevents missing required fields
- [ ] Recurring classes generate future instances automatically
- [ ] New class appears on public schedule within seconds
- [ ] Only the studio owner can create classes for their studio
- [ ] Overlapping classes show a warning (not a block)

## Related

- See: booking/reserve-spot.md (depends on classes existing)
- See: booking/edge-cases.md (what happens when class is canceled after bookings)
