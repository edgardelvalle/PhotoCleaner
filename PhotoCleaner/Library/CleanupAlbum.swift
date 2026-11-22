import Foundation
import Photos

enum CleanupAlbumError: LocalizedError {
    case couldNotCreate

    var errorDescription: String? {
        "Couldn’t create the “\(CleanupAlbum.title)” album."
    }
}

/// Soft delete: photos are added to an album instead of being deleted, optionally hidden,
/// and only deleted for real when the album is emptied.
struct CleanupAlbum {
    static let title = "Cleaner: To Delete"

    private final class IDBox: @unchecked Sendable { var value: String? }

    static func find(knownID: String?) -> PHAssetCollection? {
        if let knownID,
           let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [knownID], options: nil).firstObject {
            return album
        }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", title)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options).firstObject
    }

    func fetchOrCreate(knownID: String?) async throws -> PHAssetCollection {
        if let album = Self.find(knownID: knownID) { return album }
        let box = IDBox()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: Self.title)
            box.value = request.placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let id = box.value,
              let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
        else { throw CleanupAlbumError.couldNotCreate }
        return album
    }

    /// Adds photos to the album. No system prompt; nothing is deleted.
    /// Returns the ids this call hid, so restore can un-hide exactly those.
    func add(_ assets: [PHAsset], to album: PHAssetCollection, hide: Bool) async throws -> Set<String> {
        let toHide = hide ? assets.filter { !$0.isHidden } : []
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: album)?.addAssets(assets as NSArray)
            for asset in toHide {
                PHAssetChangeRequest(for: asset).isHidden = true
            }
        }
        return Set(toHide.map(\.localIdentifier))
    }

    /// Takes photos out of the album (if it still exists) and un-hides the ones the app hid.
    func restore(_ assets: [PHAsset], from album: PHAssetCollection?, unhiding hiddenByApp: Set<String>) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            if let album {
                PHAssetCollectionChangeRequest(for: album)?.removeAssets(assets as NSArray)
            }
            for asset in assets where hiddenByApp.contains(asset.localIdentifier) {
                PHAssetChangeRequest(for: asset).isHidden = false
            }
        }
    }

    /// Real delete. iOS shows its own confirmation; photos go to Recently Deleted for 30 days.
    func delete(_ assets: [PHAsset]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
    }
}

final class LibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    var onChange: (() -> Void)?

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange?()
    }
}

extension Error {
    var isUserCancellation: Bool {
        if let error = self as? PHPhotosError, error.code == .userCancelled { return true }
        return false
    }
}
