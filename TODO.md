# To do

Work through these in order.

## 1. Stable signing

- [ ] Add an Apple ID in Xcode and sign builds with `FLYERS_SIGN_IDENTITY`, so macOS stops asking for Photos, Calendar and Keychain access after every rebuild.

## 2. Check in real use

These haven't been confirmed in real use yet.

- [ ] Open in Flyers link, clicked from Calendar
- [ ] Flyer's web link in Calendar notes is clickable
- [ ] View photo loads the original from Photos
- [ ] Stop and Resume during a real scan
- [ ] Trackpad swipe to delete
- [ ] Delete key
- [ ] Link confirmation before opening a flyer's link
- [ ] Menu bar popover
- [ ] Start at login, staying in the menu bar
- [ ] Icon in the Dock and Finder

## 3. Fix

- [ ] Editing an event in Flyers rewrites all its Calendar fields, which overwrites notes and end times changed in Calendar.
- [ ] Calendar changes to an event's end time don't sync back to Flyers.

## 4. Test with more flyers

- [ ] Add schedule-style flyers and a "Sundays 4-6pm" flyer to `samples/`, then check them with `flyers-check`.

## 5. v2 features

- [ ] Drag and drop or Share, which also covers checking a few specific old photos
- [ ] Weekly digest notification
- [ ] Leave-by alerts
- [ ] Interests, to rank events by fit

## 6. v3 features

- [ ] Learn from deleted events
- [ ] Deadline reminders, such as "RSVP by" and "tickets on sale"
- [ ] Conflict warnings
- [ ] Flyer wall view
- [ ] Desktop widget and Siri
- [ ] Send an event to a friend

## Decisions

- Open-ended repeats go straight to the calendar, and unwanted ones get deleted by hand. Don't add a review step for them.
