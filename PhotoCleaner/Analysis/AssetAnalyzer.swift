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
        let metrics = PhotoMetrics.shared
        var snapshot = AssetAnalysisSnapshot(id: meta.id, modificationDate: meta.modificationDate, analyzerVersion: version)

        // Screenshots are found from metadata alone and are not grouped as duplicates in v1.
        if meta.isScreenshot {
            metrics.record { $0.metadataOnly += 1 }
            return snapshot
        }

        let signpostID = Signposts.photos.makeSignpostID()
        let source = allowNetwork ? "iCloud" : "device"
        let loadInterval = Signposts.photos.beginInterval("Load image", id: signpostID, "\(source, privacy: .public)")
        let loadStart = ContinuousClock.now
        let image = await ImageLoader.image(for: meta.asset, side: analysisSide, allowNetwork: allowNetwork)
        let loadTime = loadStart.secondsSince
        Signposts.photos.endInterval("Load image", loadInterval)

        guard let image, let cgImage = image.cgImage else {
            // e.g. iCloud photo while offline or on cellular: retried later
            if Task.isCancelled {
                metrics.record { $0.cancelled += 1 }
            } else if allowNetwork {
                metrics.record { $0.downloadFailed += 1 }
                Log.analysis.notice("iCloud download failed for \(meta.id, privacy: .private(mask: .hash)) after \(loadTime, format: .fixed(precision: 1)) s")
            } else {
                metrics.record { $0.notOnDevice += 1 }
            }
            return nil
        }

        if !allowNetwork, max(cgImage.width, cgImage.height) < minimumLocalSide,
           max(meta.pixelWidth, meta.pixelHeight) >= minimumLocalSide {
            metrics.record { $0.tinyPreviews += 1 }
            return nil
        }
        metrics.record {
            if allowNetwork { $0.iCloudImageLoad.add(loadTime) } else { $0.localImageLoad.add(loadTime) }
        }
        if loadTime > 10 {
            Log.analysis.notice("Slow image load (\(source, privacy: .public)): \(loadTime, format: .fixed(precision: 1)) s for \(meta.id, privacy: .private(mask: .hash))")
        }

        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        // Vision blocks its thread for a while; run it on its own queue so the Swift
        // concurrency pool stays free for image loading, saving and rebuilding the lists.
        let (dHash, signals, visionTime) = await withCheckedContinuation { (continuation: CheckedContinuation<(UInt64?, VisionSignals, TimeInterval), Never>) in
            visionQueue.async {
                let interval = Signposts.photos.beginInterval("Vision", id: signpostID)
                let start = ContinuousClock.now
                let hash = DHash.compute(cgImage)
                let signals = VisionAnalyzer.analyze(cgImage, orientation: orientation)
                let seconds = start.secondsSince
                Signposts.photos.endInterval("Vision", interval)
                continuation.resume(returning: (hash, signals, seconds))
            }
        }
        metrics.record {
            $0.vision.add(visionTime)
            if allowNetwork { $0.analyzedDownloaded += 1 } else { $0.analyzedLocal += 1 }
        }
        if signals.featurePrint == nil {
            Log.analysis.notice("No feature print for \(meta.id, privacy: .private(mask: .hash)); it won't be matched as a similar shot")
        }
        Log.analysis.debug("Analyzed \(meta.id, privacy: .private(mask: .hash)) from \(source, privacy: .public): load \(Int(loadTime * 1000)) ms, vision \(Int(visionTime * 1000)) ms")
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
