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

How it works is written at the top of `Sources/FlyersCore/Sync.swift`. The merge rules are tested with two
devices and a fake cloud in `SyncTests.swift`. `CloudSync.swift` carries the records through iCloud.

- [x] Sync records for flyers (with their photos), events, read photos and settings. The later change to a record wins.
- [x] Match photos across devices by iCloud Photos' cloud ID, and claim photos before reading them.
- [x] Only the device that found an event adds it to Calendar and reads Calendar's changes back. Other devices find it by its cross-device ID to edit or delete it.
- [x] Only remove an original from Photos once its flyer has reached iCloud.
- [x] `CloudSync`: carry the records through CloudKit with `CKSyncEngine`.
- [x] Register the iCloud container `iCloud.app.flyers.Flyers` and add the iCloud entitlement to both apps.
- [x] Switch `CloudSync` on in both apps, and show sync status and errors in Settings. Builds that list `FlyersCloudContainer` in Info.plist sync.
- [x] Create the schema in iCloud's Development environment (`Flyers --cloud-schema` from a Debug build sends demo data).
- [ ] Deploy the schema to Production in the CloudKit Console, then try a Mac and an iPhone together.
- [ ] Push notifications on the Mac. It fetches when it comes to the front and before each scan for now.
- [ ] Sync spending, summed across devices, so the monthly limit covers both.
- [x] Add the Mac app to the Xcode project (target `FlyersMac`). iCloud needs a provisioning profile, which the `build-app.sh` build can't carry, so that build doesn't sync.
- [x] Sync the API key with iCloud Keychain (`kSecAttrSynchronizable`). Keys saved before move there at launch.
- [ ] Turn scanning on the phone on by default once sync works.

### Later

- [ ] Ask iOS for occasional background time with `BGProcessingTask`. It usually comes overnight while charging.
- [ ] Widgets.

## 6. Publish: free app, $3.99 once for sync

Goal: anyone can download Flyers and use it with nothing to set up, and pay once to sync between
their Mac and iPhone.

### Reading flyers without an API key
Pasting an Anthropic key is too much to ask. Anthropic has no "sign in with Claude" for other apps
to bill against, so the options are Apple's models or a server of our own.

- [x] `AppleIntelligenceReader`: reads flyers with Apple's Foundation Models (macOS 27 / iOS 27),
      with images, filling in the same answer as the Claude reader. `flyers-check --apple` and
      `--apple-device` try it on the samples.
- [x] Tried the on-device model on `samples/flyers`: it finds event names but misses most dates, and
      a long schedule overflows it. Not good enough alone.
- [ ] Ask Apple for the Private Cloud Compute entitlement (`com.apple.developer.private-cloud-compute`).
      Xcode can't add it automatically, so it's a request on developer.apple.com. Apple's larger
      model runs there, free to us and the user, with a usage quota.
- [ ] Once granted: add it to both entitlements files, run `flyers-check samples --apple` from a
      signed build, and compare with Claude. If it's close, make it the default.
- [ ] Settings: a "Read flyers with" choice, Apple Intelligence or Claude (your key). Hide the key
      and spending unless Claude is chosen.
- [ ] Fallback if Apple's model isn't good enough: our own small server holding the Claude key,
      paid for by the purchase or a monthly scan allowance. Costs us per flyer, so price for it.

### Paying for sync
- [ ] StoreKit 2 non-consumable "Sync", $3.99, one purchase for both apps (same bundle ID, so
      Universal Purchase). Restore Purchases in Settings.
- [ ] Without it: everything works on one device. With it: `CloudSync` turns on.
- [ ] Create the product in App Store Connect (yours), and a StoreKit configuration file for testing.

### Setup and Settings, as a product designer would
- [x] iPhone Settings: a short list of categories with icons and values, each opening its own page.
      Show Setup is gone; "Finish Setting Up" appears at the top only while something's missing.
- [x] Mac Settings: the same categories, in the same order, with the same names.
- [ ] Setup in three steps: Calendar (choose or make one), Photos, then reading (Apple Intelligence
      with nothing to do, or Claude with a key, tucked under "Use your own Claude key").
- [ ] A Sync step at the end of setup that offers the purchase, skippable.
- [ ] Explain what happens to photos in one plain line during setup (they're read, then moved into
      Flyers), with the toggle right there.

### App Store Connect business setup (yours)
- [x] Paid Applications Agreement: accepted, bank account and W-9 added (Nov 20). Waiting for Apple
      to make it Active. Needed for the sync purchase and the Small Business Program.
- [ ] Developer account address: update requested (Nov 20), can take up to two weeks.
- [ ] App Store Small Business Program: enroll (15% commission instead of 30%). Also required for
      free Private Cloud Compute.
- [ ] EU Digital Services Act trader status: App Store Connect → Business → Complete Compliance
      Requirements. Selling the sync purchase in the EU makes you a trader, and Apple then shows
      your contact details (address, phone, email) on the EU App Store listing. A business
      address, phone and email that aren't your home ones avoid publishing those. Not declaring
      means Flyers can't be offered in the EU.

### Mac App Store
- [ ] App Sandbox for the Mac app (needed for the Mac App Store), with the data moved into the
      sandbox container on first launch.
- [ ] App Store listing, screenshots, privacy details (photos sent to Anthropic or Apple), and an
      update to `docs/`, which still mentions "Weekly schedules".

## 7. v2 features

- [x] Drag and drop, which also covers checking a few specific old photos
- [ ] Share (Share menu on Mac, Share extension on iPhone)
- [ ] Weekly digest notification
- [ ] Leave-by alerts
- [ ] Interests, to rank events by fit

## 8. v3 features

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
