import Foundation
import CryptoKit
import UIKit
import UniformTypeIdentifiers
import SwiftUI

struct SyncEntry: Codable, Equatable, Sendable {
    let path: String
    let kind: String
    let size: UInt64
    let sha256: String
    var modified: TimeInterval? = nil
}
struct SyncManifest: Codable, Equatable, Sendable { let kind: String; let entries: [SyncEntry] }
struct SyncDiff: Codable, Sendable { let added: Int; let updated: Int; let skipped: Int; let deleted: Int }
// iOS document-picker URLs embed the security scope in their bookmark. The macOS-only
// .withSecurityScope option is intentionally not used on iOS.
struct FolderAuthorization: Codable, Equatable, Sendable {
    var bookmark: Data
    var name: String
    static func capture(_ url: URL) throws -> Self {
        let access = try ScopedFolder(url)
        defer { access.close() }
        return try SyncFiles.coordinate(url) { coordinated in
            let values = try coordinated.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw AppError.message("请选择可访问的普通文件夹")
            }
            // A real directory read distinguishes an empty folder from denied access.
            _ = try FileManager.default.contentsOfDirectory(at: coordinated, includingPropertiesForKeys: nil, options: [])
            let bookmark = try coordinated.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            return Self(bookmark: bookmark, name: coordinated.lastPathComponent)
        }
    }
    mutating func resolve() throws -> URL {
        var stale = false
        let url: URL
        do { url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) }
        catch { throw AppError.message("文件夹书签已失效，请重新选择：\(name)") }
        let access = try ScopedFolder(url)
        defer { access.close() }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw AppError.message("文件夹已移动或不存在，请重新选择") }
        if stale { bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) }
        name = url.lastPathComponent
        return url
    }
}

struct ScopedFolder {
    let url: URL
    private let started: Bool
    init(_ url: URL) throws {
        self.url = url
        started = url.startAccessingSecurityScopedResource()
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard started || url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(home) else {
            throw AppError.message("文件夹授权已失效，请编辑任务并重新选择文件夹")
        }
    }
    func close() { if started { url.stopAccessingSecurityScopedResource() } }
}

// MARK: - App 文档目录浏览（不依赖系统文件夹选择器）

