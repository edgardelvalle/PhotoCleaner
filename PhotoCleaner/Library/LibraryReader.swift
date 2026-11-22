import Foundation
import Photos

/// The facts about one photo that the app needs, read once per scan.
/// `PHAsset` is immutable, so sharing it across threads is safe.
struct AssetMeta: @unchecked Sendable {
    let asset: PHAsset
    let id: String
    let creationDate: Date
    let modificationDate: Date?
    let isFavorite: Bool
    let isScreenshot: Bool
    let burstIdentifier: String?
    let pixelWidth: Int
    let pixelHeight: Int
    var pixelCount: Int { pixelWidth * pixelHeight }

    init(_ asset: PHAsset) {
        self.asset = asset
        id = asset.localIdentifier
        creationDate = asset.creationDate ?? .distantPast
        modificationDate = asset.modificationDate
        isFavorite = asset.isFavorite
        isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
        burstIdentifier = asset.burstIdentifier
        pixelWidth = asset.pixelWidth
        pixelHeight = asset.pixelHeight
    }
}

struct LibrarySnapshot: @unchecked Sendable {
    /// Visible (not hidden) photos, newest first.
    var metas: [AssetMeta] = []
    /// Photos that are in at least one album (user albums, shared albums...), except ours.
    var albumMemberIDs: Set<String> = []
    var cleanupAlbumID: String?
    /// Contents of "Cleaner: To Delete" (including hidden photos), plus any photo the app hid
    /// that is no longer in the album, so it can't get stranded in Hidden. Newest first.
    var cleanupAssets: [PHAsset] = []
    var cleanupIDs: Set<String> { Set(cleanupAssets.map(\.localIdentifier)) }
}

enum LibraryReader {
    /// Reads the library. Runs off the main thread; PhotoKit fetches are thread-safe.
    static func read(cleanupAlbumID: String?, hiddenByApp: Set<String>) -> LibrarySnapshot {
        var snapshot = LibrarySnapshot()

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let photos = PHAsset.fetchAssets(with: .image, options: options)
        var metas: [AssetMeta] = []
        metas.reserveCapacity(photos.count)
        photos.enumerateObjects { asset, _, _ in metas.append(AssetMeta(asset)) }
        snapshot.metas = metas

        let cleanupAlbum = CleanupAlbum.find(knownID: cleanupAlbumID)
        snapshot.cleanupAlbumID = cleanupAlbum?.localIdentifier
        if let cleanupAlbum {
            let albumOptions = PHFetchOptions()
            albumOptions.includeHiddenAssets = true
            albumOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            var cleanupAssets: [PHAsset] = []
            PHAsset.fetchAssets(in: cleanupAlbum, options: albumOptions).enumerateObjects { asset, _, _ in
                cleanupAssets.append(asset)
            }
            snapshot.cleanupAssets = cleanupAssets
        }

        // Photos the app hid but that are no longer in the album (for example because the
        // album was deleted in the Photos app) still show up in To Delete for restoring.
        let missing = hiddenByApp.subtracting(snapshot.cleanupAssets.map(\.localIdentifier))
        if !missing.isEmpty {
            let hiddenOptions = PHFetchOptions()
            hiddenOptions.includeHiddenAssets = true
            PHAsset.fetchAssets(withLocalIdentifiers: Array(missing), options: hiddenOptions).enumerateObjects { asset, _, _ in
                if asset.isHidden { snapshot.cleanupAssets.append(asset) }
            }
        }

        var members = Set<String>()
        let ourAlbumID = snapshot.cleanupAlbumID
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil).enumerateObjects { collection, _, _ in
            guard collection.localIdentifier != ourAlbumID else { return }
            PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
                members.insert(asset.localIdentifier)
            }
        }
        snapshot.albumMemberIDs = members
        return snapshot
    }
}

extension PHAsset {
    /// PhotoKit has no public file-size API, so space is estimated from pixel count.
    /// Typical HEIC/JPEG photos use roughly 0.3 bytes per pixel, PNG screenshots more.
    var estimatedBytes: Int64 {
        if mediaType == .video { return Int64(duration * 1_500_000) }
        let bytesPerPixel = mediaSubtypes.contains(.photoScreenshot) ? 0.45 : 0.3
        return Int64(Double(pixelWidth * pixelHeight) * bytesPerPixel)
    }
}
