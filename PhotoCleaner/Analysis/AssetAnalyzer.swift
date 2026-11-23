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

    /// Concurrent; how many photos run at once is limited by the scan's task group.
    private static let visionQueue = DispatchQueue(label: "PhotoCleaner.vision", qos: .userInitiated, attributes: .concurrent)

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

        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        // Vision blocks its thread for a while; run it on its own queue so the Swift
        // concurrency pool stays free for image loading, saving and rebuilding the lists.
        let (dHash, signals) = await withCheckedContinuation { (continuation: CheckedContinuation<(UInt64?, VisionSignals), Never>) in
            visionQueue.async {
                continuation.resume(returning: (DHash.compute(cgImage), VisionAnalyzer.analyze(cgImage, orientation: orientation)))
            }
        }
        snapshot.dHash = dHash
        snapshot.featurePrint = signals.featurePrint
        snapshot.aestheticsScore = signals.aestheticsScore
        snapshot.isUtility = signals.isUtility
        snapshot.hasDocument = signals.hasDocument
        snapshot.textCharacterCount = signals.textCharacterCount
        snapshot.hasReceiptWords = signals.hasReceiptWords
        return snapshot
    }
}
