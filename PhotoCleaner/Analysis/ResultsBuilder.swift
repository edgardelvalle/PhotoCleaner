import Foundation
import Vision

/// Turns the library snapshot plus cached analysis into the three cleanup lists.
/// Runs off the main actor; keeps decoded feature prints between builds.
actor ResultsBuilder {
    private var decoded: [String: (data: Data, observation: VNFeaturePrintObservation)] = [:]

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
            GroupingItem(id: $0.id, date: $0.creationDate, dHash: analyses[$0.id]?.dHash, burstID: $0.burstIdentifier)
        }
        var grouper = SimilarityGrouper()
        grouper.featureThreshold = settings.similarityThreshold
        let rawGroups = grouper.group(items) { a, b in
            guard let printA = self.featurePrint(a, analyses), let printB = self.featurePrint(b, analyses) else { return nil }
            return VisionAnalyzer.distance(printA, printB)
        }

        var groupedIDs = Set<String>()
        for ids in rawGroups {
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

            let keeperHash = analyses[keeper.id]?.dHash
            let allCopies = ids.allSatisfy { id in
                guard let keeperHash, let hash = analyses[id]?.dHash else { return false }
                return DHash.distance(keeperHash, hash) <= 2
            }
            let savings = ids.filter { $0 != keeper.id }
                .reduce(Int64(0)) { $0 + (metasByID[$1]?.asset.estimatedBytes ?? 0) }

            results.duplicateGroups.append(DuplicateGroup(
                id: ids.joined(separator: "|"),
                memberIDs: ids,
                keeperID: keeper.id,
                keeperReason: keeper.reason,
                kind: allCopies ? .exactCopies : .similarShots,
                date: metasByID[ids.last!]?.creationDate ?? .distantPast,
                estimatedSavings: savings
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

    private func featurePrint(_ id: String, _ analyses: [String: AssetAnalysisSnapshot]) -> VNFeaturePrintObservation? {
        guard let data = analyses[id]?.featurePrint else { return nil }
        if let cached = decoded[id], cached.data == data { return cached.observation }
        guard let observation = VisionAnalyzer.decodeFeaturePrint(data) else { return nil }
        decoded[id] = (data, observation)
        return observation
    }

    func clearCache() {
        decoded.removeAll()
    }
}
