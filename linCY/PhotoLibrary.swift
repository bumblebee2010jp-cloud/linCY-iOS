import Photos
import CryptoKit
import Foundation
import ImageIO
import AVFoundation

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

    /// 上传和下载查重必须使用同一份资源清单及重名规则。
    struct BackupEntry {
        let resource: PHAssetResource
        let name: String
        let creationDate: Date?
    }

    static func backupEntries(in collection: PHAssetCollection) -> [BackupEntry] {
        let assets = PHAsset.fetchAssets(in: collection, options: options())
        var counts: [String: Int] = [:]
        assets.enumerateObjects { asset, _, _ in
            for resource in resources(asset) {
                let name = resourceName(resource, asset: asset, duplicated: false)
                counts[name.lowercased(), default: 0] += 1
            }
        }
        var entries: [BackupEntry] = []
        assets.enumerateObjects { asset, _, _ in
            for resource in resources(asset) {
                let plain = resourceName(resource, asset: asset, duplicated: false)
                entries.append(BackupEntry(resource: resource,
                    name: resourceName(resource, asset: asset,
                        duplicated: (counts[plain.lowercased()] ?? 0) > 1),
                    creationDate: asset.creationDate))
            }
        }
        return entries
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

    /// 包含动图、实况照片的全部备份资源，并沿用上传的安全命名和重名后缀。
    static func existingFilenames(in collection: PHAssetCollection) async -> Set<String> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let names = Set(backupEntries(in: collection).map { $0.name.lowercased() })
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

    // 只记录本机已知的相册日期；按服务器、远端相册、完整文件名隔离。
    // 不把下载时间、HTTP Last-Modified 或缓存文件创建时间当成拍摄时间。
    static func dateKey(server: URL, album: String, name: String) -> String {
        let identity = [server.absoluteString, album, name]
        let data = try! JSONEncoder().encode(identity)
        return "captureDate." + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func rememberDate(_ date: Date?, server: URL, album: String, name: String) {
        guard let date else { return }
        UserDefaults.standard.set(date, forKey: dateKey(server: server, album: album, name: name))
    }

    static func rememberedDate(server: URL, album: String, name: String) -> Date? {
        UserDefaults.standard.object(forKey: dateKey(server: server, album: album, name: name)) as? Date
    }

    static func embeddedCreationDate(fileURL: URL, kind: String) async -> Date? {
        if kind == "video" {
            let asset = AVURLAsset(url: fileURL)
            if let item = try? await asset.load(.creationDate) {
                if let date = try? await item.load(.dateValue) { return date }
                if let value = try? await item.load(.stringValue) {
                    let formatter = ISO8601DateFormatter()
                    if let date = formatter.date(from: value) { return date }
                    formatter.formatOptions.insert(.withFractionalSeconds)
                    return formatter.date(from: value)
                }
            }
            return nil
        }
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let values = [
            (exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String,
             exif?["OffsetTimeOriginal"] as? String),
            (exif?[kCGImagePropertyExifDateTimeDigitized as String] as? String,
             exif?["OffsetTimeDigitized"] as? String),
            (tiff?[kCGImagePropertyTIFFDateTime as String] as? String, nil)
        ]
        for (value, offset) in values {
            guard let value else { continue }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.isLenient = false
            if let offset {
                formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
                if let date = formatter.date(from: value + offset) { return date }
            } else {
                // EXIF 没有时区时沿用本机时区，不能假定为 UTC 造成八小时偏移。
                formatter.timeZone = .current
                formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
                if let date = formatter.date(from: value) { return date }
            }
        }
        return nil
    }

    /// 把下载好的临时文件存进指定相册。文件会被 PhotoKit 移走，调用方无需再删。
    static func saveDownloaded(fileURL: URL, originalFilename: String, kind: String, creationDate: Date?, into collection: PHAssetCollection) async throws {
        let embeddedDate = await embeddedCreationDate(fileURL: fileURL, kind: kind)
        guard let captureDate = creationDate ?? embeddedDate else {
            throw AppError.message("无法确定原拍摄时间，已跳过保存以免变成下载时间；如本机仍有原件，请先备份一次以记录日期")
        }
        let type: PHAssetResourceType = (kind == "video") ? .video : .photo
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.creationDate = captureDate
            let options = PHAssetResourceCreationOptions()
            // 中转路径带 UUID，仅用于防止缓存冲突，不能成为相册中的文件名。
            options.originalFilename = originalFilename
            options.shouldMoveFile = true
            request.addResource(with: type, fileURL: fileURL, options: options)
            if let albumChange = PHAssetCollectionChangeRequest(for: collection),
               let placeholder = request.placeholderForCreatedAsset {
                albumChange.addAssets([placeholder] as NSArray)
            }
        }
    }
}
