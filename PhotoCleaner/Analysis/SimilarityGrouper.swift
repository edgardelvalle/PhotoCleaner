import Foundation

struct GroupingItem: Sendable, Equatable {
    let id: String
    let date: Date
    let dHash: UInt64?
    let burstID: String?
}

/// Finds groups of duplicate and near-duplicate photos without comparing every pair.
///
/// 1. Identical hashes anywhere in the library are linked (exact copies saved on different days).
/// 2. Photos from the same burst are linked.
/// 3. Photos are split into "sessions" wherever there is a long gap between shots, and only
///    photos close together inside a session are compared, by dHash and by Vision feature print.
/// Links are merged with union-find; every set of two or more photos is a group.
struct SimilarityGrouper {
    /// A gap longer than this between two shots starts a new session.
    var sessionGap: TimeInterval = 10 * 60
    /// Vision feature print distance at or below which two photos count as "similar".
    var featureThreshold: Float = 0.35
    /// dHash bit distance at or below which two photos count as copies.
    var hashThreshold: Int = 4
    /// Inside a session, each photo is compared with at most this many following photos.
    var neighborWindow: Int = 40

    /// Returns groups of ids (each in date order), newest group first.
    func group(_ items: [GroupingItem], featureDistance: (String, String) -> Float?) -> [[String]] {
        guard items.count > 1 else { return [] }
        let sorted = items.sorted { $0.date < $1.date }
        var sets = UnionFind(count: sorted.count)

        var firstIndexByHash: [UInt64: Int] = [:]
        var firstIndexByBurst: [String: Int] = [:]
        for (index, item) in sorted.enumerated() {
            if let hash = item.dHash, DHash.isInformative(hash) {
                if let other = firstIndexByHash[hash] { sets.union(index, other) } else { firstIndexByHash[hash] = index }
            }
            if let burst = item.burstID {
                if let other = firstIndexByBurst[burst] { sets.union(index, other) } else { firstIndexByBurst[burst] = index }
            }
        }

        var sessionStart = 0
        for end in 1...sorted.count {
            let isBoundary = end == sorted.count
                || sorted[end].date.timeIntervalSince(sorted[end - 1].date) > sessionGap
            guard isBoundary else { continue }
            linkSession(sorted, range: sessionStart..<end, sets: &sets, featureDistance: featureDistance)
            sessionStart = end
        }

        var membersByRoot: [Int: [Int]] = [:]
        for index in sorted.indices {
            membersByRoot[sets.find(index), default: []].append(index)
        }
        return membersByRoot.values
            .filter { $0.count > 1 }
            .sorted { sorted[$0.last!].date > sorted[$1.last!].date }
            .map { $0.map { sorted[$0].id } }
    }

    private func linkSession(
        _ items: [GroupingItem],
        range: Range<Int>,
        sets: inout UnionFind,
        featureDistance: (String, String) -> Float?
    ) {
        guard range.count > 1 else { return }
        for i in range {
            let upper = min(range.upperBound, i + 1 + neighborWindow)
            guard i + 1 < upper else { continue }
            for j in (i + 1)..<upper {
                if sets.find(i) == sets.find(j) { continue }
                if areAlike(items[i], items[j], featureDistance: featureDistance) {
                    sets.union(i, j)
                }
            }
        }
    }

    private func areAlike(_ a: GroupingItem, _ b: GroupingItem, featureDistance: (String, String) -> Float?) -> Bool {
        if let hashA = a.dHash, let hashB = b.dHash,
           DHash.isInformative(hashA), DHash.isInformative(hashB),
           DHash.distance(hashA, hashB) <= hashThreshold {
            return true
        }
        if let distance = featureDistance(a.id, b.id) {
            return distance <= featureThreshold
        }
        return false
    }
}
