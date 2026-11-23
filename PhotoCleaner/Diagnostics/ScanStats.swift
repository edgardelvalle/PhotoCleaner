import Foundation
import os

/// Count, total and slowest of something that happens many times, like loading an image.
struct Timing: Sendable, Equatable {
    var count = 0
    var total: TimeInterval = 0
    var max: TimeInterval = 0

    var mean: TimeInterval? { count > 0 ? total / Double(count) : nil }

    mutating func add(_ seconds: TimeInterval) {
        count += 1
        total += seconds
        max = Swift.max(max, seconds)
    }
}

/// Per-photo counters, recorded from the analysis tasks off the main thread.
struct PhotoCounters: Sendable, Equatable {
    /// Analyzed from a copy already on the device.
    var analyzedLocal = 0
    /// Analyzed after downloading from iCloud.
    var analyzedDownloaded = 0
    /// Screenshots, which are recognized from metadata without loading the image.
    var metadataOnly = 0
    /// Not on the device in the on-device pass, so left for the iCloud pass.
    var notOnDevice = 0
    /// Only PhotoKit's tiny preview was on the device; also left for the iCloud pass.
    var tinyPreviews = 0
    /// The iCloud download failed (offline, iCloud error, or the photo is gone).
    var downloadFailed = 0
    /// Stopped because the scan was cancelled.
    var cancelled = 0

    var localImageLoad = Timing()
    var iCloudImageLoad = Timing()
    var vision = Timing()

    var analyzed: Int { analyzedLocal + analyzedDownloaded + metadataOnly }
}

/// Thread-safe collector for `PhotoCounters`. `AssetAnalyzer` records into it from many
/// tasks at once; the app model copies it into `ScanStats` a few times a second.
final class PhotoMetrics: Sendable {
    static let shared = PhotoMetrics()

    private let state = OSAllocatedUnfairLock(initialState: PhotoCounters())

    func record(_ update: (inout PhotoCounters) -> Void) {
        state.withLockUnchecked { update(&$0) }
    }

    var snapshot: PhotoCounters { state.withLockUnchecked { $0 } }

    func reset() {
        state.withLockUnchecked { $0 = PhotoCounters() }
    }
}

/// What happened in the current or last scan, shown on the Diagnostics screen and logged
/// as a summary when the scan ends. Nothing here leaves the device.
struct ScanStats: Sendable, Equatable {
    enum Outcome: String, Sendable { case notStarted = "Not started", running = "Running", finished = "Finished", cancelled = "Cancelled" }

    var outcome = Outcome.notStarted
    var startedAt: Date?
    var finishedAt: Date?

    /// Photos in the library.
    var libraryCount = 0
    /// Photos whose cached analysis was still valid, so they were not analyzed again.
    var cacheHits = 0
    /// Photos that needed analysis (new, edited, or analyzed by an older version).
    var toAnalyze = 0
    /// Photos the on-device pass couldn't do, handed to the iCloud pass.
    var neededICloud = 0
    /// Photos skipped because they need iCloud and the phone is on cellular.
    var skippedForCellular = 0
    /// Rows in the analysis cache when it was loaded (0 if it was already in memory).
    var cacheRowsLoaded = 0

    var readLibrary: TimeInterval = 0
    var loadCache: TimeInterval = 0
    var localPass: TimeInterval = 0
    var iCloudPass: TimeInterval = 0
    var prune: TimeInterval = 0
    /// Rebuilding the cleanup lists (grouping duplicates, scoring one-offs).
    var rebuilds = Timing()
    var cacheSaves = Timing()

    var photos = PhotoCounters()

    /// The most recent errors, newest last.
    var errors: [String] = []
    static let maxErrors = 20

    mutating func addError(_ message: String) {
        errors.append(message)
        if errors.count > Self.maxErrors { errors.removeFirst(errors.count - Self.maxErrors) }
    }

    /// Wall-clock time of the scan so far, or of the whole scan once it has ended.
    func elapsed(now: Date = Date()) -> TimeInterval? {
        guard let startedAt else { return nil }
        return (finishedAt ?? now).timeIntervalSince(startedAt)
    }

    /// Photos analyzed per second while the analysis passes were running.
    var photosPerSecond: Double? {
        let seconds = localPass + iCloudPass
        let analyzed = photos.analyzedLocal + photos.analyzedDownloaded
        guard seconds > 0.5, analyzed > 0 else { return nil }
        return Double(analyzed) / seconds
    }

    /// A plain-text report to paste into a bug report or a chat.
    func report(now: Date = Date()) -> String {
        func s(_ seconds: TimeInterval) -> String { String(format: "%.1f s", seconds) }
        func ms(_ timing: Timing) -> String {
            guard let mean = timing.mean else { return "–" }
            return String(format: "%d × avg %.0f ms, max %.0f ms", timing.count, mean * 1000, timing.max * 1000)
        }
        var lines: [String] = []
        lines.append("Photo Cleaner scan report")
        lines.append("Status: \(outcome.rawValue)")
        if let startedAt { lines.append("Started: \(startedAt.formatted(date: .abbreviated, time: .standard))") }
        if let elapsed = elapsed(now: now) { lines.append("Duration: \(s(elapsed))") }
        if let rate = photosPerSecond { lines.append(String(format: "Speed: %.1f photos/s", rate)) }
        lines.append("")
        lines.append("Library: \(libraryCount) photos, \(cacheHits) from cache, \(toAnalyze) to analyze")
        lines.append("Analyzed: \(photos.analyzedLocal) on device, \(photos.analyzedDownloaded) from iCloud, \(photos.metadataOnly) screenshots (metadata only)")
        lines.append("Needed iCloud: \(neededICloud) (not on device \(photos.notOnDevice), tiny preview only \(photos.tinyPreviews))")
        lines.append("Download failed: \(photos.downloadFailed), skipped on cellular: \(skippedForCellular), cancelled: \(photos.cancelled)")
        lines.append("")
        lines.append("Read library: \(s(readLibrary))")
        lines.append("Load cache: \(s(loadCache)) (\(cacheRowsLoaded) rows)")
        lines.append("On-device pass: \(s(localPass))")
        lines.append("iCloud pass: \(s(iCloudPass))")
        lines.append("Prune cache: \(s(prune))")
        lines.append("Image load (device): \(ms(photos.localImageLoad))")
        lines.append("Image load (iCloud): \(ms(photos.iCloudImageLoad))")
        lines.append("Vision: \(ms(photos.vision))")
        lines.append("List rebuilds: \(ms(rebuilds))")
        lines.append("Cache saves: \(ms(cacheSaves))")
        if !errors.isEmpty {
            lines.append("")
            lines.append("Errors:")
            lines.append(contentsOf: errors.map { "- \($0)" })
        }
        return lines.joined(separator: "\n")
    }
}
