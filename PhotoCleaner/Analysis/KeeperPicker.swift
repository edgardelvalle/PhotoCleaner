import Foundation

struct KeeperCandidate: Sendable {
    let id: String
    let isFavorite: Bool
    /// Vision aesthetics overall score, from -1 (poor) to 1 (great).
    let aestheticsScore: Double?
    let pixelCount: Int
    let date: Date
}

enum KeeperReason: String, Sendable {
    case favorite = "Your favorite"
    case bestQuality = "Best quality"
    case largest = "Highest resolution"
    case newest = "Newest"
}

/// Picks which photo in a group to keep: a favorite first, then the best aesthetics score,
/// then the largest image, then the newest.
enum KeeperPicker {
    static func pick(_ candidates: [KeeperCandidate]) -> (id: String, reason: KeeperReason)? {
        guard let best = candidates.max(by: { key($0) < key($1) }) else { return nil }
        let others = candidates.filter { $0.id != best.id }
        let reason: KeeperReason
        if best.isFavorite && !others.allSatisfy(\.isFavorite) {
            reason = .favorite
        } else if let score = best.aestheticsScore, others.contains(where: { ($0.aestheticsScore ?? -2) < score }) {
            reason = .bestQuality
        } else if others.contains(where: { $0.pixelCount < best.pixelCount }) {
            reason = .largest
        } else {
            reason = .newest
        }
        return (best.id, reason)
    }

    private static func key(_ c: KeeperCandidate) -> (Int, Double, Int, Double) {
        (c.isFavorite ? 1 : 0, c.aestheticsScore ?? -2, c.pixelCount, c.date.timeIntervalSince1970)
    }
}
