# RadioQA — macOS client

A SwiftUI app for checking that the four stations recorded, and listening back.

## Build

The Xcode project is generated from `project.yml`, so it is not committed.

```bash
brew install xcodegen      # once
cd macos
xcodegen generate
open RadioQA.xcodeproj      # or: xcodebuild -scheme RadioQA build
```

## First run

Settings (gear icon) needs two values:

- **Server URL** — `https://radio-api.funasia.net`
- **API token** — the Worker's `API_TOKEN`

**Test connection** verifies both before saving. The token is stored in the
Keychain, not in `UserDefaults` or on disk.

## What it shows

**Coverage grid** — stations down, broadcast hours 06:00–24:00 across. Green is
a complete hour, red is nothing, amber in between. A number in a cell means that
hour arrived as several segments, which happens when the recorder restarts
mid-hour; the hour can still be complete. Click any cell to play it.

**Recordings list** — every segment for the day, marked `partial` when shorter
than an hour.

**Player** — play/pause, ±15s, and a scrubber. Seeking issues HTTP Range
requests, so jumping to 40 minutes in does not download the first 40 minutes.

## Notes

- Dates are broadcast days in `America/Chicago`, matching the recorder.
- Today never reads as complete until after midnight CT.
- Nothing older than three years exists; lifecycle rules delete it.
- Playback passes the token as a query parameter rather than a header, because
  `AVPlayer` cannot easily set headers. The API accepts both.
