# Flyers

A Mac app and an iPhone app that read event flyers from Photos and put the events on your calendar.
`Sources/FlyersCore` holds everything both apps share, `Sources/Flyers` the Mac app (with a few views
the iPhone app also compiles), and `iOS/` the iPhone app and the Xcode project for both.

## Design rule: the two apps behave the same

The Mac and iPhone apps must do the same things the same way. Layout can differ to suit each
platform (a sidebar on the Mac, a tab bar on the iPhone), but behavior must match: what's listed,
what a tap or click does, what's asked before acting, what's kept and for how long, how the map
groups and shows things, which settings exist.

- When you change how something works in one app, make the same change in the other in the same
  piece of work, or say clearly what's left.
- Put shared logic in `FlyersCore` and shared views in `Sources/Flyers` files the iPhone target also
  compiles (`LocationMap.swift`, `Glass.swift`, `SyncStatus.swift`, `DeleteConfirmation.swift`), so
  the two can't drift.
- Differences that are only about the platform are fine: keyboard shortcuts and hover help on the
  Mac, swipe gestures and haptics on the iPhone.
