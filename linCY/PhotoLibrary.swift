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

    // MARK: - 反向同步：服务器 → 手机相册

    /// 相册内已有文件的原始文件名集合（小写），用于和服务器对比。
    /// 上传统一用 originalFilename 命名，所以两端能对得上。
    static func existingFilenames(in collection: PHAssetCollection) async -> Set<String> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let assets = PHAsset.fetchAssets(in: collection, options: nil)
                var names = Set<String>()
                names.reserveCapacity(assets.count)
                assets.enumerateObjects { asset, _, _ in
                    if let resource = PHAssetResource.assetResources(for: asset).first {
                        names.insert(resource.originalFilename.lowercased())
                    }
                }
                continuation.resume(returning: names)
            }
        }
    }

    /// 按标题查找用户相册（不匹配智能相册）。
    static func album(named title: String) -> PHAssetCollection? {
        let result = PHAssetCollection.fetchAssetCollections(with: .album,
            subtype: .albumRegular, options: nil)
        var found: PHAssetCollection?
        result.enumerateObjects { collection, _, stop in
            if collection.localizedTitle == title {
                found = collection
                stop.pointee = true
            }
        }
        return found
    }

    /// 没有同名相册时新建一个。
    static func ensureAlbum(named title: String) async throws -> PHAssetCollection {
        if let existing = album(named: title) { return existing }

        var placeholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            placeholder = request.placeholderForCreatedAssetCollection
        }
        guard let identifier = placeholder?.localIdentifier,
              let created = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [identifier], options: nil).firstObject
        else { throw AppError.message("创建相册失败：\(title)") }
        return created
    }

    /// 把下载好的临时文件存进指定相册。文件会被 PhotoKit 移走，调用方无需再删。
    static func saveDownloaded(fileURL: URL, kind: String, into collection: PHAssetCollection) async throws {
        let type: PHAssetResourceType = (kind == "video") ? .video : .photo
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            request.addResource(with: type, fileURL: fileURL, options: options)
            if let albumChange = PHAssetCollectionChangeRequest(for: collection),
               let placeholder = request.placeholderForCreatedAsset {
                albumChange.addAssets([placeholder] as NSArray)
            }
        }
    }
}
