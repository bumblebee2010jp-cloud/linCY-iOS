import Foundation
import SwiftUI
import UIKit

enum FolderDirection: String, Codable, CaseIterable, Identifiable {
    case mirror = "手机 → 服务器增量上传"
    case merge = "服务器 → 手机合并"
    var id: String { rawValue }
}
struct SyncEndpoint: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var address: String
    var wifiOnly: Bool
}
struct FolderSyncTask: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var endpointID: UUID
    var direction: FolderDirection
    var local: FolderAuthorization
    var remotePath: String
    var area: String
    var sharedRoot: Bool = true
}
struct MirrorPreview: Identifiable {
    let id = UUID()
    let task: FolderSyncTask
    let local: [SyncEntry]
    let remote: [SyncEntry]
    let diff: SyncDiff
    let server: Server
    let cookie: String
}
struct SyncTotals: Codable {
    var added = 0; var updated = 0; var skipped = 0; var deleted = 0; var failed = 0
}

@MainActor final class FolderSyncManager: ObservableObject {
    static let shared = FolderSyncManager()
    @Published var endpoints: [SyncEndpoint] = []
    @Published var tasks: [FolderSyncTask] = []
    @Published var logs: [String] = []
    @Published var status = "手动预览和执行，不会自动开始同步"
    @Published var running = false
    @Published var progress = 0.0
    @Published var totals = SyncTotals()
    @Published var preview: MirrorPreview?
    private var operation: Task<Void, Never>?
    private var backgroundObserver: NSObjectProtocol?
    private let defaults = UserDefaults.standard

