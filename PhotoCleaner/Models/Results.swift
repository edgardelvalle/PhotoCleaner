import Foundation

struct DuplicateGroup: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case exactCopies, similarShots }

    let id: String
    /// Members in date order.
    let memberIDs: [String]
    let keeperID: String
    let keeperReason: KeeperReason
    let kind: Kind
    let date: Date
    /// Rough bytes freed by deleting everything except the keeper.
    let estimatedSavings: Int64
    /// Members that one-tap actions must never mark: favorites and photos the user kept.
    let protectedIDs: Set<String>

    var extraIDs: [String] { memberIDs.filter { $0 != keeperID } }
    /// Extras that "Keep best" may mark.
    var markableExtraIDs: [String] { extraIDs.filter { !protectedIDs.contains($0) } }

    var title: String {
        switch kind {
        case .exactCopies: "\(memberIDs.count) copies of the same photo"
        case .similarShots: "\(memberIDs.count) similar shots"
        }
    }
}

struct OneOffCandidate: Identifiable, Hashable, Sendable {
    let id: String
    let reason: String
    let score: Int
    let date: Date
}

struct ScanResults: Sendable {
    var duplicateGroups: [DuplicateGroup] = []
    /// Oldest first.
    var screenshotIDs: [String] = []
    /// Oldest first.
    var oneOffs: [OneOffCandidate] = []
}

extension ScanResults {
    /// Every extra photo across all duplicate groups, for "Delete all": each group keeps its
    /// best photo, and favorites and photos the user chose to keep are never included.
    /// A photo that is any group's keeper is never included, even if it also appears
    /// as an extra elsewhere.
    func deletableDuplicateExtraIDs(excluding keptIDs: Set<String>) -> [String] {
        let keepers = Set(duplicateGroups.map(\.keeperID))
        var seen = Set<String>()
        return duplicateGroups
            .flatMap(\.markableExtraIDs)
            .filter { !keptIDs.contains($0) && !keepers.contains($0) && seen.insert($0).inserted }
    }
}

struct ScanSettings: Sendable {
    var similarityThreshold: Float
    var keptIDs: Set<String>
}

enum ScanState: Equatable {
    case idle
    case preparing
    case scanning(done: Int, total: Int)
    case finished(Date)
}

extension Int64 {
    var bytesText: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
