import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum AlbumSource: String, CaseIterable, Identifiable {
    case local = "本机相册"
    case remote = "服务器相册"
    var id: String { rawValue }
}

enum SyncRequest: Identifiable {
    case albums([String])

    var targets: [String] {
        switch self {
        case .albums(let list): return list
        }
    }

    var id: String { targets.joined(separator: "|") }

    var title: String {
        let list = targets
        return list.count == 1
            ? "同步「\(list[0])」到手机相册？"
            : "同步选中的 \(list.count) 个相册？"
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions:
        [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = BackupManager.shared
        _ = FolderBackupManager.shared
        return true
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackupManager.sessionID else { completionHandler(); return }
        BackupManager.shared.backgroundCompletion = completionHandler
    }
}

@main
struct LinCYApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
    @StateObject private var backup = BackupManager.shared
    @AppStorage("serverAddress") private var address = ""
    @AppStorage("wifiOnly") private var wifiOnly = true
    @State private var draft = ""
    @State private var password = ""
    @State private var showHiddenAlbums = false
    @State private var albumSource: AlbumSource = .local
    @State private var syncRequest: SyncRequest?
    @State private var selectedRemote: Set<String> = []
    @State private var connectionStatus = ""
    @State private var connecting = false
    @State private var webToken = UUID()
    @State private var webCookie: String?

    var body: some View {
        TabView {
            webTab
            albumTab
            FolderBackupView()
                .tabItem { Label("文件夹备份", systemImage: "folder") }
            connectionTab
        }
        .task { await restore() }
    }

    // MARK: - 原版功能

    private var webTab: some View {
        NavigationStack {
            webContent
        }
        .tabItem { Label("原版功能", systemImage: "globe") }
    }

