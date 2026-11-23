# Photo Cleaner

A free, private photo cleaner for iPhone and iPad. It finds duplicates, old screenshots and
throwaway shots (receipts, whiteboards, parking spots), and lets you clear them out with
swipes and taps. Everything runs on the device with Apple's own frameworks: no account,
no data sent anywhere, no third-party dependencies.

## Requirements

- Xcode 16 or newer (the project uses Xcode 16 folder syncing)
- iOS / iPadOS 18 or newer
- A real iPhone or iPad is best for testing: some Vision requests are slow or unavailable
  in the Simulator, and the Simulator's photo library is tiny

## Build and run

1. Open `PhotoCleaner.xcodeproj`.
2. Select the **PhotoCleaner** target, then **Signing & Capabilities**: pick your Team and
   change the bundle identifier from `com.example.PhotoCleaner` to something of yours.
3. Choose your device and press Run (⌘R).
4. Unit tests: ⌘U (they cover the grouping, hashing and scoring logic, and run in the Simulator).

To try it in the Simulator, drag a few photos onto the Simulator window first, including a
duplicate or two and a screenshot (⌘S in the Simulator takes one).

## How it works

| Feature | How it's detected |
| --- | --- |
| Exact copies | 9x8 dHash of a small thumbnail; identical hashes with identical pixel dimensions are grouped across the whole library. Low-contrast (dark, plain) photos get no hash |
| Similar shots | Vision feature prints (revision pinned) compared only between photos taken close together (sessions split at 10-minute gaps), threshold 0.35. Each group has an anchor photo and others join only if they match it, so groups can't chain |
| Best photo in a group | Favorite first, then Vision aesthetics score, then resolution |
| Screenshots | PhotoKit screenshot subtype |
| One-offs | Vision aesthetics `isUtility`, document detection and on-device text recognition (receipt words), scored; favorites, photos in albums and photos under 3 days old are never suggested |

Analysis results are cached with SwiftData, keyed by photo id and modification date, so
later scans only look at new or edited photos. iCloud-only photos are not downloaded over
cellular unless you turn that on in Settings.

The one-tap "Mark extra copies" button only covers exact copies and never marks favorites
or photos you chose to keep. Similar shots are reviewed group by group.

### Deleting safely

- Marked photos collect in the **Marked** tray.
- **Move to "Cleaner: To Delete"** adds them to an album (optionally hiding them). Nothing is
  deleted and no system prompt appears.
- **To Delete** tab: restore photos (un-hiding the ones the app hid) or **Empty album**, which
  is the real delete. If the album is deleted in Photos, photos the app hid still show up here
  so they can be restored. iOS asks to confirm, and photos stay in Recently Deleted for 30 days.
- **Delete now** in the tray skips the album.

## Project layout

```
PhotoCleaner/
  App/        App entry, AppModel (scan + actions), Preferences, Marked tray
  Analysis/   dHash, Vision analysis, grouping, keeper pick, one-off scoring, results builder
  Diagnostics/ Loggers, signposts, scan stats, MetricKit reports
  Library/    PhotoKit reading, image loading, the cleanup album
  Models/     SwiftData cache and result types
  Views/      SwiftUI screens
PhotoCleanerTests/  Unit tests for the pure logic
```

## Troubleshooting

Everything below stays on the phone. There is no analytics SDK and nothing is uploaded.

### Diagnostics screen

Settings > Diagnostics shows live counts and timings for the current or last scan: photos
from cache vs. analyzed, how many came from iCloud, failed downloads, time per phase, average
image-load and Vision time per photo, and photos per second. **Copy scan report** puts the
same numbers on the clipboard as text. MetricKit reports (hangs, crashes, launch time,
energy) that iOS delivers are listed there too and can be shared as JSON.

### Logs (Console.app or Xcode)

The app logs with `os.Logger` under the subsystem set to its bundle id
(`com.example.PhotoCleaner` today), in these categories: `scan`, `analysis`, `library`,
`cache`, `results`, `actions`, `metrics`.

- **Xcode:** run on the phone; logs appear in the console pane. Filter with
  `subsystem:com.example.PhotoCleaner` or `category:scan`.
- **Console.app (no Xcode run needed):** plug in the phone, open Console on the Mac, select
  the phone in the sidebar, click **Start streaming**, and search
  `subsystem:com.example.PhotoCleaner`. Turn on Action > Include Info Messages and Include
  Debug Messages to see everything.
- **After the fact:** `notice`, `error` and `fault` lines are kept on the phone for a few days.
  With the phone plugged in, `sudo log collect --device --last 1h --output scan.logarchive`
  on the Mac, then open the archive in Console.
- Every scan ends with a one-line `Scan finished in …` summary at notice level, followed by
  a timings line at info level.
- Photo ids are hashed in logs (`<mask.hash: …>`), so lines about the same photo match without
  revealing which one. While the debugger is attached, Xcode shows them in full.

### Instruments

Scan phases are signposts: **Scan**, **Read library**, **Load cache**, **On-device pass**,
**iCloud pass**, **Rebuild lists** and **Prune cache** appear in the Points of Interest track
of any template (Product > Profile, then Time Profiler is a good start). Each photo also gets
**Load image** and **Vision** intervals in the `analysis` category; add the os_signpost
instrument to see them, which shows whether a slow scan is waiting on iCloud or on Vision.

### MetricKit

iOS delivers daily metric reports and crash/hang diagnostics to the app; they are logged in
the `metrics` category and saved under Application Support/Diagnostics. When running from
Xcode on a device, Debug > Simulate MetricKit Payloads delivers a sample right away. The
Simulator never sends real ones.

## Known limits of this first version

- Space numbers are estimates from pixel counts; PhotoKit has no public file-size API.
- The scan runs while the app is open; there's no background scanning yet.
- Not yet built from the design: Apple Pencil marking, synchronized zoom in compare mode,
  the iPad inspector panel, drag-to-select, blur detection and large videos.
- Thresholds (0.35 similarity, 10-minute sessions, one-off scoring) need tuning on a real library.
