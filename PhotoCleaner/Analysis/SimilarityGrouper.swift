import Foundation

struct GroupingItem: Sendable, Equatable {
    let id: String
    let date: Date
    let dHash: UInt64?
    let burstID: String?
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
}

struct RawGroup: Sendable, Equatable {
    /// Members in date order.
    var ids: [String]
    /// True when every member is a pixel-level copy of the first one.
    var isExactCopies: Bool
}

/// Finds groups of duplicate and near-duplicate photos without comparing every pair,
/// and without chaining (A looks like B, B looks like C, so A, B and C end up together).
///
/// 1. Exact copies anywhere in the library: identical, high-contrast dHash and identical
///    pixel dimensions. Equality can't chain, so these groups stay tight.
/// 2. Photos from the same burst.
/// 3. Everything else is split into "sessions" at long gaps between shots. Inside a session
///    each group has an anchor (its first photo), and a photo joins a group only if it is
///    alike with that anchor, by dHash or by Vision feature print.
/// Each photo belongs to at most one group.
struct SimilarityGrouper {
    /// A gap longer than this between two shots starts a new session.
    var sessionGap: TimeInterval = 10 * 60
    /// Vision feature print distance at or below which two photos count as "similar".
    var featureThreshold: Float = 0.35
    /// dHash bit distance at or below which two photos in one session count as alike.
    var hashThreshold: Int = 4
    /// dHash bit distance at or below which a session group still counts as exact copies.
    var copyThreshold: Int = 2
    /// A photo is only compared with groups anchored within this many photos before it.
    var neighborWindow: Int = 40

    private struct ExactKey: Hashable {
        let hash: UInt64
        let width: Int
        let height: Int
    }

    /// Returns groups of two or more photos, newest group first.
    func group(_ items: [GroupingItem], featureDistance: (String, String) -> Float?) -> [RawGroup] {
        guard items.count > 1 else { return [] }
        let sorted = items.sorted { $0.date < $1.date }
        var claimed = Set<Int>()
        var found: [(indices: [Int], exact: Bool)] = []

        // 1. Exact copies anywhere.
        var byKey: [ExactKey: [Int]] = [:]
        for (index, item) in sorted.enumerated() {
            guard let hash = item.dHash, DHash.isStrong(hash) else { continue }
            byKey[ExactKey(hash: hash, width: item.pixelWidth, height: item.pixelHeight), default: []].append(index)
        }
        for members in byKey.values where members.count > 1 {
            found.append((members, true))
            claimed.formUnion(members)
        }

        // 2. Bursts.
        var byBurst: [String: [Int]] = [:]
        for (index, item) in sorted.enumerated() where !claimed.contains(index) {
            if let burst = item.burstID { byBurst[burst, default: []].append(index) }
        }
        for members in byBurst.values where members.count > 1 {
            found.append((members, false))
            claimed.formUnion(members)
        }

        // 3. Sessions, clustered around anchors.
        var sessionStart = 0
        for end in 1...sorted.count {
            let isBoundary = end == sorted.count
                || sorted[end].date.timeIntervalSince(sorted[end - 1].date) > sessionGap
            guard isBoundary else { continue }
            let pool = (sessionStart..<end).filter { !claimed.contains($0) }
            for cluster in clusterSession(sorted, pool: pool, featureDistance: featureDistance) where cluster.count > 1 {
                let anchor = sorted[cluster[0]]
                let exact = cluster.dropFirst().allSatisfy { isCopy(anchor, sorted[$0], within: copyThreshold) }
                found.append((cluster, exact))
            }
            sessionStart = end
        }

        return found
            .map { (indices: $0.indices.sorted(), exact: $0.exact) }
            .sorted { sorted[$0.indices.last!].date > sorted[$1.indices.last!].date }
            .map { RawGroup(ids: $0.indices.map { sorted[$0].id }, isExactCopies: $0.exact) }
    }

    private func clusterSession(
        _ items: [GroupingItem],
        pool: [Int],
        featureDistance: (String, String) -> Float?
    ) -> [[Int]] {
        var clusters: [[Int]] = []
        var anchorPosition: [Int] = [] // position in `pool` of each cluster's anchor
        var active: [Int] = []          // clusters still close enough to join

        for (position, index) in pool.enumerated() {
            active.removeAll { position - anchorPosition[$0] > neighborWindow }
            let item = items[index]
            if let match = active.first(where: { areAlike(items[clusters[$0][0]], item, featureDistance: featureDistance) }) {
                clusters[match].append(index)
            } else {
                clusters.append([index])
                anchorPosition.append(position)
                active.append(clusters.count - 1)
            }
        }
        return clusters
    }

    private func areAlike(_ a: GroupingItem, _ b: GroupingItem, featureDistance: (String, String) -> Float?) -> Bool {
        if isCopy(a, b, within: hashThreshold) { return true }
        if let distance = featureDistance(a.id, b.id) {
            return distance <= featureThreshold
        }
        return false
    }

    private func isCopy(_ a: GroupingItem, _ b: GroupingItem, within bits: Int) -> Bool {
        guard let hashA = a.dHash, let hashB = b.dHash,
              DHash.isStrong(hashA), DHash.isStrong(hashB),
              Self.sameShape(a, b)
        else { return false }
        return DHash.distance(hashA, hashB) <= bits
    }

    /// Same aspect ratio within 1%. Unknown sizes (0) don't block a match.
    static func sameShape(_ a: GroupingItem, _ b: GroupingItem) -> Bool {
        guard a.pixelWidth > 0, a.pixelHeight > 0, b.pixelWidth > 0, b.pixelHeight > 0 else { return true }
        let ratioA = Double(a.pixelWidth) / Double(a.pixelHeight)
        let ratioB = Double(b.pixelWidth) / Double(b.pixelHeight)
        return abs(ratioA - ratioB) / ratioA < 0.01
    }
}
