import Photos
import UIKit
import ImageIO

enum ImageLoader {
    /// Shared by every on-screen thumbnail, so images prefetched with `prefetch` are reused.
    static let thumbnails: PHCachingImageManager = {
        let manager = PHCachingImageManager()
        // Grid tiles only need the small, fast versions.
        manager.allowsCachingHighQualityImages = false
        return manager
    }()

    /// Loads one image of roughly `side` pixels for analysis. The handler fires once with
    /// `.highQualityFormat`. Cancelling the task cancels the PhotoKit request.
    static func image(
        for asset: PHAsset,
        side: CGFloat,
        manager: PHImageManager = PHImageManager.default(),
        allowNetwork: Bool = true
    ) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = allowNetwork
        let request = RequestBox(manager: manager)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                request.start(continuation) {
                    manager.requestImage(
                        for: asset,
                        targetSize: CGSize(width: side, height: side),
                        contentMode: .aspectFit,
                        options: options
                    ) { image, _ in
                        request.finish(image)
                    }
                }
            }
        } onCancel: {
            request.cancel()
        }
    }

    /// Options shared by on-screen thumbnails and the prefetcher; they must match for the
    /// prefetched images to be reused.
    static func displayOptions(allowNetwork: Bool) -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        // A small local version arrives right away, the sharp one follows.
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = allowNetwork
        return options
    }

    /// Streams images for display: a quick low-resolution one first (when PhotoKit has it),
    /// then the final one. Ending the stream (the view disappearing) cancels the request,
    /// so fast scrolling doesn't pile up downloads for tiles that are no longer visible.
    static func displayImages(
        for asset: PHAsset,
        pixelSide: CGFloat,
        contentMode: PHImageContentMode,
        allowNetwork: Bool = true
    ) -> AsyncStream<DisplayImage> {
        AsyncStream { continuation in
            let manager = thumbnails
            let id = manager.requestImage(
                for: asset,
                targetSize: CGSize(width: pixelSide, height: pixelSide),
                contentMode: contentMode,
                options: displayOptions(allowNetwork: allowNetwork)
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if let image { continuation.yield(DisplayImage(image: image, isDegraded: degraded)) }
                if !degraded { continuation.finish() }
            }
            continuation.onTermination = { _ in manager.cancelImageRequest(id) }
        }
    }

    /// Asks PhotoKit to prepare thumbnails for photos that are about to scroll into view.
    static func prefetch(_ assets: [PHAsset], pixelSide: CGFloat) {
        guard !assets.isEmpty else { return }
        thumbnails.startCachingImages(
            for: assets,
            targetSize: CGSize(width: pixelSide, height: pixelSide),
            contentMode: .aspectFill,
            options: displayOptions(allowNetwork: true)
        )
    }

    /// Lets PhotoKit drop prefetched thumbnails, for example when a grid closes.
    static func stopPrefetching() {
        thumbnails.stopCachingImagesForAllAssets()
    }

    /// Rounds a requested size up to a few fixed steps, so the same photo shown in slightly
    /// different places hits the same cached thumbnail.
    static func bucketed(_ pixels: CGFloat) -> CGFloat {
        for step: CGFloat in [128, 256, 384, 512, 768, 1024, 1536, 2048] where pixels <= step {
            return step
        }
        return pixels
    }
}

struct DisplayImage: @unchecked Sendable {
    let image: UIImage
    /// A quick low-resolution stand-in; the final image follows.
    let isDegraded: Bool
}

/// One analysis image request. Resumes its continuation exactly once: with the image, or
/// with nil when the task is cancelled (PhotoKit may not call back after a cancel).
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var id: PHImageRequestID?
    private var cancelled = false
    private let manager: PHImageManager

    init(manager: PHImageManager) {
        self.manager = manager
    }

    func start(_ continuation: CheckedContinuation<UIImage?, Never>, send: () -> PHImageRequestID) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        self.continuation = continuation
        lock.unlock()
        let id = send()
        lock.lock()
        self.id = id
        lock.unlock()
    }

    func finish(_ image: UIImage?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: image)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let continuation = self.continuation
        self.continuation = nil
        let id = self.id
        lock.unlock()
        continuation?.resume(returning: nil)
        if let id { manager.cancelImageRequest(id) }
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
