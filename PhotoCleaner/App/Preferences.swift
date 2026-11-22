import Foundation
import Observation

/// Small settings and bookkeeping kept in UserDefaults.
@MainActor
@Observable
final class Preferences {
    private enum Key {
        static let hideSoftDeleted = "hideSoftDeleted"
        static let similarityThreshold = "similarityThreshold"
        static let keptIDs = "keptIDs"
        static let hiddenByApp = "hiddenByApp"
        static let cleanupAddedDates = "cleanupAddedDates"
        static let cleanupAlbumID = "cleanupAlbumID"
        static let lifetimeFreedBytes = "lifetimeFreedBytes"
    }

    static let defaultSimilarityThreshold = 0.35

    @ObservationIgnored private let defaults: UserDefaults

    /// Also hide photos when they're moved to the cleanup album.
    var hideSoftDeleted: Bool { didSet { defaults.set(hideSoftDeleted, forKey: Key.hideSoftDeleted) } }
    /// Vision feature print distance for "similar shots". Lower is stricter.
    var similarityThreshold: Double { didSet { defaults.set(similarityThreshold, forKey: Key.similarityThreshold) } }
    /// Photos the user swiped "keep" on, so they aren't suggested again.
    var keptIDs: Set<String> { didSet { defaults.set(Array(keptIDs), forKey: Key.keptIDs) } }
    /// Photos the app hid, so restore only un-hides those.
    var hiddenByApp: Set<String> { didSet { defaults.set(Array(hiddenByApp), forKey: Key.hiddenByApp) } }
    /// When each photo was moved to the cleanup album, for the "older than 30 days" nudge.
    var cleanupAddedDates: [String: Date] {
        didSet { defaults.set(cleanupAddedDates.mapValues(\.timeIntervalSince1970), forKey: Key.cleanupAddedDates) }
    }
    var cleanupAlbumID: String? { didSet { defaults.set(cleanupAlbumID, forKey: Key.cleanupAlbumID) } }
    var lifetimeFreedBytes: Int64 { didSet { defaults.set(lifetimeFreedBytes, forKey: Key.lifetimeFreedBytes) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hideSoftDeleted = defaults.bool(forKey: Key.hideSoftDeleted)
        let threshold = defaults.double(forKey: Key.similarityThreshold)
        similarityThreshold = threshold > 0 ? threshold : Self.defaultSimilarityThreshold
        keptIDs = Set(defaults.stringArray(forKey: Key.keptIDs) ?? [])
        hiddenByApp = Set(defaults.stringArray(forKey: Key.hiddenByApp) ?? [])
        let rawDates = defaults.dictionary(forKey: Key.cleanupAddedDates) as? [String: Double] ?? [:]
        cleanupAddedDates = rawDates.mapValues { Date(timeIntervalSince1970: $0) }
        cleanupAlbumID = defaults.string(forKey: Key.cleanupAlbumID)
        lifetimeFreedBytes = Int64(defaults.integer(forKey: Key.lifetimeFreedBytes))
    }

    /// Forgets bookkeeping for photos that are no longer in the cleanup album.
    func prune(cleanupIDs: Set<String>) {
        let dates = cleanupAddedDates.filter { cleanupIDs.contains($0.key) }
        if dates.count != cleanupAddedDates.count { cleanupAddedDates = dates }
    }
}

/// The "Marked" tray: photos picked for deletion that haven't been acted on yet.
@MainActor
@Observable
final class TrayStore {
    private static let key = "trayIDs"
    @ObservationIgnored private let defaults: UserDefaults

    private(set) var orderedIDs: [String]
    private(set) var markedIDs: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.stringArray(forKey: Self.key) ?? []
        orderedIDs = saved
        markedIDs = Set(saved)
    }

    var count: Int { orderedIDs.count }
    var isEmpty: Bool { orderedIDs.isEmpty }

    func contains(_ id: String) -> Bool { markedIDs.contains(id) }

    func toggle(_ id: String) {
        if contains(id) { remove([id]) } else { add([id]) }
    }

    func add(_ ids: [String]) {
        let new = ids.filter { !markedIDs.contains($0) }
        guard !new.isEmpty else { return }
        orderedIDs.append(contentsOf: new)
        markedIDs.formUnion(new)
        save()
    }

    func remove(_ ids: [String]) {
        let removing = Set(ids)
        guard !removing.isDisjoint(with: markedIDs) else { return }
        orderedIDs.removeAll { removing.contains($0) }
        markedIDs.subtract(removing)
        save()
    }

    func clear() {
        orderedIDs = []
        markedIDs = []
        save()
    }

    /// Drops ids whose photos no longer exist or are no longer visible.
    func prune(keeping valid: Set<String>) {
        let stale = orderedIDs.filter { !valid.contains($0) }
        if !stale.isEmpty { remove(stale) }
    }

    private func save() {
        defaults.set(orderedIDs, forKey: Self.key)
    }
}
