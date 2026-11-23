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

extension Array where Element == DuplicateGroup {
    /// The group to review after `id`: the next one in the list with nothing marked yet.
    /// Doesn't wrap around, so skipping through the list ends at the last group.
    /// If `id` is no longer in the list (it was rebuilt), starts from the top.
    func nextUndecided(after id: String, isMarked: (String) -> Bool) -> DuplicateGroup? {
        let start = firstIndex { $0.id == id }.map { index(after: $0) } ?? startIndex
        return self[start...].first { !$0.memberIDs.contains(where: isMarked) }
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
