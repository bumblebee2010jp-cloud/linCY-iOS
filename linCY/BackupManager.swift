import UIKit
import Photos
import SwiftUI

// Main-thread state; URLSession delegates are delivered on OperationQueue.main.
final class BackupManager: NSObject, ObservableObject, URLSessionDataDelegate {
    static let shared = BackupManager()
    static let sessionID = "com.lincy.ios.album-upload"
    @Published var albums: [PhoneAlbum] = []
    @Published var selected = Set(UserDefaults.standard.stringArray(forKey: "selectedAlbums") ?? []) {
        didSet { UserDefaults.standard.set(Array(selected), forKey: "selectedAlbums") }
    }
    @Published var running = false
    @Published var restoring = true
    @Published var status = "选择相册后，点击开始备份"
    @Published var logs: [String] = []
    @Published var uploaded = 0
    @Published var skipped = 0
    @Published var failed = 0
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
            if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited {
                status = "当前仅能备份你授权的部分照片；如需完整相册，请在系统设置允许所有照片"
            }
        } catch { status = error.localizedDescription }
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
                let assets = PHAsset.fetchAssets(in: album.collection, options: PhotoLibrary.options())
                var counts: [String: Int] = [:]
                assets.enumerateObjects { asset, _, _ in
                    for resource in PhotoLibrary.resources(asset) {
                        let name = PhotoLibrary.resourceName(resource, asset: asset, duplicated: false).lowercased()
                        counts[name, default: 0] += 1
                    }
                }
                for index in 0..<assets.count {
                    try checkStop()
                    let asset = assets.object(at: index)
                    for resource in PhotoLibrary.resources(asset) {
                        try checkStop()
                        let plain = PhotoLibrary.resourceName(resource, asset: asset, duplicated: false)
                        let name = PhotoLibrary.resourceName(resource, asset: asset,
                            duplicated: (counts[plain.lowercased()] ?? 0) > 1)
                        do {
                            if try await server.exists(album: folder, name: name, cookie: cookie) {
                                skipped += 1
                                continue
                            }
                            status = "正在备份 \(album.title)：\(name)"
                            let temp = try exportURL()
                            defer { try? fileManager.removeItem(at: temp) }
                            try await PhotoLibrary.export(resource, to: temp)
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
            }
            status = "本轮完成：上传 \(uploaded)，已有跳过 \(skipped)，失败 \(failed)"
        } catch is CancellationError {
            status = "已停止；下次点击开始备份会重新对比并补传"
        } catch {
            status = "本轮中止：\(error.localizedDescription)。修复后点击开始备份重试"
            log(status)
        }
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
                [200, 201].contains(response.statusCode),
                let json = (try? JSONSerialization.jsonObject(with: responseBody)) as? [String: Any],
                json["name"] is String, json["size"] is NSNumber || json["skipped"] as? Bool == true {
            result = .success(json["skipped"] as? Bool == true)
        } else {
            let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            result = .failure(AppError.message("上传 HTTP \(code)：\(String(data: responseBody.prefix(300), encoding: .utf8) ?? "响应无效")"))
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
