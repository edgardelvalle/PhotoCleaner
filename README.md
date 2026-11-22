# Photo Cleaner

A free, private photo cleaner for iPhone and iPad. It finds duplicates, old screenshots and
throwaway shots (receipts, whiteboards, parking spots), and lets you clear them out with
swipes and taps. Everything runs on the device with Apple's own frameworks: no account,
no network code, no third-party dependencies.

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
| Exact copies | 9x8 dHash of a small thumbnail; identical hashes are grouped across the whole library |
| Similar shots | Vision feature prints compared only between photos taken close together (sessions split at 10-minute gaps), threshold 0.35, merged with union-find |
| Best photo in a group | Favorite first, then Vision aesthetics score, then resolution |
| Screenshots | PhotoKit screenshot subtype |
| One-offs | Vision aesthetics `isUtility`, document detection and on-device text recognition (receipt words), scored; favorites, photos in albums and photos under 3 days old are never suggested |

Analysis results are cached with SwiftData, keyed by photo id and modification date, so
later scans only look at new or edited photos.

### Deleting safely

- Marked photos collect in the **Marked** tray.
- **Move to "Cleaner: To Delete"** adds them to an album (optionally hiding them). Nothing is
  deleted and no system prompt appears.
- **To Delete** tab: restore photos (un-hiding the ones the app hid) or **Empty album**, which
  is the real delete. iOS asks to confirm, and photos stay in Recently Deleted for 30 days.
- **Delete now** in the tray skips the album.

## Project layout

```
PhotoCleaner/
  App/        App entry, AppModel (scan + actions), Preferences, Marked tray
  Analysis/   dHash, Vision analysis, grouping, keeper pick, one-off scoring, results builder
  Library/    PhotoKit reading, image loading, the cleanup album
  Models/     SwiftData cache and result types
  Views/      SwiftUI screens
PhotoCleanerTests/  Unit tests for the pure logic
```

## Known limits of this first version

- Space numbers are estimates from pixel counts; PhotoKit has no public file-size API.
- The scan runs while the app is open; there's no background scanning yet.
- Not yet built from the design: Apple Pencil marking, synchronized zoom in compare mode,
  the iPad inspector panel, drag-to-select, blur detection and large videos.
- Thresholds (0.35 similarity, 10-minute sessions, one-off scoring) need tuning on a real library.
