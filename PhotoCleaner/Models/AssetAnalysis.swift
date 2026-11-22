import Foundation
import SwiftData

/// What the scanner learned about one photo. Plain value type so it can cross actors.
struct AssetAnalysisSnapshot: Sendable, Equatable {
    var id: String
    var modificationDate: Date?
    var analyzerVersion: Int
    var dHash: UInt64?
    /// Archived `VNFeaturePrintObservation`.
    var featurePrint: Data?
    var aestheticsScore: Double?
    var isUtility = false
    var hasDocument = false
    var textCharacterCount = 0
    var hasReceiptWords = false

    /// The same snapshot without the archived feature print. Prints live only in
    /// `ResultsBuilder` once decoded, so memory holds one copy.
    var withoutFeaturePrint: AssetAnalysisSnapshot {
        var copy = self
        copy.featurePrint = nil
        return copy
    }
}

/// On-disk cache of analysis results, keyed by asset id. A photo is analyzed again only
/// when its modification date or the analyzer version changes.
@Model
final class AssetAnalysis {
    @Attribute(.unique) var localIdentifier: String
    var modificationDate: Date?
    var analyzerVersion: Int
    var dHash: Int64?
    var featurePrint: Data?
    var aestheticsScore: Double?
    var isUtility: Bool
    var hasDocument: Bool
    var textCharacterCount: Int
    var hasReceiptWords: Bool

    init(_ snapshot: AssetAnalysisSnapshot) {
        localIdentifier = snapshot.id
        modificationDate = snapshot.modificationDate
        analyzerVersion = snapshot.analyzerVersion
        dHash = snapshot.dHash.map { Int64(bitPattern: $0) }
        featurePrint = snapshot.featurePrint
        aestheticsScore = snapshot.aestheticsScore
        isUtility = snapshot.isUtility
        hasDocument = snapshot.hasDocument
        textCharacterCount = snapshot.textCharacterCount
        hasReceiptWords = snapshot.hasReceiptWords
    }

    func update(from snapshot: AssetAnalysisSnapshot) {
        modificationDate = snapshot.modificationDate
        analyzerVersion = snapshot.analyzerVersion
        dHash = snapshot.dHash.map { Int64(bitPattern: $0) }
        featurePrint = snapshot.featurePrint
        aestheticsScore = snapshot.aestheticsScore
        isUtility = snapshot.isUtility
        hasDocument = snapshot.hasDocument
        textCharacterCount = snapshot.textCharacterCount
        hasReceiptWords = snapshot.hasReceiptWords
    }

    var snapshot: AssetAnalysisSnapshot {
        AssetAnalysisSnapshot(
            id: localIdentifier,
            modificationDate: modificationDate,
            analyzerVersion: analyzerVersion,
            dHash: dHash.map { UInt64(bitPattern: $0) },
            featurePrint: featurePrint,
            aestheticsScore: aestheticsScore,
            isUtility: isUtility,
            hasDocument: hasDocument,
            textCharacterCount: textCharacterCount,
            hasReceiptWords: hasReceiptWords
        )
    }
}

@ModelActor
actor AnalysisStore {
    func allSnapshots() throws -> [String: AssetAnalysisSnapshot] {
        let rows = try modelContext.fetch(FetchDescriptor<AssetAnalysis>())
        return Dictionary(rows.map { ($0.localIdentifier, $0.snapshot) }, uniquingKeysWith: { first, _ in first })
    }

    func save(_ snapshots: [AssetAnalysisSnapshot]) throws {
        guard !snapshots.isEmpty else { return }
        let ids = snapshots.map(\.id)
        let existing = try modelContext.fetch(
            FetchDescriptor<AssetAnalysis>(predicate: #Predicate { ids.contains($0.localIdentifier) })
        )
        var rowsByID = Dictionary(existing.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        for snapshot in snapshots {
            if let row = rowsByID[snapshot.id] {
                row.update(from: snapshot)
            } else {
                let row = AssetAnalysis(snapshot)
                modelContext.insert(row)
                rowsByID[snapshot.id] = row
            }
        }
        try modelContext.save()
    }

    /// Removes cached rows for photos that no longer exist.
    func prune(keeping ids: Set<String>) throws {
        let rows = try modelContext.fetch(FetchDescriptor<AssetAnalysis>())
        var changed = false
        for row in rows where !ids.contains(row.localIdentifier) {
            modelContext.delete(row)
            changed = true
        }
        if changed { try modelContext.save() }
    }

    func reset() throws {
        try modelContext.delete(model: AssetAnalysis.self)
        try modelContext.save()
    }
}
