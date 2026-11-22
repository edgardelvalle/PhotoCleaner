import Foundation
import Photos
import Observation
import SwiftData

enum AppSection: Hashable {
    case overview, duplicates, screenshots, oneOffs, cleanup
}

/// The app's single source of truth: library access, the scan, the results and the
/// soft-delete actions. Views read it from the environment.
@MainActor
@Observable
final class AppModel {
    static let scanConcurrency = 4

    var authorization: PHAuthorizationStatus
    var selectedSection: AppSection = .overview
    var scanState: ScanState = .idle
    var results = ScanResults()
    var cleanupAssets: [PHAsset] = []
    var showTray = false
    var isWorking = false
    var errorMessage: String?

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
    @ObservationIgnored private let builder = ResultsBuilder()
    @ObservationIgnored private let store: AnalysisStore?
    @ObservationIgnored private let album = CleanupAlbum()
    @ObservationIgnored private let observer = LibraryObserver()

    init() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
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
        results = ScanResults()
        scanState = .idle
        startScan()
    }

    private func runScan() async {
        if case .scanning = scanState {} else { scanState = .preparing }
        let albumID = preferences.cleanupAlbumID
        let snapshot = await Task.detached(priority: .userInitiated) {
            LibraryReader.read(cleanupAlbumID: albumID)
        }.value
        apply(snapshot)

        if !analysesLoaded, let store {
            analyses = (try? await store.allSnapshots()) ?? [:]
            analysesLoaded = true
        }
        await refreshResults()

        let todo = snapshot.metas.filter { meta in
            guard let cached = analyses[meta.id] else { return true }
            return cached.modificationDate != meta.modificationDate || cached.analyzerVersion != AssetAnalyzer.version
        }
        let total = snapshot.metas.count
        var done = total - todo.count
        var pending: [AssetAnalysisSnapshot] = []
        var sinceRefresh = 0
        scanState = .scanning(done: done, total: total)

        await withTaskGroup(of: AssetAnalysisSnapshot?.self) { group in
            var queue = todo.makeIterator()
            for _ in 0..<Self.scanConcurrency {
                guard let meta = queue.next() else { break }
                group.addTask { await AssetAnalyzer.analyze(meta) }
            }
            while let result = await group.next() {
                done += 1
                sinceRefresh += 1
                if let result {
                    analyses[result.id] = result
                    pending.append(result)
                }
                scanState = .scanning(done: done, total: total)
                if pending.count >= 100 {
                    try? await store?.save(pending)
                    pending.removeAll()
                }
                if sinceRefresh >= 300 {
                    sinceRefresh = 0
                    await refreshResults()
                }
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                if let meta = queue.next() {
                    group.addTask { await AssetAnalyzer.analyze(meta) }
                }
            }
        }

        try? await store?.save(pending)
        let existing = Set(snapshot.metas.map(\.id)).union(snapshot.cleanupIDs)
        if !Task.isCancelled {
            try? await store?.prune(keeping: existing)
            analyses = analyses.filter { existing.contains($0.key) }
        }
        await refreshResults()
        scanState = Task.isCancelled ? .idle : .finished(Date())
    }

    private func apply(_ snapshot: LibrarySnapshot) {
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

    func markExtras(of group: DuplicateGroup) {
        tray.add(group.extraIDs)
    }

    func markAllDuplicateExtras() {
        tray.add(results.duplicateGroups.flatMap(\.extraIDs))
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
        isWorking = true
        defer { isWorking = false }
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
        isWorking = true
        defer { isWorking = false }
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

    func restore(_ assets: [PHAsset]) async {
        guard !assets.isEmpty, let collection = CleanupAlbum.find(knownID: preferences.cleanupAlbumID) else { return }
        isWorking = true
        defer { isWorking = false }
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
        isWorking = true
        defer { isWorking = false }
        do {
            try await album.delete(assets)
            preferences.lifetimeFreedBytes += freed
            preferences.hiddenByApp.subtract(assets.map(\.localIdentifier))
            startScan()
        } catch {
            show(error)
        }
    }

    private func show(_ error: Error) {
        guard !error.isUserCancellation else { return }
        errorMessage = error.localizedDescription
    }
}