    private init() {
        endpoints = Self.read([SyncEndpoint].self, key: "syncEndpoints") ?? []
        tasks = Self.read([FolderSyncTask].self, key: "folderSyncTasks") ?? []
        logs = Self.read([String].self, key: "folderSyncLogs") ?? []
        // Upgrade the old native folder list, preserving every saved authorization.
        if tasks.isEmpty, let legacy = Self.read([WatchedFolder].self, key: "watchedFolders"),
           let address = defaults.string(forKey: "serverAddress"), !address.isEmpty,
           let server = try? Server(address: address, wifiOnly: defaults.bool(forKey: "wifiOnly")) {
            let endpoint = SyncEndpoint(name: "原服务器", address: server.base.absoluteString, wifiOnly: defaults.bool(forKey: "wifiOnly"))
            endpoints.append(endpoint)
            tasks = legacy.map { FolderSyncTask(name: $0.displayName, endpointID: endpoint.id, direction: .mirror,
                local: FolderAuthorization(bookmark: $0.bookmark, name: $0.displayName),
                remotePath: $0.displayName, area: "upload") }
            persist()
        }
        if defaults.bool(forKey: "folderSyncInProgress") {
            status = "上次同步被中断。请重新预览或下载；已完成的文件保留，未完成的文件下次手动重试"
            defaults.set(false, forKey: "folderSyncInProgress")
        }
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.stop() } }
    }
    private static func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(endpoints) { defaults.set(data, forKey: "syncEndpoints") }
        if let data = try? JSONEncoder().encode(tasks) { defaults.set(data, forKey: "folderSyncTasks") }
        if let data = try? JSONEncoder().encode(logs) { defaults.set(data, forKey: "folderSyncLogs") }
    }
    func log(_ message: String) {
        logs.insert(Date().formatted(date: .omitted, time: .standard) + " " + message, at: 0)
        logs = Array(logs.prefix(200)); persist()
    }
    func saveServer(name: String, address: String, password: String, wifiOnly: Bool) throws -> UUID {
        let server = try Server(address: address, wifiOnly: wifiOnly)
        try Credentials.save(password, for: server.base.absoluteString)
        if let index = endpoints.firstIndex(where: { $0.address == server.base.absoluteString }) {
            endpoints[index].name = name.isEmpty ? server.base.absoluteString : name
            endpoints[index].wifiOnly = wifiOnly; persist(); return endpoints[index].id
        }
        let value = SyncEndpoint(name: name.isEmpty ? server.base.absoluteString : name,
            address: server.base.absoluteString, wifiOnly: wifiOnly)
        endpoints.append(value); persist(); return value.id
    }
    func saveTask(_ task: FolderSyncTask) throws {
        try SyncFiles.validate(task.remotePath)
        guard endpoints.contains(where: { $0.id == task.endpointID }) else { throw AppError.message("请先保存服务器") }
        if task.direction == .mirror {
            let endpoint = endpoints.first { $0.id == task.endpointID }!
            let path = task.remotePath.lowercased()
            let collision = tasks.contains { other in
                guard other.id != task.id, other.direction == .mirror,
                      let otherEndpoint = endpoints.first(where: { $0.id == other.endpointID }),
                      otherEndpoint.address.lowercased() == endpoint.address.lowercased() else { return false }
                let otherPath = other.remotePath.lowercased()
                return path == otherPath || path.hasPrefix(otherPath + "/") || otherPath.hasPrefix(path + "/")
            }
            guard !collision else { throw AppError.message("另一个上传任务已使用相同或重叠的服务器目录") }
        }
        if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = task } else { tasks.append(task) }
        persist()
    }
    func removeTask(_ id: UUID) { guard !running, preview == nil else { return }; tasks.removeAll { $0.id == id }; persist() }
    private func connection(_ task: FolderSyncTask) async throws -> (Server, String) {
        guard let endpoint = endpoints.first(where: { $0.id == task.endpointID }) else { throw AppError.message("服务器配置不存在") }
        let server = try Server(address: endpoint.address, wifiOnly: endpoint.wifiOnly)
        let cookie = try await server.login(password: Credentials.password(for: endpoint.address))
        return (server, cookie)
    }
    func browse(endpointID: UUID, area: String, path: String) async throws -> SyncManifest {
        guard let endpoint = endpoints.first(where: { $0.id == endpointID }) else { throw AppError.message("请选择服务器") }
        let server = try Server(address: endpoint.address, wifiOnly: endpoint.wifiOnly)
        let cookie = try await server.login(password: Credentials.password(for: endpoint.address))
        let entries: [SyncEntry]
        if area == "upload" {
            let listing = try await server.uploadContents(path: path, cookie: cookie)
            entries = try listing.entries.map { item in
                try SyncFiles.validate(item.name)
                guard !item.name.contains("/") else { throw AppError.message("服务器返回文件名无效") }
                return SyncEntry(path: item.name, kind: item.isDir ? "dir" : "file", size: item.size.flatMap { $0 >= 0 ? UInt64($0) : nil } ?? UInt64.max, sha256: "")
            }
        } else {
            entries = try await server.downloadListing(path: path, cookie: cookie).map { item in
                try SyncFiles.validate(item.name)
                guard !item.name.contains("/") else { throw AppError.message("服务器返回文件名无效") }
                return SyncEntry(path: item.name, kind: item.isDir ? "dir" : "file", size: item.size, sha256: "")
            }
        }
        return SyncManifest(kind: "dir", entries: entries)
    }
    private func begin() -> Bool {
        guard !running, preview == nil, !BackupManager.shared.running else {
            status = "请先完成当前同步或相册任务"; return false
        }
        running = true; totals = SyncTotals(); progress = 0
        defaults.set(true, forKey: "folderSyncInProgress")
        return true
    }
    private func finish() { running = false; operation = nil; defaults.set(false, forKey: "folderSyncInProgress"); persist() }
    static func work<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        let worker = Task.detached(priority: .userInitiated, operation: body)
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    private func scopedRoot(_ task: FolderSyncTask) throws -> ScopedFolder {
        var updated = task
        let root = try updated.local.resolve()
        if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index].local = updated.local; persist() }
        return try ScopedFolder(root)
    }
    static func difference(local: [SyncEntry], remote: [SyncEntry]) throws -> SyncDiff {
        let old = Dictionary(uniqueKeysWithValues: remote.map { ($0.path, $0) })
        var added = 0, updated = 0, skipped = 0
        for entry in local {
            guard let previous = old[entry.path] else { added += 1; continue }
            guard entry.kind == previous.kind else { throw AppError.message("服务器同名路径类型不同，原内容已保留：\(entry.path)") }
            if entry.kind == "dir" || entry.size == previous.size { skipped += 1 } else { updated += 1 }
        }
        return SyncDiff(added: added, updated: updated, skipped: skipped, deleted: 0)
    }
    func prepare(_ task: FolderSyncTask) {
        guard begin() else { return }
        operation = Task {
            defer { finish() }
            do {
                status = "完整扫描手机目录：\(task.local.name)"
                let access = try scopedRoot(task)
                let root = access.url
                defer { access.close() }
                let local = try await Self.work { try SyncFiles.scan(root) }
                try Task.checkCancellation()
                let (server, cookie) = try await connection(task)
                let remote = try await server.legacyUploadManifest(root: task.remotePath, sharedRoot: task.sharedRoot, cookie: cookie)
                let diff = try Self.difference(local: local, remote: remote)
                try Task.checkCancellation()
                preview = MirrorPreview(task: task, local: local, remote: remote, diff: diff, server: server, cookie: cookie)
                status = "预览已生成：按相对路径和大小对比，不删除服务器文件"
                log("预览 \(task.name)：新增 \(diff.added)，更新 \(diff.updated)，跳过 \(diff.skipped)，删除 0")
            } catch { report(error) }
        }
    }
    func cancelPreview() { preview = nil; status = "已取消；服务器文件未改变" }
    func confirmMirror() {
        guard let p = preview, !running else { return }
        preview = nil; running = true; defaults.set(true, forKey: "folderSyncInProgress")
        operation = Task {
            defer { finish() }
            do {
                let access = try scopedRoot(p.task)
                let root = access.url
                defer { access.close() }
                status = "重新核对手机和服务器目录"
                let current = try await Self.work { try SyncFiles.scan(root) }
                guard current == p.local else { throw AppError.message("手机目录在预览后变化，请重新预览") }
                let remote = try await p.server.legacyUploadManifest(root: p.task.remotePath, sharedRoot: p.task.sharedRoot, cookie: p.cookie)
                guard remote == p.remote else { throw AppError.message("服务器目录在预览后变化，请重新预览") }
                let old = Dictionary(uniqueKeysWithValues: remote.map { ($0.path, $0) })
                try Task.checkCancellation()
                try await p.server.ensureUploadDirectory(p.task.remotePath, cookie: p.cookie)
                var completed = 0
                for entry in p.local {
                    try Task.checkCancellation()
                    if let previous = old[entry.path], previous.kind == entry.kind,
                       entry.kind == "dir" || entry.size == previous.size {
                        totals.skipped += 1; completed += 1; continue
                    }
                    status = "增量上传：\(entry.path)"
                    if entry.kind == "dir" {
                        try await retry { try await p.server.ensureUploadDirectory(p.task.remotePath + "/" + entry.path, cookie: p.cookie) }
                    } else {
                        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                        defer { try? FileManager.default.removeItem(at: temp) }
                        try await Self.work { try SyncFiles.snapshot(root: root, entry: entry, to: temp) }
                        let relativeDir = (entry.path as NSString).deletingLastPathComponent
                        let directory = relativeDir.isEmpty ? p.task.remotePath : p.task.remotePath + "/" + relativeDir
                        try await retry {
                            try await p.server.uploadFile(path: directory, name: (entry.path as NSString).lastPathComponent,
                                fileURL: temp, size: Int64(entry.size), overwrite: true, cookie: p.cookie)
                        }
                        if p.task.sharedRoot {
                            let verified = try await p.server.downloadListing(path: directory, cookie: p.cookie)
                            guard verified.contains(where: { $0.name == (entry.path as NSString).lastPathComponent && !$0.isDir && $0.size == entry.size }) else {
                                throw AppError.message("上传后的服务器大小校验失败，请重新执行")
                            }
                        }
                    }
                    if old[entry.path] == nil { totals.added += 1 } else { totals.updated += 1 }
                    completed += 1; progress = Double(completed) / Double(max(p.local.count, 1))
                    log("已上传并核对：\(entry.path)")
                }
                status = "增量上传完成，服务器额外文件和目录全部保留"
                log(status); progress = 1
            } catch { report(error) }
        }
    }
    func download(_ task: FolderSyncTask) {
        guard begin() else { return }
        operation = Task {
            defer { finish() }
            do {
                let access = try scopedRoot(task)
                let root = access.url
                defer { access.close() }
                let (server, cookie) = try await connection(task)
                status = "读取服务器目录和文件大小"
                let manifest = try await server.legacyDownloadManifest(root: task.remotePath, cookie: cookie)
                guard ["file", "dir"].contains(manifest.kind) else { throw AppError.message("服务器文件或目录不存在") }
                let baseName = (task.remotePath as NSString).lastPathComponent
                try SyncFiles.validate(baseName)
                let items: [SyncEntry] = manifest.kind == "dir" ?
                    [SyncEntry(path: "", kind: "dir", size: 0, sha256: "")] + manifest.entries : manifest.entries
                for (index, entry) in items.enumerated() {
                    try Task.checkCancellation()
                    let relative = entry.path.isEmpty ? baseName : baseName + "/" + entry.path
                    try SyncFiles.validate(relative)
                    status = "合并下载 \(index + 1)/\(items.count)：\(relative)"
                    if entry.kind == "dir" {
                        try await Self.work {
                            try SyncFiles.coordinate(root, writing: true) { value in
                                let dir = try SyncFiles.safeURL(root: value, path: relative, createParents: true)
                                if FileManager.default.fileExists(atPath: dir.path) {
                                    guard try dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                                        throw AppError.message("手机同名路径是文件，已保留原文件并停止")
                                    }
                                } else { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false) }
                            }
                        }
                        continue
                    }
                    guard entry.kind == "file" else { throw AppError.message("服务器清单无效") }
                    let existing: (Bool, Bool) = try await Self.work {
                        try SyncFiles.coordinate(root) { value in
                            let dest = try SyncFiles.safeURL(root: value, path: relative)
                            guard FileManager.default.fileExists(atPath: dest.path) else { return (false, false) }
                            let values = try dest.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                            guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else { throw AppError.message("手机同名路径不是普通文件") }
                            return (true, UInt64(size) == entry.size)
                        }
                    }
                    if existing.1 { totals.skipped += 1; continue }
                    let remote = entry.path.isEmpty ? task.remotePath : task.remotePath + "/" + entry.path
                    let temp = try await retry { try await server.legacyDownload(path: remote, expectedSize: entry.size, cookie: cookie) }
                    defer { try? FileManager.default.removeItem(at: temp) }
                    try Task.checkCancellation()
                    try await Self.work { try SyncFiles.mergeFile(temp: temp, root: root, relative: relative, expected: entry) }
                    if existing.0 { totals.updated += 1 } else { totals.added += 1 }
                    progress = Double(index + 1) / Double(max(items.count, 1))
                    log("下载且校验通过：\(relative)")
                }
                status = "合并下载完成，手机额外文件和目录已保留"; progress = 1; log(status)
            } catch { report(error) }
        }
    }
    private func retry<T>(_ action: () async throws -> T) async throws -> T {
        for attempt in 1...3 {
            try Task.checkCancellation()
            do { return try await action() }
            catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                guard attempt < 3 else { throw error }
                log("传输失败，第 \(attempt) 次重试：\(error.localizedDescription)")
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
        }
        throw AppError.message("传输失败")
    }
    private func report(_ error: Error) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            status = "已中断；已完成文件保留，请重新预览或下载"
        } else { totals.failed += 1; status = "失败：\(error.localizedDescription)" }
        log(status)
    }
    func stop() {
        if running { operation?.cancel(); status = "正在停止当前传输；下次执行会重新对比" }
        else if preview != nil { cancelPreview() }
    }
}
