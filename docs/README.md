# Flyers landing page

A one-page static site: `index.html` (inline CSS, Google Fonts only) plus `images/`. No build step. GitHub Pages
can serve this folder from `main`.

**Preview locally:** run `cd docs && python3 -m http.server 8000` and visit http://localhost:8000.

**Screenshots** in `images/` come from the real app in demo mode (`open -n build/Flyers.app --args --demo`, or
`--demo-setup` for the setup screen), so no real photos or calendar events show. Capture the window alone with
`screencapture -o -l <window id>` to keep its rounded corners transparent, then resize to 1600 pixels wide.
