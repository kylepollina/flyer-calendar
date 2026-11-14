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

Either device scans. Your phone usually gets to new photos first, when you open the app, and the Mac
skips anything the phone already handled. If you never open the phone app, the Mac still catches everything.

### Before starting

- [x] Check that team K9NSF24HZ7 is a paid Apple Developer Program membership. It is, so iCloud sync is available.

### Step 1: Xcode project

- [x] Make an Xcode project (`iOS/Flyers.xcodeproj`) with an iPhone app that uses `FlyersCore`.
- [ ] Add the Mac app to that project. iCloud needs a provisioning profile, which the `build-app.sh` build can't carry.
- [ ] Add a Share extension.
- [x] Replace the Mac-only parts for iPhone: images, the zoomable photo viewer, and opening links and maps.
- [ ] Edit an event on iPhone, an app icon, and the `flyers://` link from Calendar.
- [x] Keep the menu bar, start at login and the background scheduler Mac-only.
- [x] Get the iPhone app running on its own local data, to prove the shared code works on iOS. Scanning on the iPhone is off by default until sync exists, so it can't double up with the Mac.
- [ ] Install it on a real iPhone from Xcode and try it.

### Step 2: iCloud sync

- [ ] Sync flyers, events and settings as CloudKit records with `CKSyncEngine`, one record per event, so an edit on one device and a scan on the other don't overwrite each other.
- [ ] Key the handled-photos record (`document.photos`) by iCloud Photos' cloud ID (`PHPhotoLibrary.cloudIdentifierMappings`) and sync it. Photos' local IDs differ on each device.
- [ ] Before scanning a photo, write a claim ("phone is reading this") to the synced record. The other device skips claimed photos, and a claim older than about 10 minutes counts as abandoned.
- [ ] Rely on event fingerprints to drop duplicates if two devices read the same flyer anyway.
- [ ] Only the device that found an event adds it to Calendar. Save its shared Calendar ID (`calendarItemExternalIdentifier`) in the synced record, so the other device never adds it again and either device can apply edits.
- [ ] Upload saved photo copies to CloudKit, and only remove an original from Photos once its copy has finished uploading. Deleting from iCloud Photos removes it from every device.
- [ ] Sync the API key with iCloud Keychain (`kSecAttrSynchronizable`) so the phone and Share extension can use it.

### Step 3: Scanning on iPhone

- [x] Scan when you open the app, with the same 2-minute photo grouping as the Mac (behind the Settings switch for now).
- [ ] Ask iOS for occasional background time with `BGProcessingTask`. It usually comes overnight while charging.
- [ ] Share extension: share a screenshot to Flyers and get its events right away.

### Step 4: Polish

- [x] Pinch to zoom on iPhone, and maps.
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
