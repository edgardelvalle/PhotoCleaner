import Foundation
import Photos
import UIKit
import ImageIO

enum AssetAnalyzer {
    /// Bump to re-analyze every photo after changing what is computed.
    static let version = 1
    /// Thumbnail size used for analysis. Vision scales down internally anyway.
    static let analysisSide: CGFloat = 512

    static func analyze(_ meta: AssetMeta) async -> AssetAnalysisSnapshot? {
        if Task.isCancelled { return nil }
        var snapshot = AssetAnalysisSnapshot(id: meta.id, modificationDate: meta.modificationDate, analyzerVersion: version)

        // Screenshots are found from metadata alone and are not grouped as duplicates in v1.
        if meta.isScreenshot { return snapshot }

        guard let image = await ImageLoader.image(for: meta.asset, side: analysisSide),
              let cgImage = image.cgImage
        else { return nil } // e.g. iCloud photo while offline: retried on the next scan

        snapshot.dHash = DHash.compute(cgImage)
        let signals = VisionAnalyzer.analyze(cgImage, orientation: CGImagePropertyOrientation(image.imageOrientation))
        snapshot.featurePrint = signals.featurePrint
        snapshot.aestheticsScore = signals.aestheticsScore
        snapshot.isUtility = signals.isUtility
        snapshot.hasDocument = signals.hasDocument
        snapshot.textCharacterCount = signals.textCharacterCount
        snapshot.hasReceiptWords = signals.hasReceiptWords
        return snapshot
    }
}
