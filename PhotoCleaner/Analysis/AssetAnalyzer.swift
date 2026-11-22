import Foundation
import Photos
import UIKit
import ImageIO

enum AssetAnalyzer {
    /// Bump to re-analyze every photo after changing what is computed.
    /// 2: feature print revision pinned, low-contrast photos get no dHash.
    static let version = 2
    /// Thumbnail size used for analysis. Vision scales down internally anyway.
    static let analysisSide: CGFloat = 512

    /// - Parameter allowCellular: whether an iCloud-only photo may be downloaded over a
    ///   cellular or other expensive connection. If not, the photo is skipped and retried later.
    static func analyze(_ meta: AssetMeta, allowCellular: Bool) async -> AssetAnalysisSnapshot? {
        if Task.isCancelled { return nil }
        var snapshot = AssetAnalysisSnapshot(id: meta.id, modificationDate: meta.modificationDate, analyzerVersion: version)

        // Screenshots are found from metadata alone and are not grouped as duplicates in v1.
        if meta.isScreenshot { return snapshot }

        let allowNetwork = allowCellular || !NetworkMonitor.shared.isExpensive
        guard let image = await ImageLoader.image(for: meta.asset, side: analysisSide, allowNetwork: allowNetwork),
              let cgImage = image.cgImage
        else { return nil } // e.g. iCloud photo while offline or on cellular: retried on the next scan

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
