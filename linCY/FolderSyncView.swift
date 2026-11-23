import SwiftUI
import UniformTypeIdentifiers

struct FolderSyncView: View {
    let currentAddress: String
    let wifiOnly: Bool
    @StateObject private var manager = FolderSyncManager.shared
    @State private var edit: FolderSyncTask?
    @State private var adding = false
    @State private var showServer = false
    @State private var message = ""
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(manager.status)
                    if manager.running { ProgressView(value: manager.progress); Button("停止同步", role: .destructive) { manager.stop() } }
                    Text("新增 \(manager.totals.added) · 更新 \(manager.totals.updated) · 跳过 \(manager.totals.skipped) · 删除 \(manager.totals.deleted) · 失败 \(manager.totals.failed)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("服务器") {
                    ForEach(manager.endpoints) { endpoint in
                        VStack(alignment: .leading) { Text(endpoint.name); Text(endpoint.address).font(.caption).foregroundStyle(.secondary) }
                    }
                    Button("添加 / 更新服务器") { showServer = true }.disabled(manager.running || manager.preview != nil)
                    if !currentAddress.isEmpty {
                        Button("保存当前连接的服务器") {
                            do { _ = try manager.saveServer(name: "linCY", address: currentAddress,
                                password: Credentials.password(for: currentAddress), wifiOnly: wifiOnly); message = "已保存当前服务器" }
                            catch { message = error.localizedDescription }
                        }.disabled(manager.running || manager.preview != nil)
                    }
                }
                Section("同步任务") {
                    ForEach(manager.tasks) { task in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(task.name).font(.headline)
                            Text(task.direction.rawValue).font(.subheadline)
                            Text("手机：\(task.local.name)\n服务器：\(task.area)/\(task.remotePath)").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button(task.direction == .mirror ? "预览增量上传" : "开始合并下载") {
                                    if task.direction == .mirror { manager.prepare(task) } else { manager.download(task) }
                                }.buttonStyle(.borderedProminent)
                                Button("编辑 / 重新授权") { edit = task }.buttonStyle(.bordered)
                            }.disabled(manager.running || manager.preview != nil)
                        }.padding(.vertical, 4)
                    }.onDelete { offsets in for index in offsets { manager.removeTask(manager.tasks[index].id) } }
                    Button("新建同步任务") { adding = true }.disabled(manager.endpoints.isEmpty || manager.running || manager.preview != nil)
                }
                if !message.isEmpty { Section { Text(message).font(.footnote) } }
                Section {
                    Text("上传按相对路径、文件名和大小对比，确认后只上传新增或大小不同的文件；服务器额外内容保留。下载只合并，不删除手机文件。请保持 App 在前台，进入后台会停止后续步骤。")
                    Text("上传使用服务器“备份文件夹”，下载使用“下载文件夹”。这两个根目录相同时可准确按文件大小对比。同名同大小但内容不同会跳过。")
                }.font(.footnote)
                if !manager.logs.isEmpty {
                    Section("同步记录") {
                        ForEach(Array(manager.logs.enumerated()), id: \.offset) { _, log in Text(log).font(.caption).textSelection(.enabled) }
                    }
                }
            }.navigationTitle("文件夹同步")
                .sheet(isPresented: $showServer) { SyncServerEditor(manager: manager) }
                .sheet(isPresented: $adding) { SyncTaskEditor(manager: manager, original: nil) }
                .sheet(item: $edit) { task in SyncTaskEditor(manager: manager, original: task) }
                .sheet(item: $manager.preview) { preview in
                    MirrorPreviewView(manager: manager, preview: preview)
                }
        }.tabItem { Label("文件夹同步", systemImage: "folder.badge.gearshape") }
    }
}

