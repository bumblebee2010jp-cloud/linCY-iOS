import UIKit
import Photos
import SwiftUI

// Main-thread state; URLSession delegates are delivered on OperationQueue.main.
final class BackupManager: NSObject, ObservableObject, URLSessionDataDelegate {
    static let shared = BackupManager()
    static let sessionID = "com.lincy.ios.album-upload"
    @Published var albums: [PhoneAlbum] = []
    /// 服务器上的相册文件夹列表（相册备份页「服务器相册」分页展示）。
    @Published var remoteAlbums: [String] = []
    @Published var loadingRemote = false
    @Published var selected = Set(UserDefaults.standard.stringArray(forKey: "selectedAlbums") ?? []) {
        didSet { UserDefaults.standard.set(Array(selected), forKey: "selectedAlbums") }
    }
    /// 用户长按隐藏的相册。隐藏后移出主列表、显示在底部「已隐藏相册」分组，并取消勾选。
    @Published var hidden = Set(UserDefaults.standard.stringArray(forKey: "hiddenAlbums") ?? []) {
        didSet { UserDefaults.standard.set(Array(hidden), forKey: "hiddenAlbums") }
    }
    @Published var running = false
    @Published var restoring = true
    @Published var status = "选择相册后，点击开始备份"
    @Published var logs: [String] = []
    @Published var uploaded = 0
    @Published var skipped = 0
    @Published var failed = 0
    @Published var downloaded = 0
    @Published var progress: Double = 0
    var backgroundCompletion: (() -> Void)?
    private var session: URLSession!
    private var uploadContinuation: CheckedContinuation<Bool, Error>?
    private var responseBody = Data()
    private var stopRequested = false
    private var grace: UIBackgroundTaskIdentifier = .invalid
    private let pendingKey = "pendingUploadFile"
    private let pendingNameKey = "pendingUploadName"
    private let fileManager = FileManager.default

    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.httpMaximumConnectionsPerHost = 1
        config.timeoutIntervalForResource = 24 * 60 * 60
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        session.getAllTasks { tasks in
            DispatchQueue.main.async {
                self.restoring = false
                if tasks.isEmpty {
                    self.cleanPending()
                } else {
                    self.running = true
                    self.status = "正在恢复上次已提交的上传；完成后可手动开始下一轮"
                    tasks.forEach { $0.resume() }
                }
            }
        }
    }

    func log(_ text: String) {
        logs.insert(text, at: 0)
        if logs.count > 100 { logs.removeLast() }
    }

    @MainActor func loadAlbums() async {
        do {
            albums = try await PhotoLibrary.load()
            let visible = Set(albums.map(\.id))
            selected.formIntersection(visible)
            // 相册被删除或重建后，隐藏记录里会留下无效 ID，顺手清掉。
            hidden.formIntersection(visible)
            if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited {
                status = "当前仅能备份你授权的部分照片；如需完整相册，请在系统设置允许所有照片"
            }
        } catch { status = error.localizedDescription }
    }

    /// 长按隐藏：移出主列表，同时取消勾选，避免下次误备份。
    func hide(_ albumID: String) {
        hidden.insert(albumID)
        selected.remove(albumID)
    }

    func unhide(_ albumID: String) {
        hidden.remove(albumID)
    }

    func stop() {
        stopRequested = true
        status = "将在当前文件处理完成后停止"
    }

    @MainActor func start(address: String, password: String, wifiOnly: Bool) async {
        guard !running, !restoring else { return }
        let chosen = albums.filter { selected.contains($0.id) }
        guard !chosen.isEmpty else { status = "请先选择至少一个相册"; return }
        running = true
        stopRequested = false
        uploaded = 0; skipped = 0; failed = 0; progress = 0
        grace = UIApplication.shared.beginBackgroundTask(withName: "Prepare album backup") { [weak self] in
            DispatchQueue.main.async {
                self?.stopRequested = true
                self?.endGrace()
            }
        }
        defer { running = false; endGrace(); progress = 0 }
        do {
            let server = try Server(address: address, wifiOnly: wifiOnly)
            let cookie = try await server.login(password: password)
            var known = Set(try await server.albums(cookie: cookie))
            let titleCounts = Dictionary(grouping: albums, by: { PhotoLibrary.safeName($0.title).lowercased() })
            for album in chosen {
                try checkStop()
                var folder = PhotoLibrary.safeName(album.title)
                if (titleCounts[folder.lowercased()]?.count ?? 0) > 1 {
                    folder += "_" + PhotoLibrary.shortID(album.id)
                }
                status = "正在对比相册：\(album.title)"
                folder = try await server.ensureAlbum(folder, known: &known, cookie: cookie)
                log("相册 \(album.title) → 服务器 /\(folder)")
                let entries = PhotoLibrary.backupEntries(in: album.collection)

                // 第二步：并发查重。原来是每个文件一次串行 exists，往返次数等于文件数；
                // 现在按固定窗口并发，往返次数降到 1/parallel。
                status = "正在对比 \(album.title)：0 / \(entries.count)"
                let existing = try await existingNames(server: server, album: folder,
                    names: entries.map(\.name), cookie: cookie) { done, total in
                    status = "正在对比 \(album.title)：\(done) / \(total)"
                }
                skipped += existing.count
                log("相册 \(album.title)：共 \(entries.count) 个文件，服务器已有 \(existing.count) 个")

                // 第三步：只上传缺失文件。上传仍逐个串行（后台 URLSession 单任务模型）。
                for entry in entries {
                    try checkStop()
                    if existing.contains(entry.name) { continue }
                    let name = entry.name
                    do {
                        status = "正在备份 \(album.title)：\(name)"
                        let temp = try exportURL()
                        defer { try? fileManager.removeItem(at: temp) }
                        try await PhotoLibrary.export(entry.resource, to: temp)
                        try checkStop()
                        let attrs = try fileManager.attributesOfItem(atPath: temp.path)
                        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                        guard size <= 20 * 1024 * 1024 * 1024 else {
                            throw AppError.message("单个文件超过服务器 20 GiB 限制")
                        }
                        let request = server.uploadRequest(album: folder, name: name, cookie: cookie, size: size)
                        let wasSkipped = try await upload(request, file: temp, name: name, wifiOnly: wifiOnly)
                        if wasSkipped { skipped += 1 } else { uploaded += 1 }
                        log(wasSkipped ? "服务器已有：\(name)" : "已备份：\(name)")
                    } catch {
                        failed += 1
                        log("失败 \(name)：\(error.localizedDescription)")
                        // Authentication/network failures should not hammer the server for every photo.
                        if error is URLError || error.localizedDescription.contains("HTTP 401") ||
                            error.localizedDescription.contains("HTTP 429") { throw error }
                        if stopRequested { throw CancellationError() }
                    }
                }
            }
            status = "本轮完成：上传 \(uploaded)，已有跳过 \(skipped)，失败 \(failed)"
        } catch is CancellationError {
            status = "已停止；下次点击开始备份会重新对比并补传"
        } catch {
            status = "本轮中止：\(error.localizedDescription)。修复后点击开始备份重试"
            log(status)
        }
    }

    // MARK: - 反向同步：服务器相册 → 手机相册

    /// 读取服务器上的相册文件夹列表，供「服务器相册」分页展示。
    @MainActor func loadRemoteAlbums(address: String, password: String, wifiOnly: Bool) async {
        guard !running, !loadingRemote else { return }
        loadingRemote = true
        defer { loadingRemote = false }
        do {
            let server = try Server(address: address, wifiOnly: wifiOnly)
            let cookie = try await server.login(password: password)
            remoteAlbums = try await server.albums(cookie: cookie)
            status = "服务器上有 \(remoteAlbums.count) 个相册"
        } catch {
            status = "读取服务器相册失败：\(error.localizedDescription)"
            log(status)
        }
    }

    /// 把服务器上的指定相册同步到手机同名相册：不存在就新建，
    /// 只下载手机里没有的文件（按原始文件名比对，和上传用的是同一套命名）。
    @MainActor func syncAlbums(_ names: [String], address: String, password: String, wifiOnly: Bool) async {
        guard !running, !restoring, !names.isEmpty else { return }
        running = true
        stopRequested = false
        uploaded = 0; skipped = 0; failed = 0; downloaded = 0; progress = 0
        grace = UIApplication.shared.beginBackgroundTask(withName: "Sync albums from server") { [weak self] in
            DispatchQueue.main.async {
                self?.stopRequested = true
                self?.endGrace()
            }
        }
        defer { running = false; endGrace(); progress = 0 }

        do {
            let server = try Server(address: address, wifiOnly: wifiOnly)
            let cookie = try await server.login(password: password)
            log("开始同步 \(names.count) 个相册")

            // 手机上被隐藏的相册，同名的不再往回同步。
            var hiddenNames = Set<String>()
            for album in albums where hidden.contains(album.id) {
                hiddenNames.insert(album.title)
                hiddenNames.insert(PhotoLibrary.safeName(album.title))
            }

            var index = 0
            for remoteName in names {
                try checkStop()
                index += 1
                let title = remoteName.split(separator: "/").last.map(String.init) ?? remoteName
                if hiddenNames.contains(remoteName) || hiddenNames.contains(title) {
                    log("跳过已隐藏相册：\(remoteName)")
                    continue
                }

                status = "对比 \(index)/\(names.count)：\(remoteName)"
                let items = try await remotePhotos(server: server, album: remoteName, cookie: cookie)
                if items.isEmpty {
                    log("\(remoteName)：服务器上没有可同步的图片或视频")
                    continue
                }

                let collection = try await PhotoLibrary.ensureAlbum(named: title)
                let existing = await PhotoLibrary.existingFilenames(in: collection)
                let missing = items.filter { !existing.contains($0.name.lowercased()) }
                skipped += items.count - missing.count
                log("\(remoteName)：共 \(items.count) 个，手机已有 \(items.count - missing.count) 个，待下载 \(missing.count) 个")
                if missing.isEmpty { continue }

                let staging = try stagingDirectory()
                for item in missing {
                    try checkStop()
                    status = "下载 \(remoteName)：\(item.name)"
                    let target = staging.appendingPathComponent(UUID().uuidString + "-" + item.name)
                    do {
                        try await server.downloadPhoto(album: remoteName, name: item.name,
                            cookie: cookie, to: target)
                        try await PhotoLibrary.saveDownloaded(fileURL: target, originalFilename: item.name,
                            kind: item.kind, into: collection)
                        downloaded += 1
                        log("已同步：\(item.name)")
                    } catch {
                        failed += 1
                        log("失败 \(item.name)：\(error.localizedDescription)")
                        try? fileManager.removeItem(at: target)
                        if error is URLError || error.localizedDescription.contains("HTTP 401") ||
                            error.localizedDescription.contains("HTTP 429") { throw error }
                        if stopRequested { throw CancellationError() }
                    }
                }
            }
            await loadAlbums()
            status = "同步完成：下载 \(downloaded)，已有跳过 \(skipped)，失败 \(failed)"
        } catch is CancellationError {
            status = "已停止；下次点击同步会重新对比"
        } catch {
            status = "同步中止：\(error.localizedDescription)"
            log(status)
        }
    }

    /// 分页拉取服务器某个相册的全部文件。
    /// 服务端固定每页 12 条，首屏拿到 total 后并发补齐其余页。
    @MainActor
    private func remotePhotos(server: Server, album: String, cookie: String)
        async throws -> [(name: String, kind: String)] {
        let first = try await server.photos(album: album, offset: 0, cookie: cookie)

        var seen = Set<String>()
        var result: [(name: String, kind: String)] = []
        result.reserveCapacity(first.total)
        for item in first.photos where seen.insert(item.name).inserted {
            result.append((item.name, item.kind))
        }
        guard first.total > result.count, !first.photos.isEmpty else { return result }

        let pageSize = first.photos.count
        var offsets: [Int] = []
        var cursor = pageSize
        while cursor < first.total {
            offsets.append(cursor)
            cursor += pageSize
        }

        let parallel = 5
        var index = 0
        while index < offsets.count {
            try checkStop()
            let end = min(index + parallel, offsets.count)
            let chunk = Array(offsets[index..<end])
            let pages: [Server.AlbumPage] = await withTaskGroup(of: Server.AlbumPage?.self) { group in
                for offset in chunk {
                    group.addTask {
                        try? await server.photos(album: album, offset: offset, cookie: cookie)
                    }
                }
                var collected: [Server.AlbumPage] = []
                for await page in group {
                    if let page { collected.append(page) }
                }
                return collected
            }
            for page in pages {
                for item in page.photos where seen.insert(item.name).inserted {
                    result.append((item.name, item.kind))
                }
            }
            index = end
        }
        return result
    }

    /// 同步下载的中转目录（不参与 iCloud 备份）。
    private func stagingDirectory() throws -> URL {
        let folder = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SyncDownloads", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        var excluded = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        return folder
    }

    /// 用固定窗口并发查询服务器上已存在的文件名。
    /// 原来每个文件一次串行 exists，往返次数等于文件数；这里降到 ceil(N / parallel)，
    /// 对比阶段的主要提速点。
    @MainActor
    private func existingNames(server: Server, album: String, names: [String], cookie: String,
                               parallel: Int = 6,
                               progress: (Int, Int) -> Void) async throws -> Set<String> {
        guard !names.isEmpty else { return [] }

        var existing = Set<String>(minimumCapacity: names.count)
        var unconfirmed = 0
        let total = names.count
        var cursor = 0

        while cursor < total {
            if stopRequested { throw CancellationError() }
            let end = min(cursor + parallel, total)
            let chunk = Array(names[cursor..<end])

            let results: [(String, Bool?, String)] =
                await withTaskGroup(of: (String, Bool?, String).self) { group in
                    for name in chunk {
                        group.addTask {
                            do {
                                let hit = try await server.exists(album: album, name: name, cookie: cookie)
                                return (name, hit, "")
                            } catch {
                                return (name, nil, error.localizedDescription)
                            }
                        }
                    }
                    var collected: [(String, Bool?, String)] = []
                    collected.reserveCapacity(chunk.count)
                    for await item in group { collected.append(item) }
                    return collected
                }

            var chunkFailures = 0
            var firstMessage = ""
            for (name, hit, message) in results {
                if let hit {
                    if hit { existing.insert(name) }
                } else {
                    chunkFailures += 1
                    if firstMessage.isEmpty { firstMessage = message }
                }
            }
            unconfirmed += chunkFailures

            // 一批里大半都失败，基本可以断定网络或服务端出了问题，别再空转。
            if chunkFailures > chunk.count / 2 {
                throw AppError.message("查重失败 \(chunkFailures)/\(chunk.count)：\(firstMessage.isEmpty ? "未知错误" : firstMessage)")
            }

            cursor = end
            progress(cursor, total)
            try checkStop()
        }

        if unconfirmed > 0 {
            log("有 \(unconfirmed) 个文件查重未确认，已按「服务器没有」处理，交给上传接口确认")
        }
        return existing
    }

    private func checkStop() throws {
        if stopRequested { throw CancellationError() }
        // Do not begin exporting another original after entering the background.
        // Submitted URLSession file uploads may finish independently of the app.
        if UIApplication.shared.applicationState == .background {
            stopRequested = true
            throw CancellationError()
        }
    }

    private func endGrace() {
        if grace != .invalid { UIApplication.shared.endBackgroundTask(grace); grace = .invalid }
    }

    private func exportURL() throws -> URL {
        let folder = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingUploads", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var excluded = folder
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        return folder.appendingPathComponent(UUID().uuidString)
    }

    private func upload(_ request: URLRequest, file: URL, name: String, wifiOnly: Bool) async throws -> Bool {
        var request = request
        request.allowsCellularAccess = !wifiOnly
        return try await withCheckedThrowingContinuation { continuation in
            uploadContinuation = continuation
            responseBody = Data()
            UserDefaults.standard.set(file.path, forKey: pendingKey)
            UserDefaults.standard.set(name, forKey: pendingNameKey)
            let task = session.uploadTask(with: request, fromFile: file)
            task.taskDescription = name
            task.resume()
        }
    }

    private func cleanPending() {
        if let path = UserDefaults.standard.string(forKey: pendingKey) {
            // Never delete a path outside this app's staging directory.
            let expected = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PendingUploads").standardizedFileURL
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if url.deletingLastPathComponent() == expected { try? fileManager.removeItem(at: url) }
        }
        UserDefaults.standard.removeObject(forKey: pendingKey)
        UserDefaults.standard.removeObject(forKey: pendingNameKey)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if responseBody.count < 65536 { responseBody.append(data.prefix(65536 - responseBody.count)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress = totalBytesExpectedToSend > 0 ? Double(totalBytesSent) / Double(totalBytesExpectedToSend) : 0
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var result: Result<Bool, Error>
        if let error { result = .failure(error) }
        else if let response = task.response as? HTTPURLResponse,
                (200..<300).contains(response.statusCode) {
            // 2xx 即表示服务器已接收该文件。响应体只用来识别「服务器已存在此文件」，
            // 缺字段或空 body（例如 201 且无返回内容）不应判为失败。
            let json = (try? JSONSerialization.jsonObject(with: responseBody)) as? [String: Any]
            result = .success(json?["skipped"] as? Bool == true)
        } else {
            let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: responseBody.prefix(300), encoding: .utf8) ?? ""
            result = .failure(AppError.message("上传 HTTP \(code)：\(body.isEmpty ? "服务端未返回内容" : body)"))
        }
        cleanPending()
        responseBody = Data()
        if let continuation = uploadContinuation {
            uploadContinuation = nil
            continuation.resume(with: result)
        } else {
            running = false
            switch result {
            case .success: status = "上次已提交的文件上传完成；点击开始备份继续对比其他文件"
            case .failure(let error): status = "上次上传未完成：\(error.localizedDescription)。请手动重试"
            }
            log(status)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = backgroundCompletion
        backgroundCompletion = nil
        completion?()
    }
}

// MARK: - 文件夹镜像备份（手机文件夹 → 服务器「备份文件」根目录）

struct WatchedFolder: Codable, Identifiable, Equatable {
    var id: UUID
    var displayName: String
    var bookmark: Data
}

/// 以手机文件夹为准镜像到服务器备份根下的同名文件夹：
/// 缺失或大小变动的上传，服务器上比手机多的删除。可同时维护多个文件夹。
final class FolderBackupManager: ObservableObject {
    static let shared = FolderBackupManager()

    @Published var folders: [WatchedFolder] = [] {
        didSet { persist() }
    }
    @Published var running = false
    @Published var status = "添加手机文件夹后开始同步"
    @Published var logs: [String] = []
    @Published var uploaded = 0
    @Published var skipped = 0
    @Published var deleted = 0
    @Published var failed = 0
    @Published var progress: Double = 0
    /// 服务端没有 /api/upload-delete 时置位并持久化，之后不再尝试删除，只做增量上传。
    @Published var deletionUnavailable: Bool = UserDefaults.standard.bool(forKey: "folderDeletionUnavailable") {
        didSet { UserDefaults.standard.set(deletionUnavailable, forKey: "folderDeletionUnavailable") }
    }

    private let storeKey = "watchedFolders"
    private let fileManager = FileManager.default

    private init() { load() }

    func log(_ text: String) {
        logs.insert(text, at: 0)
        if logs.count > 200 { logs.removeLast() }
    }

    // MARK: 列表维护

    @discardableResult
    func addFolder(_ url: URL) -> Bool {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
            let name = url.lastPathComponent
            guard !folders.contains(where: { $0.displayName == name }) else {
                status = "「\(name)」已在列表里"
                return false
            }
            folders.append(WatchedFolder(id: UUID(), displayName: name, bookmark: data))
            status = "已添加：\(name)"
            return true
        } catch {
            status = "添加失败：\(error.localizedDescription)"
            log(status)
            return false
        }
    }

    func remove(_ id: UUID) {
        folders.removeAll { $0.id == id }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let saved = try? JSONDecoder().decode([WatchedFolder].self, from: data) else { return }
        folders = saved
    }

    // MARK: 同步

    @MainActor func startSync(address: String, password: String, wifiOnly: Bool) async {
        guard !running else { return }
        guard !folders.isEmpty else { status = "请先添加手机文件夹"; return }
        running = true
        uploaded = 0; skipped = 0; deleted = 0; failed = 0; progress = 0
        defer { running = false; progress = 0 }

        do {
            let server = try Server(address: address, wifiOnly: wifiOnly)
            let cookie = try await server.login(password: password)
            var deletionBlocked = false

            var index = 0
            for folder in folders {
                index += 1
                status = "同步 \(index)/\(folders.count)：\(folder.displayName)"
                do {
                    try await syncOne(folder, server: server, cookie: cookie)
                } catch {
                    failed += 1
                    log("失败 \(folder.displayName)：\(error.localizedDescription)")
                }
                progress = Double(index) / Double(folders.count)
            }

            var summary = "完成：上传 \(uploaded) · 跳过 \(skipped) · 失败 \(failed)"
            if !deletionUnavailable { summary += " · 删除 \(deleted)" }
            status = summary
            if deletionUnavailable {
                log("服务端没有删除接口，只同步新增与变动的文件（不会删除服务器已有内容）")
            }
        } catch {
            status = "同步中止：\(error.localizedDescription)"
            log(status)
        }
    }

    /// 同步单个文件夹。服务端不支持删除时只做增量上传。
    @MainActor
    private func syncOne(_ folder: WatchedFolder, server: Server, cookie: String) async throws {
        var stale = false
        let root = try URL(resolvingBookmarkData: folder.bookmark, options: [],
                           relativeTo: nil, bookmarkDataIsStale: &stale)
        guard root.startAccessingSecurityScopedResource() else {
            throw AppError.message("无法访问「\(folder.displayName)」，请重新添加该文件夹")
        }
        defer { root.stopAccessingSecurityScopedResource() }

        let local = try scanLocal(root: root)
        log("\(folder.displayName)：本地 \(local.count) 个文件")
        guard !local.isEmpty else {
            log("\(folder.displayName)：文件夹为空，跳过")
            return
        }

        // 远端根目录：不存在就新建（服务端会自动处理同名冲突）
        let wanted = PhotoLibrary.safeName(folder.displayName)
        let top = try await server.uploadContents(path: "", cookie: cookie)
        let remoteRoot: String
        if let existing = top.entries.first(where: { $0.name == wanted && $0.isDir }) {
            remoteRoot = existing.name
        } else {
            remoteRoot = try await server.createFolder(name: wanted, parent: "", cookie: cookie)
            log("新建服务器文件夹 /\(remoteRoot)")
        }

        let remote = try await scanRemote(server: server, root: remoteRoot, cookie: cookie)
        log("\(folder.displayName)：服务器已有 \(remote.count) 个条目")

        // 上传缺失的、或大小对不上的
        for item in local {
            let remoteDir = item.dirRelative.isEmpty ? remoteRoot : remoteRoot + "/" + item.dirRelative
            let remotePath = remoteRoot + "/" + item.relative
            if let existing = remote[remotePath], !existing.isDir,
               let size = existing.size, size == item.size {
                skipped += 1
                continue
            }
            do {
                try await server.uploadFile(path: remoteDir, name: item.name, fileURL: item.url,
                                            size: item.size, overwrite: true, cookie: cookie)
                uploaded += 1
                log("上传 \(item.relative)")
            } catch {
                failed += 1
                log("失败 \(item.relative)：\(error.localizedDescription)")
                if error is URLError || error.localizedDescription.contains("HTTP 401") { throw error }
            }
        }

        // 服务端没有删除接口时跳过清理，只保留增量上传
        guard !deletionUnavailable else { return }

        let localPaths = Set(local.map { remoteRoot + "/" + $0.relative })
        let extras = remote.filter { !localPaths.contains($0.key) }
            .sorted { $0.key.count > $1.key.count }
        for (path, _) in extras {
            do {
                if try await server.deleteUpload(path: path, cookie: cookie) {
                    deleted += 1
                    log("删除 \(path)")
                } else {
                    deletionUnavailable = true
                    log("服务端没有删除接口：本轮起只做增量同步，不再清理服务器文件")
                    return
                }
            } catch {
                failed += 1
                log("删除失败 \(path)：\(error.localizedDescription)")
            }
        }
    }

    struct LocalItem {
        let url: URL
        let relative: String
        let dirRelative: String
        let name: String
        let size: Int64
    }

    private func scanLocal(root: URL) throws -> [LocalItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        guard let en = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }

        let base = root.standardizedFileURL.path
        var items: [LocalItem] = []
        for case let url as URL in en {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base) else { continue }
            var relative = String(path.dropFirst(base.count))
            if relative.hasPrefix("/") { relative.removeFirst() }
            guard !relative.isEmpty else { continue }
            items.append(LocalItem(
                url: url,
                relative: relative,
                dirRelative: (relative as NSString).deletingLastPathComponent,
                name: url.lastPathComponent,
                size: Int64(values?.fileSize ?? 0)))
        }
        return items
    }

    private func scanRemote(server: Server, root: String,
                            cookie: String) async throws -> [String: Server.UploadEntry] {
        var result: [String: Server.UploadEntry] = [:]
        var queue: [String] = [root]
        var visited = 0
        while let dir = queue.popLast() {
            visited += 1
            if visited > 5000 { throw AppError.message("服务器目录过多，已中止") }
            let contents = try await server.uploadContents(path: dir, cookie: cookie)
            for entry in contents.entries {
                let relative = dir.isEmpty ? entry.name : "\(dir)/\(entry.name)"
                result[relative] = entry
                if entry.isDir { queue.append(relative) }
            }
        }
        return result
    }
}
