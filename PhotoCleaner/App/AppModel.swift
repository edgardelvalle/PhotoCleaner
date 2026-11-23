import Foundation
import Photos
import Observation
import SwiftData
import UIKit
import os

enum AppSection: Hashable {
    case overview, duplicates, screenshots, oneOffs, cleanup
}

/// The app's single source of truth: library access, the scan, the results and the
/// soft-delete actions. Views read it from the environment.
@MainActor
@Observable
final class AppModel {
    /// Photos analyzed at once when everything is on the device (CPU and Neural Engine bound).
    static let localConcurrency = min(6, max(2, ProcessInfo.processInfo.activeProcessorCount))
    /// Photos analyzed at once when they first have to come from iCloud (network bound).
    static let downloadConcurrency = 6
    /// During a scan, the first results show after this long...
    static let firstRefreshDelay: TimeInterval = 2
    /// ...and the cleanup lists are rebuilt at most this often after that.
    static let refreshInterval: TimeInterval = 8
    /// The progress bar is updated at most this often.
    static let progressInterval: TimeInterval = 0.25

    var authorization: PHAuthorizationStatus
    var selectedSection: AppSection = .overview
    var scanState: ScanState = .idle
    var results = ScanResults()
    var cleanupAssets: [PHAsset] = []
    var showTray = false
    var isWorking = false
    var errorMessage: String?
    /// iCloud photos skipped in the last scan because of a cellular connection.
    var skippedForCellular = 0
    /// Rough time left in the current scan, once there is enough to estimate it.
    var scanTimeRemaining: TimeInterval?

    let preferences = Preferences()
    let tray = TrayStore()

    @ObservationIgnored private var assetsByID: [String: PHAsset] = [:]
    @ObservationIgnored private var metasByID: [String: AssetMeta] = [:]
    @ObservationIgnored private var analyses: [String: AssetAnalysisSnapshot] = [:]
    @ObservationIgnored private var analysesLoaded = false
    @ObservationIgnored private var library = LibrarySnapshot()
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var rescanWhenDone = false
    @ObservationIgnored private var changeDebounce: Task<Void, Never>?
    @ObservationIgnored private var isObserving = false
    /// Library changes before this time are the app's own and don't trigger a scan.
    @ObservationIgnored private var ignoreLibraryChangesUntil = Date.distantPast
    @ObservationIgnored private let builder = ResultsBuilder()
    @ObservationIgnored private let store: AnalysisStore?
    @ObservationIgnored private let album = CleanupAlbum()
    @ObservationIgnored private let observer = LibraryObserver()

