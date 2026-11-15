# To do

Work through these in order.

## 1. Stable signing

- [x] Add an Apple ID in Xcode and sign builds with `FLYERS_SIGN_IDENTITY`, so macOS stops asking for Photos, Calendar and Keychain access after every rebuild.

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

## 5. iPhone app that syncs with the Mac

Goal: the iPhone app does everything the Mac app does, looks as polished, and stays in sync with it.
Either device scans. Your phone usually gets to new photos first, when you open the app, and the Mac
skips anything the phone already handled. If you never open the phone app, the Mac still catches everything.

### Done

- [x] Team K9NSF24HZ7 is a paid Apple Developer Program membership, so iCloud sync is available.
- [x] Xcode project (`iOS/Flyers.xcodeproj`) with an iPhone app that uses `FlyersCore`.
- [x] Lists, event page, map of every event, settings, pinch-to-zoom photo.
- [x] Scan when you open the app, behind a Settings switch until sync exists.

### Polish: match the Mac

- [x] Share the Mac's Liquid Glass styling (`Glass.swift`) with the iPhone app, falling back to materials before iOS 26.
- [x] Event page: the flyer's blurred colors behind it, a big poster header, glass cards and glass buttons.
- [x] List: glass tab switcher, floating glass notices for scan progress and Undo, swipe actions with haptics.
- [x] Map and photo viewer: glass controls.
- [x] First-run setup: a welcome screen with a card per step (API key, Photos, Calendar), like the Mac.
- [x] App icon.
- [ ] Check it on a real iPhone on iOS 26. The simulators here stop at iOS 18.5, which can't show Liquid Glass.

### Parity: everything the Mac does

- [x] Remove Photo from Photos on the event page.
- [x] Deleted section under Past, with Restore.
- [x] "Delete the photo too?" after deleting a photo's last event.
- [x] Photo viewer pages through every photo of a flyer.
- [x] Edit an event.
- [x] Settings: alert time, add mode (automatic or review), saved photos, clearing past events' photos.
- [ ] Open an event from the `flyers://` link in Calendar.
- [ ] Share extension, in place of the Mac's drag and drop.

### Sync

- [ ] Add the Mac app to the Xcode project. iCloud needs a provisioning profile, which the `build-app.sh` build can't carry.
- [ ] Sync flyers, events and settings as CloudKit records with `CKSyncEngine`, one record per event, so an edit on one device and a scan on the other don't overwrite each other.
- [ ] Key the handled-photos record (`document.photos`) by iCloud Photos' cloud ID (`PHPhotoLibrary.cloudIdentifierMappings`) and sync it. Photos' local IDs differ on each device.
- [ ] Before scanning a photo, write a claim ("phone is reading this") to the synced record. The other device skips claimed photos, and a claim older than about 10 minutes counts as abandoned.
- [ ] Rely on event fingerprints to drop duplicates if two devices read the same flyer anyway.
- [ ] Only the device that found an event adds it to Calendar. Its saved cross-device Calendar ID (`calendarExternalID`) lets the other device find it and apply edits.
- [ ] Upload saved photo copies to CloudKit, and only remove an original from Photos once its copy has finished uploading. Deleting from iCloud Photos removes it from every device.
- [ ] Sync the API key with iCloud Keychain (`kSecAttrSynchronizable`) so the phone and Share extension can use it.
- [ ] Turn scanning on the phone on by default once sync works.

### Later

- [ ] Ask iOS for occasional background time with `BGProcessingTask`. It usually comes overnight while charging.
- [ ] Widgets.

## 6. v2 features

- [x] Drag and drop, which also covers checking a few specific old photos
- [ ] Share (Share menu on Mac, Share extension on iPhone)
- [ ] Weekly digest notification
- [ ] Leave-by alerts
- [ ] Interests, to rank events by fit

## 7. v3 features

- [ ] Learn from deleted events
- [ ] Deadline reminders, such as "RSVP by" and "tickets on sale"
- [ ] Conflict warnings
- [ ] Flyer wall view
- [x] Map view of every event, past and upcoming, to see them all by place.
- [ ] Desktop widget and Siri
- [ ] Send an event to a friend

## Decisions

- Open-ended repeats go straight to the calendar, and unwanted ones get deleted by hand. Don't add a review step for them.
- Every event goes straight to the calendar, however many a flyer has. "Events from this photo" on an event's page lists them, with Delete All for a flyer that added too much.

## Known gaps

- [x] Several separate flyers photographed within two minutes were saved as one flyer. Only screenshots are read together now, and one answer can return several flyers, each with its own photos and events.
- [ ] The landing page in `docs/` still describes "Weekly schedules" you pick from, which no longer exists.