private struct SyncServerEditor: View {
    @ObservedObject var manager: FolderSyncManager
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var password = ""
    @State private var wifiOnly = true
    @State private var error = ""
    var body: some View {
        NavigationStack {
            Form {
                TextField("服务器名称（Windows / 飞牛）", text: $name)
                TextField("http://192.168.1.10:8091", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                SecureField("手机传输访问密码（没有则留空）", text: $password)
                Toggle("仅 Wi-Fi", isOn: $wifiOnly)
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                Button("保存服务器") {
                    do { _ = try manager.saveServer(name: name, address: address, password: password, wifiOnly: wifiOnly); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }.navigationTitle("服务器设置").toolbar { Button("取消") { dismiss() } }
        }
    }
}

private struct SyncTaskEditor: View {
    @ObservedObject var manager: FolderSyncManager
    let original: FolderSyncTask?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var endpointID = UUID()
    @State private var direction: FolderDirection = .mirror
    @State private var local: FolderAuthorization?
    @State private var path = ""
    @State private var area = "download"
    @State private var sharedRoot = true
    @State private var picking = false
    @State private var pendingFolder: PickedFolder?
    @State private var authorizing = false
    @State private var selectionStatus = ""
    @State private var authorizationID = UUID()
    @State private var showSelectionError = false
    @State private var error = ""
    @State private var browsing = false
    @State private var children: [SyncEntry] = []
    @State private var browserPath = ""
    @State private var initialized = false
    var body: some View {
        NavigationStack {
            Form {
                Section("任务") {
                    TextField("任务名称", text: $name)
                    Picker("服务器", selection: $endpointID) { ForEach(manager.endpoints) { Text($0.name).tag($0.id) } }
                    Picker("方向", selection: $direction) { ForEach(FolderDirection.allCases) { Text($0.rawValue).tag($0) } }
                    Button(local == nil ? "选择手机文件夹" : "重新选择：\(local!.name)") {
                        error = ""; selectionStatus = ""; picking = true
                    }.disabled(authorizing)
                    if authorizing {
                        ProgressView("已选中，正在读取文件夹授权…")
                        Button("取消读取") { authorizationID = UUID(); authorizing = false; selectionStatus = "已取消读取，可重新选择" }
                    }
                    if !selectionStatus.isEmpty { Text(selectionStatus).font(.caption).textSelection(.enabled) }
                    if let local { Text("已获得目录授权：\(local.name)").font(.caption) }
                }
                Section("服务器目录") {
                    if direction == .mirror { Toggle("备份和下载根目录是同一个文件夹", isOn: $sharedRoot) }
                    TextField(direction == .mirror ? "目标相对目录，例如 iPhone/Documents" : "源文件或文件夹相对路径", text: $path)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("不会删除任意一端的额外文件。同名同大小跳过，大小不同覆盖。关闭“同一个文件夹”时，无法确认服务器大小的文件会保守重传。下载在所选手机目录中创建同名文件或文件夹。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(browsing ? "正在读取…" : "浏览服务器根目录") { browserPath = ""; browse("") }.disabled(browsing)
                    if !browserPath.isEmpty {
                        Text("当前 /\(browserPath)").font(.caption)
                        Button("使用此目录") { path = browserPath }
                        Button("上一级") { browse((browserPath as NSString).deletingLastPathComponent) }.disabled(browsing)
                    }
                    ForEach(children, id: \.path) { entry in
                        HStack {
                            Image(systemName: entry.kind == "dir" ? "folder" : "doc")
                            Text((entry.path as NSString).lastPathComponent)
                            Spacer()
                            if entry.kind == "dir" {
                                Button("进入") { browse(join(browserPath, entry.path)) }.buttonStyle(.bordered).disabled(browsing)
                            }
                            Button("选择") { path = join(browserPath, entry.path) }.buttonStyle(.bordered)
                        }
                    }
                }
                if !error.isEmpty { Section { Text(error).foregroundStyle(.red) } }
                Button("保存任务") { save() }.disabled(authorizing || picking)
            }.navigationTitle(original == nil ? "新建同步任务" : "编辑同步任务")
                .toolbar { Button("取消") { dismiss() } }
                .fileImporter(isPresented: $picking, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                    switch result {
                    case .success(let urls):
                        guard let url = urls.first else { selectionStatus = "未选择文件夹"; return }
                        // Retain the security scope from the moment the system hands the URL over.
                        pendingFolder = PickedFolder(url)
                        selectionStatus = "已收到系统选择结果"
                        authorizePickedFolder()
                    case .failure(let failure):
                        pendingFolder = nil
                        let nsError = failure as NSError
                        selectionStatus = "选择文件夹失败：\(nsError.localizedDescription)（\(nsError.domain) / \(nsError.code)）"
                    }
                }
                .alert("文件夹授权失败", isPresented: $showSelectionError) {
                    Button("好", role: .cancel) {}
                } message: { Text(error) }
                .onAppear {
                    guard !initialized else { return }
                    initialized = true
                    endpointID = original?.endpointID ?? manager.endpoints.first?.id ?? UUID()
                    if let original {
                        name = original.name; direction = original.direction; local = original.local
                        path = original.remotePath; area = original.area; sharedRoot = original.sharedRoot
                    }
                }
        }
    }
    private func authorizePickedFolder() {
        guard let selected = pendingFolder else { return }
        pendingFolder = nil
        let requestID = UUID()
        authorizationID = requestID
        authorizing = true
        selectionStatus = "已选中：\(selected.url.lastPathComponent)，正在验证读取权限"
        Task { @MainActor in
            // Let the dismissal finish before contacting a file provider. Retaining
            // `selected` holds its original security scope throughout this operation.
            do {
                let authorization = try await Task.detached(priority: .userInitiated) {
                    try FolderAuthorization.capture(selected.url)
                }.value
                guard authorizationID == requestID else { return }
                local = authorization
                if path.isEmpty { path = authorization.name }
                if name.isEmpty { name = authorization.name }
                error = ""
                selectionStatus = "已获得授权：\(authorization.name)"
            } catch {
                guard authorizationID == requestID else { return }
                let failure = error as NSError
                self.error = "无法读取文件夹：\(failure.localizedDescription)\n错误：\(failure.domain) / \(failure.code)\n请重新选择“我的 iPhone”内可读取的文件夹。"
                selectionStatus = "系统已返回选择结果，但授权验证失败"
                showSelectionError = true
            }
            if authorizationID == requestID { authorizing = false }
            withExtendedLifetime(selected) {}
        }
    }
    private func join(_ base: String, _ child: String) -> String { base.isEmpty ? child : base + "/" + child }
    private func browse(_ target: String) {
        browsing = true; error = ""
        Task {
            defer { browsing = false }
            do {
                let manifest = try await manager.browse(endpointID: endpointID, area: direction == .mirror ? "upload" : area, path: target)
                guard manifest.kind == "dir" else { throw AppError.message("不是服务器文件夹") }
                browserPath = target
                children = manifest.entries.filter { !$0.path.isEmpty && !$0.path.contains("/") }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func save() {
        do {
            guard let local else { throw AppError.message("请先选择手机文件夹") }
            let task = FolderSyncTask(id: original?.id ?? UUID(), name: name.isEmpty ? local.name : name,
                endpointID: endpointID, direction: direction, local: local, remotePath: path,
                area: direction == .mirror ? "upload" : "download", sharedRoot: sharedRoot)
            try manager.saveTask(task); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct MirrorPreviewView: View {
    @ObservedObject var manager: FolderSyncManager
    let preview: MirrorPreview
    @State private var confirm = false
    var body: some View {
        NavigationStack {
            List {
                Section("差异预览") {
                    Text("服务器目标：\(preview.task.remotePath)")
                    Text("新增 \(preview.diff.added) · 更新 \(preview.diff.updated) · 跳过 \(preview.diff.skipped) · 删除 \(preview.diff.deleted)")
                    if preview.local.isEmpty { Text("手机源文件夹为空，只确认 / 创建同名服务器目录，不删除服务器已有内容。")
                        .foregroundStyle(.red) }
                    Button("确认增量上传") { confirm = true }
                    Button("取消") { manager.cancelPreview() }
                }
                let old = Dictionary(uniqueKeysWithValues: preview.remote.map { ($0.path, $0) })
                let new = Dictionary(uniqueKeysWithValues: preview.local.map { ($0.path, $0) })
                Section("新增 / 更新") {
                    ForEach(preview.local.filter { old[$0.path] == nil || old[$0.path]?.kind != $0.kind || ($0.kind == "file" && old[$0.path]?.size != $0.size) }, id: \.path) { entry in
                        Text((old[entry.path] == nil ? "新增 " : "更新 ") + entry.path).font(.caption)
                    }
                }
                Section("服务器额外内容（保留，不删除）") {
                    ForEach(preview.remote.filter { new[$0.path] == nil }, id: \.path) { entry in
                        Text(entry.path).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.navigationTitle("确认同步范围")
                .interactiveDismissDisabled()
                .confirmationDialog("上传新增和大小不同的文件？", isPresented: $confirm, titleVisibility: .visible) {
                    Button("开始增量上传") { manager.confirmMirror() }
                    Button("取消", role: .cancel) {}
                } message: { Text("仅上传到 \(preview.task.remotePath)，不删除服务器已有内容。") }
        }
    }
}
