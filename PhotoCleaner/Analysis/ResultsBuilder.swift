import Foundation
import Vision

/// Turns the library snapshot plus cached analysis into the three cleanup lists.
/// Runs off the main actor.
///
/// It is the only owner of feature prints in memory: they are decoded once when ingested,
/// and the archived bytes are dropped everywhere else, so each print is held once.
actor ResultsBuilder {
    private var prints: [String: VNFeaturePrintObservation] = [:]

    /// Takes in new analysis results and decodes their feature prints.
    func ingest(_ snapshots: [AssetAnalysisSnapshot]) {
        for snapshot in snapshots {
            prints[snapshot.id] = snapshot.featurePrint.flatMap(VisionAnalyzer.decodeFeaturePrint)
        }
    }

    /// Forgets prints for photos that no longer exist.
    func retain(only ids: Set<String>) {
        prints = prints.filter { ids.contains($0.key) }
    }

    func clearCache() {
        prints.removeAll()
    }

    func build(
        library: LibrarySnapshot,
        analyses: [String: AssetAnalysisSnapshot],
        settings: ScanSettings,
        now: Date = Date()
    ) -> ScanResults {
        let excluded = library.cleanupIDs
        let visible = library.metas.filter { !excluded.contains($0.id) }
        let metasByID = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var results = ScanResults()

        results.screenshotIDs = visible
            .filter { $0.isScreenshot && !settings.keptIDs.contains($0.id) }
            .sorted { $0.creationDate < $1.creationDate }
            .map(\.id)

        // Duplicates
        let photos = visible.filter { !$0.isScreenshot }
        let items = photos.map {
            GroupingItem(
                id: $0.id,
                date: $0.creationDate,
                dHash: analyses[$0.id]?.dHash,
                burstID: $0.burstIdentifier,
                pixelWidth: $0.pixelWidth,
                pixelHeight: $0.pixelHeight
            )
        }
        var grouper = SimilarityGrouper()
        grouper.featureThreshold = settings.similarityThreshold
        let rawGroups = grouper.group(items) { a, b in
            guard let printA = self.prints[a], let printB = self.prints[b] else { return nil }
            return VisionAnalyzer.distance(printA, printB)
        }

        var groupedIDs = Set<String>()
        for raw in rawGroups {
            let ids = raw.ids
            let candidates = ids.compactMap { id -> KeeperCandidate? in
                guard let meta = metasByID[id] else { return nil }
                return KeeperCandidate(
                    id: id,
                    isFavorite: meta.isFavorite,
                    aestheticsScore: analyses[id]?.aestheticsScore,
                    pixelCount: meta.pixelCount,
                    date: meta.creationDate
                )
            }
            guard let keeper = KeeperPicker.pick(candidates) else { continue }
            groupedIDs.formUnion(ids)

            let savings = ids.filter { $0 != keeper.id }
                .reduce(Int64(0)) { $0 + (metasByID[$1]?.asset.estimatedBytes ?? 0) }
            let protected = Set(ids.filter { id in
                id != keeper.id && (metasByID[id]?.isFavorite == true || settings.keptIDs.contains(id))
            })

            results.duplicateGroups.append(DuplicateGroup(
                id: ids.joined(separator: "|"),
                memberIDs: ids,
                keeperID: keeper.id,
                keeperReason: keeper.reason,
                kind: raw.isExactCopies ? .exactCopies : .similarShots,
                date: metasByID[ids.last!]?.creationDate ?? .distantPast,
                estimatedSavings: savings,
                protectedIDs: protected
            ))
        }

        // One-off throwaway shots
        let calendar = Calendar.current
        for meta in photos where !groupedIDs.contains(meta.id) && !settings.keptIDs.contains(meta.id) {
            guard let analysis = analyses[meta.id] else { continue }
            let age = calendar.dateComponents([.day], from: meta.creationDate, to: now).day ?? 0
            let signals = OneOffSignals(
                isUtility: analysis.isUtility,
                hasDocument: analysis.hasDocument,
                textCharacterCount: analysis.textCharacterCount,
                hasReceiptWords: analysis.hasReceiptWords,
                aestheticsScore: analysis.aestheticsScore,
                ageInDays: age,
                isFavorite: meta.isFavorite,
                isInUserAlbum: library.albumMemberIDs.contains(meta.id),
                isInDuplicateGroup: false,
                isScreenshot: false
            )
            if let verdict = OneOffScorer.evaluate(signals) {
                results.oneOffs.append(OneOffCandidate(id: meta.id, reason: verdict.reason, score: verdict.score, date: meta.creationDate))
            }
        }
        results.oneOffs.sort { $0.date < $1.date }
        return results
    }
}
