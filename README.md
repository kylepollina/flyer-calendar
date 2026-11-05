# Flyers

A Mac menu bar app that finds event flyers in your new photos and puts the events on your calendar.

Photos are checked on your Mac first with Apple's Vision framework. Only photos that seem to mention an event are sent to the Anthropic API (Claude Haiku 5.5).

## Commands

Build the app into `build/Flyers.app`:

```bash
./scripts/build-app.sh
```

Run the tests:

```bash
swift test
```

Check the filter and extraction against a folder of photos. Put non-flyers in a folder named `not-flyers`. Without `--api`, nothing is sent:

```bash
swift run flyers-check samples
```

```bash
ANTHROPIC_API_KEY="..." swift run flyers-check samples --api
```

Open the app with sample data, without touching your photos or calendar:

```bash
open -n build/Flyers.app --args --demo
```

To see first-run setup instead, pass `--demo-setup`. Its buttons are real, so they ask for real permissions.

Redraw the icon by running `scripts/make-icon.swift`, then rebuild `Resources/AppIcon.icns` from its output with `iconutil`.

## Layout

- `Sources/FlyersCore`: all the logic, with no UI. Photos, the API and Calendar sit behind protocols, so `FlyersEngine` runs in tests with fakes.
- `Sources/Flyers`: the SwiftUI app.
- `Sources/flyers-check`: the command-line regression check.
- `extract.py`: the original Python prototype.

The library is one JSON file at `~/Library/Application Support/Flyers/library.json`. The API key is in your login Keychain.

## Signing

The script signs ad hoc by default. macOS ties permissions to the signature, so each rebuild can ask for Photos, Calendar and Keychain access again. To keep them, set `FLYERS_SIGN_IDENTITY` to a certificate name.