/// App 自己的 Documents 目录。配合 Info.plist 的 UIFileSharingEnabled，
/// 用户可以在「文件」App → 我的 iPhone → linCY 里放入文件夹，
/// 这里直接逐层浏览并选择，完全不经过 UIDocumentPicker。
enum DocumentFolders {
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func children(of folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { (try? $0.resourceValues(forKeys: Set(keys)).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func displayPath(of folder: URL) -> String {
        let base = root.standardizedFileURL.path
        let value = folder.standardizedFileURL.path
        guard value.hasPrefix(base) else { return folder.lastPathComponent }
        var relative = String(value.dropFirst(base.count))
        while relative.hasPrefix("/") { relative.removeFirst() }
        return relative.isEmpty ? "linCY" : relative
    }
}

/// 在 App 文档目录里逐层浏览并选择文件夹。
/// 每个列表行只有一个可点控件，避免 List 同行多 Button 互相抢占。
struct AppFolderPicker: View {
    var folder: URL = DocumentFolders.root
    var onPick: (URL) -> Void
    var onClose: () -> Void

    @State private var children: [URL] = []

    private var isRoot: Bool {
        folder.standardizedFileURL.path == DocumentFolders.root.standardizedFileURL.path
    }

    var body: some View {
        List {
            if !isRoot {
                Section {
                    Button {
                        onPick(folder)
                    } label: {
                        Label("选择此文件夹：\(DocumentFolders.displayPath(of: folder))",
                              systemImage: "checkmark.circle")
                    }
                }
            }

            Section {
                if children.isEmpty {
                    Text("这里没有文件夹。打开「文件」App → 我的 iPhone → linCY，把文件夹拷进来；也可以点右上角新建一个。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(children, id: \.self) { child in
                    NavigationLink(child.lastPathComponent) {
                        AppFolderPicker(folder: child, onPick: onPick, onClose: onClose)
                    }
                }
            } header: {
                Text(DocumentFolders.displayPath(of: folder))
            }
        }
        .navigationTitle(isRoot ? "App 文档" : folder.lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { onClose() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("新建文件夹") { createFolder() }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        children = DocumentFolders.children(of: folder)
    }

    private func createFolder() {
        let name = "新建文件夹 " + String(Int(Date().timeIntervalSince1970) % 10000)
        let target = folder.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        reload()
    }
}

enum SyncFiles {
    static let fm = FileManager.default
    static func validate(_ path: String, allowEmpty: Bool = false) throws {
        if path.isEmpty && allowEmpty { return }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 2048, parts.count <= 63 else { throw AppError.message("目录路径为空或过长") }
        for part in parts {
            let stem = part.split(separator: ".", omittingEmptySubsequences: false).first?.uppercased() ?? ""
            let reserved = ["CON", "PRN", "AUX", "NUL"].contains(stem) ||
                (stem.count == 4 && (stem.hasPrefix("COM") || stem.hasPrefix("LPT")) && stem.last?.isNumber == true)
            guard !part.isEmpty, part != ".", part != "..", part.utf8.count <= 220,
                  !part.hasSuffix("."), !part.hasSuffix(" "), !part.lowercased().hasPrefix(".vuio-"),
                  part.rangeOfCharacter(from: CharacterSet(charactersIn: "\\:*?\"<>|").union(.controlCharacters)) == nil,
                  !reserved else { throw AppError.message("不支持的文件名或不安全路径：\(path)") }
        }
    }
    static func coordinate<T>(_ url: URL, writing: Bool = false, _ body: @escaping (URL) throws -> T) throws -> T {
        var failure: NSError?
        var outcome: Result<T, Error>?
        let access: (URL) -> Void = { value in outcome = Result { try body(value) } }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        if writing { coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &failure, byAccessor: access) }
        else { coordinator.coordinate(readingItemAt: url, options: [], error: &failure, byAccessor: access) }
        if let failure { throw failure }
        guard let outcome else { throw AppError.message("文件协调访问未完成") }
        return try outcome.get()
    }
    static func hash(_ url: URL) throws -> (UInt64, String) {
        let before = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard before.isRegularFile == true, before.isSymbolicLink != true else { throw AppError.message("不是普通文件或是符号链接") }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = SHA256(); var size: UInt64 = 0
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data); size += UInt64(data.count)
        }
        let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey])
        guard let expectedSize = before.fileSize, expectedSize >= 0, size == UInt64(expectedSize), before.fileSize == after.fileSize,
              before.contentModificationDate == after.contentModificationDate, after.isSymbolicLink != true else {
            throw AppError.message("文件在扫描时变化，请重新预览")
        }
        return (size, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
    static func scan(_ root: URL) throws -> [SyncEntry] {
        try coordinate(root) { root in
            let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
                throw AppError.message("本地源目录不可读，同步已停止")
            }
            var entries: [SyncEntry] = []
            var portable = Set<String>()
            func walk(_ folder: URL, prefix: String) throws {
                // Throw on every failed directory listing; never treat a failed scan as an empty directory.
                let children = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys:
                    [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: [])
                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    try Task.checkCancellation()
                    let path = prefix.isEmpty ? child.lastPathComponent : prefix + "/" + child.lastPathComponent
                    try validate(path)
                    guard portable.insert(path.lowercased()).inserted, entries.count < 100000 else {
                        throw AppError.message("路径大小写冲突或目录超过 100000 项，同步已停止")
                    }
                    let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                    guard values.isSymbolicLink != true else { throw AppError.message("源目录含符号链接，同步已停止") }
                    if values.isDirectory == true {
                        entries.append(SyncEntry(path: path, kind: "dir", size: 0, sha256: ""))
                        try walk(child, prefix: path)
                    } else if values.isRegularFile == true {
                        guard let size = values.fileSize, size >= 0, let modified = values.contentModificationDate else {
                            throw AppError.message("无法读取文件大小或修改时间：\(path)")
                        }
                        entries.append(SyncEntry(path: path, kind: "file", size: UInt64(size), sha256: "", modified: modified.timeIntervalSince1970))
                    } else { throw AppError.message("源目录含无法读取的特殊文件，同步已停止") }
                }
            }
            try walk(root, prefix: "")
            return entries.sorted { $0.path < $1.path }
        }
    }
    static func safeURL(root: URL, path: String, createParents: Bool = false) throws -> URL {
        try validate(path)
        let parts = path.split(separator: "/").map(String.init)
        var current = root
        for (index, part) in parts.enumerated() {
            current.appendPathComponent(part)
            let exists = fm.fileExists(atPath: current.path)
            if exists {
                let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                guard values.isSymbolicLink != true else { throw AppError.message("目标路径含符号链接") }
                if index < parts.count - 1 && values.isDirectory != true { throw AppError.message("目标父路径不是目录") }
            } else if createParents && index < parts.count - 1 {
                try fm.createDirectory(at: current, withIntermediateDirectories: false)
            }
        }
        let prefix = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard current.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(prefix) else {
            throw AppError.message("路径超出已授权目录")
        }
        return current
    }
    static func snapshot(root: URL, entry: SyncEntry, to temp: URL) throws {
        try coordinate(root) { root in
            let source = try safeURL(root: root, path: entry.path)
            let modified = try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970
            if let expected = entry.modified, modified != expected { throw AppError.message("本地文件在预览后变化，请重新预览") }
            try fm.copyItem(at: source, to: temp)
            let (size, digest) = try hash(temp)
            let original = try hash(source)
            guard size == entry.size, original.0 == size, original.1 == digest,
                  entry.sha256.isEmpty || digest == entry.sha256 else { throw AppError.message("本地文件在预览后变化，请重新预览") }
        }
    }
    static func mergeFile(temp: URL, root: URL, relative: String, expected: SyncEntry) throws {
        let (size, digest) = try hash(temp)
        guard size == expected.size, expected.sha256.isEmpty || digest == expected.sha256 else { throw AppError.message("下载校验失败，原文件保持不变") }
        try coordinate(root, writing: true) { root in
            let target = try safeURL(root: root, path: relative, createParents: true)
            if fm.fileExists(atPath: target.path), try target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                throw AppError.message("手机同名路径是目录，为保留额外内容，已停止覆盖")
            }
            // Copy onto the destination volume before atomically replacing the original file.
            let sibling = target.deletingLastPathComponent().appendingPathComponent(".lincy-" + UUID().uuidString + ".part")
            defer { try? fm.removeItem(at: sibling) }
            try fm.copyItem(at: temp, to: sibling)
            let checked = try hash(sibling)
            guard checked.0 == expected.size, checked.1 == digest else { throw AppError.message("目标临时文件校验失败") }
            if fm.fileExists(atPath: target.path) { _ = try fm.replaceItemAt(target, withItemAt: sibling) }
            else { try fm.moveItem(at: sibling, to: target) }
        }
    }
}

