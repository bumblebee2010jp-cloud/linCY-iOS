import Photos
import CryptoKit
import Foundation

struct PhoneAlbum: Identifiable {
    let id: String
    let title: String
    let count: Int
    let collection: PHAssetCollection
}

enum PhotoLibrary {
    static func load() async throws -> [PhoneAlbum] {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw AppError.message("请到 iPhone 设置 → linCY → 照片，允许访问相册")
        }
        var albums: [PhoneAlbum] = []
        for type in [PHAssetCollectionType.album, .smartAlbum] {
            let collections = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
            collections.enumerateObjects { collection, _, _ in
                let count = PHAsset.fetchAssets(in: collection, options: options()).count
                if count > 0 {
                    albums.append(PhoneAlbum(id: collection.localIdentifier,
                        title: collection.localizedTitle ?? "未命名相册", count: count, collection: collection))
                }
            }
        }
        return albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func options() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return options
    }

    static func resources(_ asset: PHAsset) -> [PHAssetResource] {
        PHAssetResource.assetResources(for: asset).filter {
            [.photo, .video, .pairedVideo, .alternatePhoto].contains($0.type)
        }
    }

    static func shortID(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    static func safeName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|\u{0}").union(.controlCharacters)
        let clean = value.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        // Leave room for collision suffixes and the extension within server limits.
        var result = ""
        for character in clean {
            if (result + String(character)).utf8.count > 160 { break }
            result.append(character)
        }
        if result.isEmpty { result = "未命名" }
        let stem = result.split(separator: ".").first.map(String.init)?.uppercased() ?? ""
        let reserved = ["CON", "PRN", "AUX", "NUL"].contains(stem) ||
            (stem.count == 4 && (stem.hasPrefix("COM") || stem.hasPrefix("LPT")) && stem.last?.isNumber == true)
        return reserved ? "_" + result : result
    }

    static func resourceName(_ resource: PHAssetResource, asset: PHAsset, duplicated: Bool) -> String {
        let original = resource.originalFilename as NSString
        let ext = String(safeName(original.pathExtension).prefix(20))
        let stem = safeName(original.deletingPathExtension)
        let suffix = duplicated ? "_" + shortID(asset.localIdentifier + "|\(resource.type.rawValue)") : ""
        return stem + suffix + (original.pathExtension.isEmpty ? "" : "." + ext)
    }

    static func export(_ resource: PHAssetResource, to url: URL) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}
