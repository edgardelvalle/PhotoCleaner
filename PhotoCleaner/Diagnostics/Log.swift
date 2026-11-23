import Foundation
import os

/// The app's loggers, one category per area, all under the app's bundle id as the subsystem.
///
/// Everything stays on the device: these go to the unified system log, which you read in
/// Xcode's console, in Console.app on a Mac with the phone plugged in, or in a sysdiagnose.
/// Numbers are logged as public; photo ids are hashed, so a line can be matched to another
/// without revealing which photo it was.
///
/// Levels: `debug` is only kept while streaming (Xcode or Console.app), `info` is kept in
/// memory for a short while, `notice` and above are saved to disk for a few days.
enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "PhotoCleaner"

    /// Scan lifecycle, phases and the end-of-scan summary.
    static let scan = Logger(subsystem: subsystem, category: "scan")
    /// Per-photo analysis: image loads, iCloud downloads, Vision.
    static let analysis = Logger(subsystem: subsystem, category: "analysis")
    /// Reading the photo library, authorization and library changes.
    static let library = Logger(subsystem: subsystem, category: "library")
    /// The SwiftData analysis cache.
    static let cache = Logger(subsystem: subsystem, category: "cache")
    /// Rebuilding the cleanup lists.
    static let results = Logger(subsystem: subsystem, category: "results")
    /// What the user did: moving to the cleanup album, deleting, restoring.
    static let actions = Logger(subsystem: subsystem, category: "actions")
    /// MetricKit reports (hangs, crashes, energy, launch time).
    static let metrics = Logger(subsystem: subsystem, category: "metrics")
}

/// Signposts show up as intervals in Instruments, so you can see where scan time goes.
enum Signposts {
    /// Scan phases and list rebuilds. Uses the Points of Interest category, so they appear
    /// in that track in every Instruments template without extra setup.
    static let phases = OSSignposter(subsystem: Log.subsystem, category: .pointsOfInterest)
    /// One interval per photo for image loading and Vision. Shown by the os_signpost
    /// instrument (add it to the trace) under the "analysis" category.
    static let photos = OSSignposter(logger: Log.analysis)
}

extension ContinuousClock.Instant {
    /// Seconds since this instant, for timing things into `ScanStats`.
    var secondsSince: TimeInterval {
        let elapsed = ContinuousClock.now - self
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}