extension Server {
    struct LegacyFile: Decodable, Sendable {
        let name: String
        let size: UInt64
        let isDir: Bool
        enum CodingKeys: String, CodingKey { case name, size; case isDir = "is_dir" }
    }
    func downloadListing(path: String, cookie: String) async throws -> [LegacyFile] {
        let (data, _) = try await send(request("api/files", query: [.init(name: "path", value: path)], cookie: cookie))
        return try JSONDecoder().decode([LegacyFile].self, from: data)
    }
    // Every path component is checked and created with the old API's actual `path`
    // parameter. `parent` is an album-only parameter and is not accepted here.
    func ensureUploadDirectory(_ path: String, cookie: String) async throws {
        try SyncFiles.validate(path)
        var parent = ""
        for name in path.split(separator: "/").map(String.init) {
            let wanted = parent.isEmpty ? name : parent + "/" + name
            let listing = try await uploadContents(path: parent, cookie: cookie)
            if let existing = listing.entries.first(where: { $0.name == name }) {
                guard existing.isDir else { throw AppError.message("服务器同名路径是文件，已保留：\(wanted)") }
            } else {
                var r = request("api/upload-folder", cookie: cookie)
                r.httpMethod = "POST"
                r.setValue("1", forHTTPHeaderField: "x-vuio-upload")
                r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                r.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "path": parent, "conflict": "overwrite"])
                let (data, _) = try await send(r)
                struct Reply: Decodable { let directory: String }
                guard try JSONDecoder().decode(Reply.self, from: data).directory == wanted else {
                    throw AppError.message("服务器返回了不同的目录路径，已停止上传")
                }
            }
            parent = wanted
        }
    }
    func legacyUploadManifest(root: String, sharedRoot: Bool, cookie: String) async throws -> [SyncEntry] {
        try SyncFiles.validate(root)
        // A missing selected root is established by a successful listing of its parent,
        // never by swallowing 401/403/network/parse errors as an empty directory.
        var parent = ""
        for component in root.split(separator: "/").map(String.init) {
            let listing = try await uploadContents(path: parent, cookie: cookie)
            guard let item = listing.entries.first(where: { $0.name == component }) else { return [] }
            guard item.isDir else { throw AppError.message("目标同步根路径是文件，不能覆盖成文件夹") }
            parent = parent.isEmpty ? component : parent + "/" + component
        }
        var result: [SyncEntry] = []
        var queue = [(root, "")]
        var names = Set<String>()
        while let (directory, prefix) = queue.popLast() {
            try Task.checkCancellation()
            let listing = try await uploadContents(path: directory, cookie: cookie)
            let sizes = sharedRoot ? try await downloadListing(path: directory, cookie: cookie) : []
            let sizeMap = Dictionary(uniqueKeysWithValues: sizes.map { ($0.name, $0) })
            for item in listing.entries {
                try SyncFiles.validate(item.name)
                guard !item.name.contains("/") else { throw AppError.message("服务器返回的文件名无效") }
                let relative = prefix.isEmpty ? item.name : prefix + "/" + item.name
                try SyncFiles.validate(relative)
                guard names.insert(relative.lowercased()).inserted, result.count < 100000 else {
                    throw AppError.message("服务器路径重复或清单过大")
                }
                var size = item.size.flatMap { $0 >= 0 ? UInt64($0) : nil } ?? UInt64.max
                if sharedRoot {
                    guard let measured = sizeMap[item.name], measured.isDir == item.isDir else {
                        throw AppError.message("两组目录清单不一致，请确认备份和下载根目录相同，或关闭读取大小开关")
                    }
                    size = measured.size
                }
                result.append(SyncEntry(path: relative, kind: item.isDir ? "dir" : "file", size: item.isDir ? 0 : size, sha256: ""))
                if item.isDir { queue.append((directory + "/" + item.name, relative)) }
            }
        }
        return result.sorted { $0.path < $1.path }
    }
    func legacyDownloadManifest(root: String, cookie: String) async throws -> SyncManifest {
        try SyncFiles.validate(root)
        let parent = (root as NSString).deletingLastPathComponent
        let name = (root as NSString).lastPathComponent
        let siblings = try await downloadListing(path: parent, cookie: cookie)
        guard let selected = siblings.first(where: { $0.name == name }) else { throw AppError.message("服务器路径不存在") }
        if !selected.isDir { return SyncManifest(kind: "file", entries: [SyncEntry(path: "", kind: "file", size: selected.size, sha256: "")]) }
        var result: [SyncEntry] = []
        var queue = [(root, "")]
        var names = Set<String>()
        while let (directory, prefix) = queue.popLast() {
            try Task.checkCancellation()
            for item in try await downloadListing(path: directory, cookie: cookie) {
                try SyncFiles.validate(item.name)
                guard !item.name.contains("/") else { throw AppError.message("服务器返回的文件名无效") }
                let relative = prefix.isEmpty ? item.name : prefix + "/" + item.name
                try SyncFiles.validate(relative)
                guard names.insert(relative.lowercased()).inserted, result.count < 100000 else { throw AppError.message("服务器路径重复或清单过大") }
                result.append(SyncEntry(path: relative, kind: item.isDir ? "dir" : "file", size: item.isDir ? 0 : item.size, sha256: ""))
                if item.isDir { queue.append((directory + "/" + item.name, relative)) }
            }
        }
        return SyncManifest(kind: "dir", entries: result.sorted { $0.path < $1.path })
    }
    func legacyDownload(path: String, expectedSize: UInt64, cookie: String) async throws -> URL {
        var r = request("api/download", query: [.init(name: "name", value: path)], cookie: cookie)
        r.timeoutInterval = 3600
        // Existing server streams files directly; it does not implement ranged downloads.
        // Failed transfers are retried from the beginning and never replace the destination.
        let (temp, response) = try await session.download(for: r)
        do {
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw AppError.message("文件下载失败")
            }
            let actual = try FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? NSNumber
            guard actual?.uint64Value == expectedSize, response.expectedContentLength < 0 || UInt64(response.expectedContentLength) == expectedSize else {
                throw AppError.message("下载长度校验失败，原文件保持不变")
            }
            return temp
        } catch { try? FileManager.default.removeItem(at: temp); throw error }
    }
}