    init() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        _ = NetworkMonitor.shared
        store = try? AnalysisStore(modelContainer: ModelContainer(for: AssetAnalysis.self))
        observer.onChange = { [weak self] in
            Task { @MainActor in self?.libraryDidChange() }
        }
        if hasAccess { activate() }
    }

    var hasAccess: Bool { authorization == .authorized || authorization == .limited }

    // MARK: Access

    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if hasAccess { activate() }
    }

    /// Called when the app comes back to the foreground; access may have changed in Settings.
    func refreshAuthorization() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status != authorization else { return }
        authorization = status
        if hasAccess { activate() }
    }

    private func activate() {
        if !isObserving {
            PHPhotoLibrary.shared().register(observer)
            isObserving = true
        }
        startScan()
    }

    private func libraryDidChange() {
        guard Date() >= ignoreLibraryChangesUntil else { return }
        changeDebounce?.cancel()
        changeDebounce = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            startScan()
        }
    }

    // MARK: Scanning

    var isScanning: Bool {
        switch scanState {
        case .preparing, .scanning: true
        case .idle, .finished: false
        }
    }

    /// Reads the library, shows cached results right away, then analyzes only new or
    /// changed photos, newest first.
    func startScan() {
        guard hasAccess else { return }
        if scanTask != nil {
            rescanWhenDone = true
            return
        }
        scanTask = Task {
            await runScan()
            scanTask = nil
            if rescanWhenDone {
                rescanWhenDone = false
                startScan()
            }
        }
    }

    func cancelScan() {
        rescanWhenDone = false
        scanTask?.cancel()
    }

    func resetAndRescan() async {
        cancelScan()
        try? await store?.reset()
        await builder.clearCache()
        analyses = [:]
        analysesLoaded = false
        results = ScanResults()
        scanState = .idle
        startScan()
    }

    private func runScan() async {
        if case .scanning = scanState {} else { scanState = .preparing }
        // A long first scan stops if the phone locks, so keep the screen on while it runs,
        // and ask for a little extra time when the app is switched away from.
        UIApplication.shared.isIdleTimerDisabled = true
        var backgroundTask = UIBackgroundTaskIdentifier.invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Photo scan") {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        let started = Date()
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            scanTimeRemaining = nil
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
        }
        let albumID = preferences.cleanupAlbumID
        let hiddenByApp = preferences.hiddenByApp

        // Read the library and load the analysis cache at the same time.
        let readLibrary = Task.detached(priority: .userInitiated) {
            LibraryReader.read(cleanupAlbumID: albumID, hiddenByApp: hiddenByApp)
        }
        if !analysesLoaded, let store {
            let cached = (try? await store.allSnapshots()) ?? [:]
            await builder.ingest(Array(cached.values))
            analyses = cached.mapValues(\.withoutFeaturePrint)
            analysesLoaded = true
        }
        let snapshot = await readLibrary.value
        apply(snapshot, checkedHiddenIDs: hiddenByApp)
        await refreshResults()

        let todo = snapshot.metas.filter { meta in
            guard let cached = analyses[meta.id] else { return true }
            return cached.modificationDate != meta.modificationDate || cached.analyzerVersion != AssetAnalyzer.version
        }
        let total = snapshot.metas.count
        progress = ScanProgress(done: total - todo.count, total: total)
        scanState = .scanning(done: progress.done, total: total)

        // Pass 1: photos already on the device, newest first. No downloads, so this is fast
        // and most results show up early. Photos that need iCloud are left for pass 2.
        let needDownload = await analyze(todo, allowNetwork: false, concurrency: Self.localConcurrency)

        // Pass 2: photos that have to be downloaded from iCloud first.
        let allowCellular = preferences.useCellularForICloud
        var skipped = 0
        if !Task.isCancelled, !needDownload.isEmpty {
            if allowCellular || !NetworkMonitor.shared.isExpensive {
                let failed = await analyze(needDownload, allowNetwork: true, concurrency: Self.downloadConcurrency)
                skipped = failed.count
            } else {
                skipped = needDownload.count
            }
        }
        await finishRefresh()

        skippedForCellular = (!allowCellular && NetworkMonitor.shared.isExpensive) ? skipped : 0
        let existing = Set(snapshot.metas.map(\.id)).union(snapshot.cleanupIDs)
        if !Task.isCancelled {
            try? await store?.prune(keeping: existing)
            analyses = analyses.filter { existing.contains($0.key) }
            await builder.retain(only: existing)
        }
        await refreshResults()
        scanState = Task.isCancelled ? .idle : .finished(Date())
        let seconds = Date().timeIntervalSince(started)
        Self.log.info("Scan: \(todo.count) to analyze, \(needDownload.count) needed iCloud, \(skipped) skipped, \(Int(seconds)) s")
    }

    private static let log = Logger(subsystem: "PhotoCleaner", category: "scan")

    private struct ScanProgress {
        var done = 0
        var total = 0
        var lastShown = Date.distantPast
    }

    @ObservationIgnored private var progress = ScanProgress()

    /// Results analyzed but not yet handed to the results builder.
    @ObservationIgnored private var unbuilt: [AssetAnalysisSnapshot] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastRefresh = Date()
    @ObservationIgnored private var refreshedDuringScan = false

    /// Analyzes `metas` a few at a time, saving to the cache in batches and refreshing the
    /// lists in the background now and then, so the scan never waits for a rebuild.
    /// - Returns: the photos that couldn't be analyzed (not on the device, or offline).
    private func analyze(
        _ metas: [AssetMeta],
        allowNetwork: Bool,
        concurrency: Int
    ) async -> [AssetMeta] {
        var failed: [AssetMeta] = []
        var pending: [AssetAnalysisSnapshot] = []
        let scanStart = Date()
        var analyzedThisPass = 0

        await withTaskGroup(of: (AssetMeta, AssetAnalysisSnapshot?).self) { group in
            var queue = metas.makeIterator()
            for _ in 0..<concurrency {
                guard let meta = queue.next() else { break }
                group.addTask { (meta, await AssetAnalyzer.analyze(meta, allowNetwork: allowNetwork)) }
            }
            while let next = await group.next() {
                let (meta, result) = next
                if let result {
                    progress.done += 1
                    analyzedThisPass += 1
                    analyses[result.id] = result.withoutFeaturePrint
                    unbuilt.append(result)
                    pending.append(result)
                } else if !Task.isCancelled {
                    failed.append(meta)
                }
                let now = Date()
                if now.timeIntervalSince(progress.lastShown) >= Self.progressInterval {
                    progress.lastShown = now
                    scanState = .scanning(done: progress.done, total: progress.total)
                    let elapsed = now.timeIntervalSince(scanStart)
                    if analyzedThisPass >= 30, elapsed > 5 {
                        let rate = Double(analyzedThisPass) / elapsed
                        scanTimeRemaining = Double(max(0, progress.total - progress.done)) / rate
                    }
                }
                if pending.count >= 200 {
                    let batch = pending
                    pending.removeAll()
                    try? await store?.save(batch)
                }
                let interval = refreshedDuringScan ? Self.refreshInterval : Self.firstRefreshDelay
                let since = refreshedDuringScan ? lastRefresh : scanStart
                if !unbuilt.isEmpty, refreshTask == nil, now.timeIntervalSince(since) >= interval {
                    startBackgroundRefresh()
                }
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                if let upcoming = queue.next() {
                    group.addTask { (upcoming, await AssetAnalyzer.analyze(upcoming, allowNetwork: allowNetwork)) }
                }
            }
        }
        try? await store?.save(pending)
        scanState = .scanning(done: progress.done, total: progress.total)
        return failed
    }

    /// Rebuilds the lists without holding up the scan loop.
    private func startBackgroundRefresh() {
        let batch = unbuilt
        unbuilt.removeAll()
        refreshTask = Task {
            await builder.ingest(batch)
            await refreshResults()
            lastRefresh = Date()
            refreshedDuringScan = true
            refreshTask = nil
        }
    }

    /// Waits for a background rebuild and hands over everything still unbuilt.
    private func finishRefresh() async {
        await refreshTask?.value
        refreshTask = nil
        refreshedDuringScan = false
        let batch = unbuilt
        unbuilt.removeAll()
        await builder.ingest(batch)
    }

    /// - Parameter checkedHiddenIDs: the hidden-by-app ids the snapshot was read with. Only
    ///   those can be forgotten, so ids added by an action during the read are kept.
    private func apply(_ snapshot: LibrarySnapshot, checkedHiddenIDs: Set<String>) {
        library = snapshot
        metasByID = Dictionary(snapshot.metas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var assets = metasByID.mapValues(\.asset)
        for asset in snapshot.cleanupAssets { assets[asset.localIdentifier] = asset }
        assetsByID = assets
        cleanupAssets = snapshot.cleanupAssets
        if let id = snapshot.cleanupAlbumID, id != preferences.cleanupAlbumID {
            preferences.cleanupAlbumID = id
        }
        preferences.prune(cleanupIDs: snapshot.cleanupIDs)
        // Forget hidden-by-app ids for photos that were deleted or un-hidden elsewhere.
        let stillHidden = Set(snapshot.cleanupAssets.filter(\.isHidden).map(\.localIdentifier))
        let gone = checkedHiddenIDs.subtracting(stillHidden)
        if !gone.isDisjoint(with: preferences.hiddenByApp) { preferences.hiddenByApp.subtract(gone) }
        tray.prune(keeping: Set(metasByID.keys).subtracting(snapshot.cleanupIDs))
    }

    /// Rebuilds the cleanup lists from what is already known, without analyzing anything.
    func refreshResults() async {
        let settings = ScanSettings(
            similarityThreshold: Float(preferences.similarityThreshold),
            keptIDs: preferences.keptIDs
        )
        results = await builder.build(library: library, analyses: analyses, settings: settings)
    }

    // MARK: Lookups

    func asset(_ id: String) -> PHAsset? { assetsByID[id] }
    func creationDate(_ id: String) -> Date? { metasByID[id]?.creationDate ?? assetsByID[id]?.creationDate }
    func bytes(_ ids: some Sequence<String>) -> Int64 {
        ids.reduce(0) { $0 + (assetsByID[$1]?.estimatedBytes ?? 0) }
    }

    var duplicateExtraCount: Int { results.duplicateGroups.reduce(0) { $0 + $1.memberIDs.count - 1 } }
    /// Extra copies the one-tap action may mark: exact copies only, never favorites or kept photos.
    var oneTapCopyIDs: [String] {
        results.duplicateGroups.filter { $0.kind == .exactCopies }.flatMap(\.markableExtraIDs)
    }
    var duplicateSavings: Int64 { results.duplicateGroups.reduce(0) { $0 + $1.estimatedSavings } }
    var screenshotSavings: Int64 { bytes(results.screenshotIDs) }
    var oneOffSavings: Int64 { bytes(results.oneOffs.map(\.id)) }
    var totalSavings: Int64 { duplicateSavings + screenshotSavings + oneOffSavings }
    var cleanupBytes: Int64 { cleanupAssets.reduce(0) { $0 + $1.estimatedBytes } }

    /// Number of photos that have waited in the cleanup album for more than 30 days.
    var staleCleanupCount: Int {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        return cleanupAssets.filter { (preferences.cleanupAddedDates[$0.localIdentifier] ?? .distantFuture) < cutoff }.count
    }

    // MARK: Marking

    /// Marks every photo in the group except the keeper, favorites and kept photos.
    func markExtras(of group: DuplicateGroup) {
        tray.add(group.markableExtraIDs.filter { !preferences.keptIDs.contains($0) })
    }

    /// One tap for exact copies only. Similar shots need a look, so they're not included.
    func markAllExactCopies() {
        tray.add(oneTapCopyIDs.filter { !preferences.keptIDs.contains($0) })
    }

    func keep(_ id: String) {
        tray.remove([id])
        preferences.keptIDs.insert(id)
    }

    func unkeep(_ id: String) {
        preferences.keptIDs.remove(id)
    }

    func forgetKeptPhotos() async {
        preferences.keptIDs = []
        await refreshResults()
    }

    // MARK: Soft delete and delete

    /// Moves everything in the tray to "Cleaner: To Delete". No system prompt.
    @discardableResult
    func moveTrayToCleanupAlbum() async -> Bool {
        let assets = tray.orderedIDs.compactMap { asset($0) }
        guard !assets.isEmpty else { return false }
        beginOwnChange()
        defer { endOwnChange() }
        do {
            let collection = try await album.fetchOrCreate(knownID: preferences.cleanupAlbumID)
            preferences.cleanupAlbumID = collection.localIdentifier
            let hidden = try await album.add(assets, to: collection, hide: preferences.hideSoftDeleted)
            preferences.hiddenByApp.formUnion(hidden)
            let now = Date()
            for asset in assets { preferences.cleanupAddedDates[asset.localIdentifier] = now }
            tray.clear()
            startScan()
            return true
        } catch {
            show(error)
            return false
        }
    }

    /// Deletes everything in the tray right away. iOS asks for confirmation.
    @discardableResult
    func deleteTrayNow() async -> Bool {
        let assets = tray.orderedIDs.compactMap { asset($0) }
        guard !assets.isEmpty else { return false }
        let freed = bytes(assets.map(\.localIdentifier))
        beginOwnChange()
        defer { endOwnChange() }
        do {
            try await album.delete(assets)
            preferences.lifetimeFreedBytes += freed
            tray.clear()
            startScan()
            return true
        } catch {
            show(error)
            return false
        }
    }

    /// Works even if the album was deleted: then it only un-hides the photos the app hid.
    func restore(_ assets: [PHAsset]) async {
        guard !assets.isEmpty else { return }
        let collection = CleanupAlbum.find(knownID: preferences.cleanupAlbumID)
        beginOwnChange()
        defer { endOwnChange() }
        do {
            try await album.restore(assets, from: collection, unhiding: preferences.hiddenByApp)
            let ids = assets.map(\.localIdentifier)
            preferences.hiddenByApp.subtract(ids)
            for id in ids { preferences.cleanupAddedDates[id] = nil }
            startScan()
        } catch {
            show(error)
        }
    }

    /// The real delete for soft-deleted photos. iOS asks for confirmation.
    func emptyCleanupAlbum() async {
        let assets = cleanupAssets
        guard !assets.isEmpty else { return }
        let freed = cleanupBytes
        beginOwnChange()
        defer { endOwnChange() }
        do {
            try await album.delete(assets)
            preferences.lifetimeFreedBytes += freed
            preferences.hiddenByApp.subtract(assets.map(\.localIdentifier))
            startScan()
        } catch {
            show(error)
        }
    }

    /// The app's own edits fire library-change notifications; the action itself rescans,
    /// so those notifications are ignored for a moment.
    private func beginOwnChange() {
        isWorking = true
        ignoreLibraryChangesUntil = .distantFuture
    }

    private func endOwnChange() {
        isWorking = false
        ignoreLibraryChangesUntil = Date().addingTimeInterval(3)
    }

    private func show(_ error: Error) {
        guard !error.isUserCancellation else { return }
        errorMessage = error.localizedDescription
    }
}
