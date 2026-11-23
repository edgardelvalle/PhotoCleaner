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

    /// A device-only image smaller than this is just PhotoKit's tiny preview of an iCloud
    /// photo; such photos wait for the download pass instead of being analyzed from it.
    static let minimumLocalSide = 256

    /// - Parameter allowNetwork: whether an iCloud-only photo may be downloaded. If not, or if
    ///   the download fails, it returns nil and the photo is tried again later.
    static func analyze(_ meta: AssetMeta, allowNetwork: Bool) async -> AssetAnalysisSnapshot? {
        if Task.isCancelled { return nil }
        var snapshot = AssetAnalysisSnapshot(id: meta.id, modificationDate: meta.modificationDate, analyzerVersion: version)

        // Screenshots are found from metadata alone and are not grouped as duplicates in v1.
        if meta.isScreenshot { return snapshot }

        guard let image = await ImageLoader.image(for: meta.asset, side: analysisSide, allowNetwork: allowNetwork),
              let cgImage = image.cgImage
        else { return nil } // e.g. iCloud photo while offline or on cellular: retried later

        if !allowNetwork, max(cgImage.width, cgImage.height) < minimumLocalSide,
           max(meta.pixelWidth, meta.pixelHeight) >= minimumLocalSide {
            return nil
        }

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