    @ViewBuilder
    private var webContent: some View {
        if address.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "network").font(.largeTitle)
                Text("先在“连接”页面填写电脑上的 linCY 访问地址")
                    .multilineTextAlignment(.center)
            }
            .padding()
        } else if let url = URL(string: address) {
            WebScreen(url: url, cookie: webCookie)
                .id(webToken)
                .navigationTitle("linCY")
                .navigationBarTitleDisplayMode(.inline)
        } else {
            Text("地址无效，请到「连接」页重新填写").padding()
        }
    }

    // MARK: - 相册备份

    private var albumTab: some View {
        NavigationStack {
            List {
                summarySection
                sourceSection
                if albumSource == .local {
                    localAlbumsSection
                } else {
                    remoteAlbumsSection
                }
                logsSection
            }
            .navigationTitle("相册备份")
            .onChange(of: albumSource) { source in
                guard source == .remote, backup.remoteAlbums.isEmpty,
                      !address.isEmpty, !backup.loadingRemote, !backup.running else { return }
                Task { await loadRemoteAlbums() }
            }
            .confirmationDialog(
                syncRequest?.title ?? "",
                isPresented: Binding(
                    get: { syncRequest != nil },
                    set: { if !$0 { syncRequest = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("开始同步") {
                    guard let request = syncRequest else { return }
                    Task { await syncSelected(request.targets) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("对比服务器与手机相册，只下载手机里没有的文件；手机上缺的同名相册会自动新建。")
            }
        }
        .tabItem { Label("相册备份", systemImage: "photo.on.rectangle.angled") }
    }

    @ViewBuilder
    private var summarySection: some View {
        Section {
            Text(backup.status)
            if backup.running {
                ProgressView(value: backup.progress)
            }
            Text("上传 \(backup.uploaded) · 下载 \(backup.downloaded) · 已有 \(backup.skipped) · 失败 \(backup.failed)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if backup.running {
                Button("停止当前任务") { backup.stop() }
            } else {
                Button {
                    Task { await startBackup() }
                } label: {
                    Label("开始备份", systemImage: "icloud.and.arrow.up")
                }
                .disabled(address.isEmpty || backup.selected.isEmpty || backup.restoring)
            }
        } footer: {
            Text("备份是手机 → 服务器：对比同名文件夹，缺少则新建，按文件名跳过已有文件，不覆盖、不删除。同步是服务器 → 手机：切到下方「服务器相册」勾选后下载缺失文件。")
        }
    }

    private var sourceSection: some View {
        Section {
            Picker("相册来源", selection: $albumSource) {
                ForEach(AlbumSource.allCases) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var localAlbumsSection: some View {
        Section {
            Button("读取 / 刷新手机相册") {
                Task { await backup.loadAlbums() }
            }
            .disabled(backup.running)
            ForEach(visibleAlbums) { album in
                albumRow(album)
                    .contextMenu {
                        Button(role: .destructive) {
                            backup.hide(album.id)
                        } label: {
                            Label("隐藏此相册", systemImage: "eye.slash")
                        }
                    }
            }
            if !hiddenAlbums.isEmpty {
                DisclosureGroup(isExpanded: $showHiddenAlbums) {
                    ForEach(hiddenAlbums) { album in
                        albumRow(album)
                            .contextMenu {
                                Button {
                                    backup.unhide(album.id)
                                } label: {
                                    Label("取消隐藏", systemImage: "eye")
                                }
                            }
                    }
                } label: {
                    Label("已隐藏相册（\(hiddenAlbums.count)）", systemImage: "eye.slash")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("本机相册（\(visibleAlbums.count)）")
        } footer: {
            Text("长按相册可隐藏，隐藏的相册会移到底部「已隐藏相册」并取消勾选；需要时展开即可恢复。")
        }
    }

    @ViewBuilder
    private var remoteAlbumsSection: some View {
        Section {
            if backup.loadingRemote {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在读取服务器相册…").foregroundStyle(.secondary)
                }
            } else if backup.remoteAlbums.isEmpty {
                Text("还没有读取。点右上角「读取 / 刷新」。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                remoteAlbumRows
                remoteActions
            }
        } header: {
            HStack {
                Text("服务器相册（\(backup.remoteAlbums.count)）")
                Spacer()
                Button {
                    Task { await loadRemoteAlbums() }
                } label: {
                    Text(backup.loadingRemote ? "读取中…" : "读取 / 刷新")
                        .font(.footnote)
                }
                .disabled(backup.running || backup.loadingRemote)
            }
        } footer: {
            Text("勾选后点「同步选中」，或直接「同步全部」。手机上没有的同名相册会新建，只下载缺失文件；与已隐藏手机相册同名的会跳过。")
        }
    }

    private var remoteAlbumRows: some View {
        ForEach(backup.remoteAlbums, id: \.self) { name in
            Button {
                toggleRemote(name)
            } label: {
                HStack {
                    Image(systemName: selectedRemote.contains(name)
                          ? "checkmark.circle.fill" : "circle")
                    Text(name).foregroundStyle(.primary).lineLimit(1)
                    Spacer()
                }
            }
            .disabled(backup.running || backup.restoring)
        }
    }

    @ViewBuilder
    private var remoteActions: some View {
        HStack {
            Button {
                syncRequest = .albums(Array(selectedRemote).sorted())
            } label: {
                Label("同步选中（\(selectedRemote.count)）", systemImage: "arrow.down.circle")
            }
            .disabled(selectedRemote.isEmpty || backup.running || backup.restoring)
            Spacer()
            Button(allRemoteSelected ? "取消全选" : "全选") {
                toggleAllRemote()
            }
            .disabled(backup.running)
        }
        Button {
            syncRequest = .albums(backup.remoteAlbums)
        } label: {
            Label("同步全部（\(backup.remoteAlbums.count) 个相册）",
                  systemImage: "arrow.down.circle.fill")
        }
        .disabled(backup.running || backup.restoring)
    }

    @ViewBuilder
    private var logsSection: some View {
        if !backup.logs.isEmpty {
            Section("本次记录") {
                ForEach(Array(backup.logs.enumerated()), id: \.offset) { _, text in
                    Text(text).font(.caption).textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - 连接

    private var connectionTab: some View {
        NavigationStack {
            Form {
                connectionFields
                connectionHelp
            }
            .navigationTitle("连接")
        }
        .tabItem { Label("连接", systemImage: "gearshape") }
    }

    private var connectionFields: some View {
        Section("电脑上的 linCY 服务") {
            TextField("http://192.168.1.10:8091", text: $draft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            SecureField("访问密码（未设置则留空）", text: $password)
            Toggle("备份仅使用 Wi-Fi", isOn: $wifiOnly)
                .disabled(backup.running)
            Button(connecting ? "正在连接…" : "连接并保存") {
                Task { await connect() }
            }
            .disabled(connecting || backup.running)
            if !connectionStatus.isEmpty {
                Text(connectionStatus).font(.footnote)
            }
        }
    }

    private var connectionHelp: some View {
        Section {
            Text("填写服务端“手机传输”的访问地址，默认端口 8091。手机需能访问电脑，服务端需保持开启。相册备份写入“相册备份文件夹”，文件夹备份写入“备份文件”根目录。")
            Text("相册内容只在你点击备份后上传。Live Photo 会分别备份原始照片与视频；仅 iCloud 中的原件会先下载。后台只尝试完成已提交的上传，其余内容下次手动继续。")
            Button("打开系统权限设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
        .font(.footnote)
    }

    // MARK: - 数据

    private var visibleAlbums: [PhoneAlbum] {
        backup.albums.filter { !backup.hidden.contains($0.id) }
    }

    private var hiddenAlbums: [PhoneAlbum] {
        backup.albums.filter { backup.hidden.contains($0.id) }
    }

    private var allRemoteSelected: Bool {
        !backup.remoteAlbums.isEmpty && selectedRemote.count == backup.remoteAlbums.count
    }

    @ViewBuilder
    private func albumRow(_ album: PhoneAlbum) -> some View {
        Button {
            if backup.selected.contains(album.id) { backup.selected.remove(album.id) }
            else { backup.selected.insert(album.id) }
        } label: {
            HStack {
                Image(systemName: backup.selected.contains(album.id) ? "checkmark.circle.fill" : "circle")
                Text(album.title).foregroundStyle(.primary)
                Spacer()
                Text("\(album.count)").foregroundStyle(.secondary)
            }
        }
        .disabled(backup.running)
    }

    // MARK: - 动作

    private func toggleRemote(_ name: String) {
        if selectedRemote.contains(name) { selectedRemote.remove(name) }
        else { selectedRemote.insert(name) }
    }

    private func toggleAllRemote() {
        if allRemoteSelected { selectedRemote.removeAll() }
        else { selectedRemote = Set(backup.remoteAlbums) }
    }

    @MainActor
    private func restore() async {
        draft = address
        password = Credentials.password(for: address)
        // 读取记住的选择，但启动时绝不自动开始上传。
        if !backup.selected.isEmpty { await backup.loadAlbums() }
    }

    @MainActor
    private func startBackup() async {
        await backup.start(address: address,
            password: Credentials.password(for: address), wifiOnly: wifiOnly)
    }

    @MainActor
    private func loadRemoteAlbums() async {
        await backup.loadRemoteAlbums(address: address,
            password: Credentials.password(for: address), wifiOnly: wifiOnly)
    }

    @MainActor
    private func syncSelected(_ targets: [String]) async {
        await backup.syncAlbums(targets, address: address,
            password: Credentials.password(for: address), wifiOnly: wifiOnly)
    }

    @MainActor
    private func connect() async {
        connecting = true
        defer { connecting = false }
        do {
            let server = try Server(address: draft, wifiOnly: wifiOnly)
            let cookie = try await server.login(password: password)
            _ = try await server.albums(cookie: cookie)
            try Credentials.save(password, for: server.base.absoluteString)
            address = server.base.absoluteString
            draft = address
            webCookie = cookie
            webToken = UUID()
            connectionStatus = "连接成功，已保存"
        } catch {
            connectionStatus = error.localizedDescription
        }
    }
}

// MARK: - 文件夹备份

struct FolderBackupView: View {
    @StateObject private var manager = FolderBackupManager.shared
    @AppStorage("serverAddress") private var address = ""
    @AppStorage("wifiOnly") private var wifiOnly = true
    @State private var showPicker = false

    var body: some View {
        NavigationStack {
            List {
                statusSection
                folderListSection
                logsSection
            }
            .navigationTitle("文件夹备份")
            .sheet(isPresented: $showPicker) {
                FolderPicker { url in
                    _ = manager.addFolder(url)
                }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            Text(manager.status)
            if manager.running {
                ProgressView(value: manager.progress)
            }
            Text("上传 \(manager.uploaded) · 跳过 \(manager.skipped) · 失败 \(manager.failed)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if manager.running {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在同步，请保持此页在前台")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    Task { await start() }
                } label: {
                    Label("开始同步", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(address.isEmpty || manager.folders.isEmpty)
            }
        } footer: {
            Text("以手机文件夹为准，把内容（含所有子文件夹）上传到服务器「备份文件」根目录下的同名文件夹，服务器没有就新建。大小没变化的文件会跳过。")
        }
    }

    @ViewBuilder
    private var folderListSection: some View {
        Section {
            Button {
                showPicker = true
            } label: {
                Label("添加手机文件夹", systemImage: "folder.badge.plus")
            }
            .disabled(manager.running)
            ForEach(manager.folders) { folder in
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill").foregroundStyle(.tint)
                    Text(folder.displayName)
                    Spacer()
                }
                .contextMenu {
                    Button(role: .destructive) {
                        manager.remove(folder.id)
                    } label: {
                        Label("移除", systemImage: "trash")
                    }
                }
            }
        } header: {
            Text("手机文件夹（\(manager.folders.count)）")
        } footer: {
            Text("可添加多个文件夹，长按可移除。移除只取消同步，不会删除手机或服务器上的文件。")
        }
    }

    @ViewBuilder
    private var logsSection: some View {
        if !manager.logs.isEmpty {
            Section("本次记录") {
                ForEach(Array(manager.logs.enumerated()), id: \.offset) { _, text in
                    Text(text).font(.caption).textSelection(.enabled)
                }
            }
        }
    }

    @MainActor
    private func start() async {
        await manager.startSync(address: address,
            password: Credentials.password(for: address), wifiOnly: wifiOnly)
    }
}

// MARK: - 系统文件夹选择器

/// iOS 只能选文件夹，返回 security-scoped URL，由 FolderBackupManager 转成 bookmark 长期访问。
struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: FolderPicker
        init(_ parent: FolderPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { parent.onPick(url) }
            parent.dismiss()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.dismiss()
        }
    }
}
