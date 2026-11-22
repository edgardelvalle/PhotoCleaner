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

    var extraIDs: [String] { memberIDs.filter { $0 != keeperID } }

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
