import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum AlbumSource: String, CaseIterable, Identifiable {
    case local = "本机相册"
    case remote = "服务器相册"
    var id: String { rawValue }
}

enum AppInfo {
    /// CI 会用 tag 覆盖 Info.plist 的版本号，便于区分每一版安装包。
    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
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
    @AppStorage("albumCollectionDisplayMode") private var albumLayout = AlbumDisplayMode.list.rawValue
    @AppStorage("hiddenRemoteAlbumsByServer") private var remoteHiddenStorage = "{}"
    @State private var showHiddenRemote = false
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
                if backup.scanning || !backup.conflicts.isEmpty { conflictsSection }
                sourceSection
                if albumSource == .local {
                    localAlbumsSection
                } else {
                    remoteAlbumsSection
                }
                logsSection
            }
            .navigationTitle("相册备份")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { AlbumLayoutMenu(mode: $albumLayout) }
            }
            .onChange(of: address) { _ in
                selectedRemote.removeAll(); backup.remoteAlbums = []; showHiddenRemote = false
            }
            .onChange(of: albumSource) { source in
                guard source == .remote, backup.remoteAlbums.isEmpty,
                      !address.isEmpty, !backup.loadingRemote, !busy else { return }
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
        .id(address)
        .tabItem { Label("相册备份", systemImage: "photo.on.rectangle.angled") }
    }

    @ViewBuilder
    private var summarySection: some View {
        Section {
            Text(backup.status)
            if backup.running { ProgressView(value: backup.progress) }
            Text("上传 \(backup.uploaded) · 下载 \(backup.downloaded) · 已有 \(backup.skipped) · 失败 \(backup.failed)")
                .font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                HStack(spacing: 0) {
                    Button("开始备份") { Task { await startBackup() } }
                        .font(.subheadline).buttonStyle(.borderless)
                        .disabled(address.isEmpty || backup.selected.isEmpty || busy)
                    AlbumInfoButton(title: "开始备份", message: "备份是手机 → 服务器：处理全部勾选的手机相册，对比同名文件夹，缺少则新建，按文件名跳过已有文件，不覆盖、不删除。Live Photo 会分别备份照片和视频；iCloud 原件可能需要先下载。")
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 0) {
                    Button(backup.scanning ? "正在检查…" : "检查同名大小") { Task { await scanConflicts() } }
                        .font(.subheadline).buttonStyle(.borderless)
                        .disabled(address.isEmpty || backup.selected.isEmpty || busy)
                    AlbumInfoButton(title: "检查同名大小", message: "检查全部勾选的手机相册：只对服务器已有的同名文件逐张导出并比较大小，比较慢、可停止，不修改任何文件。列出的文件备份时仍按同名跳过；需要更新请先在服务器删除对应文件。")
                }.frame(maxWidth: .infinity, alignment: .trailing)
            }
            if backup.running { Button("停止当前任务") { backup.stop() } }
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
            Button("读取 / 刷新手机相册") { Task { await backup.loadAlbums() } }.disabled(busy)
            if display == .list {
                ForEach(visibleAlbums) { album in localAlbumCell(album, grid: false) }
            } else {
                LazyVGrid(columns: display.grid, spacing: 12) {
                    ForEach(visibleAlbums) { album in localAlbumCell(album, grid: true) }
                }.padding(.vertical, 6)
            }
            if !hiddenAlbums.isEmpty {
                DisclosureGroup(isExpanded: $showHiddenAlbums) {
                    ForEach(hiddenAlbums) { album in localAlbumCell(album, grid: false) }
                } label: {
                    Label("已隐藏相册（\(hiddenAlbums.count)）", systemImage: "eye.slash").foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack {
                Text("本机相册（\(visibleAlbums.count)）")
                AlbumInfoButton(title: "手机相册", message: "圆圈用于勾选备份或检查的相册；点击相册名称/封面进入预览。长按可隐藏，隐藏后取消勾选并移到底部；展开已隐藏相册可取消隐藏。预览照片时不需要勾选。")
            }
        }
    }

    @ViewBuilder
    private var remoteAlbumsSection: some View {
        Section {
            if backup.loadingRemote {
                HStack { ProgressView(); Text("正在读取服务器相册…").foregroundStyle(.secondary) }
            } else if backup.remoteAlbums.isEmpty {
                Text("还没有读取。点右上角「读取 / 刷新」。").font(.footnote).foregroundStyle(.secondary)
            } else {
                if display == .list {
                    ForEach(visibleRemoteAlbums, id: \.self) { remoteAlbumCell($0, grid: false) }
                } else {
                    LazyVGrid(columns: display.grid, spacing: 12) {
                        ForEach(visibleRemoteAlbums, id: \.self) { remoteAlbumCell($0, grid: true) }
                    }.padding(.vertical, 6)
                }
                if !hiddenRemoteAlbums.isEmpty {
                    DisclosureGroup(isExpanded: $showHiddenRemote) {
                        ForEach(hiddenRemoteAlbums, id: \.self) { remoteAlbumCell($0, grid: false) }
                    } label: {
                        Label("已隐藏相册（\(hiddenRemoteAlbums.count)）", systemImage: "eye.slash").foregroundStyle(.secondary)
                    }
                }
                remoteActions
            }
        } header: {
            HStack {
                Text("服务器相册（\(visibleRemoteAlbums.count)）")
                AlbumInfoButton(title: "服务器相册", message: "点击名称预览照片和视频，圆圈用于勾选同步相册。长按可隐藏/取消隐藏；隐藏状态按服务器地址保存，不删除服务器文件。隐藏后取消勾选，并从全选、同步选中和同步全部中排除。")
                Spacer()
                Button(backup.loadingRemote ? "读取中…" : "读取 / 刷新") { Task { await loadRemoteAlbums() } }
                    .font(.footnote).disabled(busy || backup.loadingRemote || address.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func localAlbumCell(_ album: PhoneAlbum, grid: Bool) -> some View {
        Group {
            if grid {
                VStack(alignment: .leading, spacing: 5) {
                    NavigationLink {
                        LocalAlbumBrowser(album: album)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            LocalAlbumCover(album: album).aspectRatio(1, contentMode: .fit).cornerRadius(8)
                            Text(album.title).font(.caption).lineLimit(2)
                            Text("\(album.count) 项").font(.caption2).foregroundStyle(.secondary)
                        }.foregroundStyle(.primary)
                    }.buttonStyle(.plain)
                    localSelectionButton(album)
                }
            } else {
                HStack {
                    localSelectionButton(album)
                    NavigationLink {
                        LocalAlbumBrowser(album: album)
                    } label: {
                        HStack { Text(album.title).lineLimit(2); Spacer(); Text("\(album.count)").foregroundStyle(.secondary) }
                    }
                }
            }
        }.contextMenu {
            if backup.hidden.contains(album.id) {
                Button { backup.unhide(album.id) } label: { Label("取消隐藏", systemImage: "eye") }.disabled(busy)
            } else {
                Button { backup.hide(album.id) } label: { Label("隐藏此相册", systemImage: "eye.slash") }.disabled(busy)
            }
        }
    }

    private func localSelectionButton(_ album: PhoneAlbum) -> some View {
        Button {
            if backup.selected.contains(album.id) { backup.selected.remove(album.id) }
            else { backup.selected.insert(album.id) }
        } label: {
            Image(systemName: backup.selected.contains(album.id) ? "checkmark.circle.fill" : "circle")
                .font(.title3).frame(minWidth: 36, minHeight: 40)
        }
        .buttonStyle(.borderless).disabled(busy || backup.hidden.contains(album.id))
        .accessibilityLabel((backup.selected.contains(album.id) ? "取消勾选" : "勾选") + album.title)
    }

    @ViewBuilder
    private func remoteAlbumCell(_ name: String, grid: Bool) -> some View {
        Group {
            if grid {
                VStack(alignment: .leading, spacing: 5) {
                    NavigationLink {
                        RemoteAlbumBrowser(album: name, address: address, wifiOnly: wifiOnly)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Image(systemName: "photo.on.rectangle.angled").resizable().scaledToFit()
                                .padding(16).frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
                                .background(Color.secondary.opacity(0.1)).cornerRadius(8)
                            Text(name.isEmpty ? "根目录" : name).font(.caption).lineLimit(2)
                        }.foregroundStyle(.primary)
                    }.buttonStyle(.plain)
                    remoteSelectionButton(name)
                }
            } else {
                HStack {
                    remoteSelectionButton(name)
                    NavigationLink {
                        RemoteAlbumBrowser(album: name, address: address, wifiOnly: wifiOnly)
                    } label: { Text(name.isEmpty ? "根目录" : name).lineLimit(2) }
                }
            }
        }.contextMenu {
            if remoteHidden.contains(name) {
                Button { setRemoteHidden(name, hidden: false) } label: { Label("取消隐藏", systemImage: "eye") }.disabled(busy)
            } else {
                Button { setRemoteHidden(name, hidden: true) } label: { Label("隐藏此相册", systemImage: "eye.slash") }.disabled(busy)
            }
        }
    }

    private func remoteSelectionButton(_ name: String) -> some View {
        Button { toggleRemote(name) } label: {
            Image(systemName: selectedRemote.contains(name) ? "checkmark.circle.fill" : "circle")
                .font(.title3).frame(minWidth: 36, minHeight: 40)
        }.buttonStyle(.borderless).disabled(busy || remoteHidden.contains(name))
        .accessibilityLabel((selectedRemote.contains(name) ? "取消勾选" : "勾选") + name)
    }

    @ViewBuilder
    private var remoteActions: some View {
        HStack {
            Button { syncRequest = .albums(remoteSyncTargets) } label: {
                Label("同步选中（\(remoteSyncTargets.count)）", systemImage: "arrow.down.circle")
            }.buttonStyle(.borderless).disabled(remoteSyncTargets.isEmpty || busy)
            AlbumInfoButton(title: "同步服务器相册", message: "同步是服务器 → 手机：同步全部勾选的相册，手机没有的同名相册会新建，只下载缺失文件。与已隐藏手机相册同名的会跳过；已隐藏服务器相册也不会参与同步。同步全部只处理未隐藏的服务器相册。")
        }
        Button { toggleAllRemote() } label: {
            Label(allRemoteSelected ? "取消全选" : "全选", systemImage: "checklist")
        }.disabled(visibleRemoteAlbums.isEmpty || busy)
        Button { syncRequest = .albums(visibleRemoteAlbums) } label: {
            Label("同步全部（\(visibleRemoteAlbums.count) 个相册）", systemImage: "arrow.down.circle.fill")
        }.disabled(visibleRemoteAlbums.isEmpty || busy)
    }

    /// 同名不同大小检查：手动触发，逐张导出比对，只读不改。
    @ViewBuilder
    private var conflictsSection: some View {
        Section {
            if backup.scanning {
                ProgressView(value: backup.scanProgress)
                Button("停止检查") { backup.stop() }
            }

            ForEach(backup.conflicts) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.footnote)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Text("\(item.album) · 本地 \(sizeText(item.localSize)) / 服务器 \(sizeText(item.remoteSize))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if !backup.conflicts.isEmpty {
                Button {
                    UIPasteboard.general.string = conflictReport
                } label: {
                    Label("复制清单（\(backup.conflicts.count) 条）", systemImage: "doc.on.doc")
                }
            }
        } header: {
            Text(backup.conflicts.isEmpty ? "同名未覆盖" : "同名未覆盖（\(backup.conflicts.count)）")
        }
    }

    private var conflictReport: String {
        backup.conflicts
            .map { "\($0.album)\t\($0.name)\t\($0.localSize)\t\($0.remoteSize)" }
            .joined(separator: "\n")
    }

    private func sizeText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    @MainActor
    private func scanConflicts() async {
        await backup.scanConflicts(address: address,
            password: Credentials.password(for: address), wifiOnly: wifiOnly)
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
            .disabled(connecting || busy)
            if !connectionStatus.isEmpty {
                Text(connectionStatus).font(.footnote)
            }
        }
    }

    private var connectionHelp: some View {
        Section {
            Text("填写服务端“手机传输”的访问地址，默认端口 8091。手机需能访问电脑，服务端需保持开启。相册备份写入“相册备份文件夹”。")
            Text("相册内容只在你点击备份后上传。Live Photo 会分别备份原始照片与视频；仅 iCloud 中的原件会先下载。后台只尝试完成已提交的上传，其余内容下次手动继续。")
            Text("原版功能中点击选取文件或选取文件夹，会转到系统浏览器打开当前页面；请在网页中再次点击对应按钮继续操作。")
            Button("打开系统权限设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Text("版本 \(AppInfo.version)")
                .foregroundStyle(.secondary)
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

    private var busy: Bool { backup.running || backup.scanning || backup.restoring }
    private var display: AlbumDisplayMode { AlbumDisplayMode(rawValue: albumLayout) ?? .list }
    private var remoteHidden: Set<String> { RemoteAlbumVisibility.hidden(in: remoteHiddenStorage, server: address) }
    private var visibleRemoteAlbums: [String] {
        let hidden = remoteHidden
        return backup.remoteAlbums.filter { !hidden.contains($0) }
    }
    private var hiddenRemoteAlbums: [String] {
        let hidden = remoteHidden
        return backup.remoteAlbums.filter { hidden.contains($0) }
    }
    private var remoteSyncTargets: [String] {
        RemoteAlbumVisibility.syncTargets(selected: selectedRemote, available: backup.remoteAlbums, hidden: remoteHidden)
    }
    private var allRemoteSelected: Bool {
        !visibleRemoteAlbums.isEmpty && Set(visibleRemoteAlbums).isSubset(of: selectedRemote)
    }
    private func setRemoteHidden(_ name: String, hidden: Bool) {
        var values = remoteHidden
        if hidden { values.insert(name); selectedRemote.remove(name) } else { values.remove(name) }
        remoteHiddenStorage = RemoteAlbumVisibility.updating(remoteHiddenStorage, server: address, hidden: values)
    }

    // MARK: - 动作

    private func toggleRemote(_ name: String) {
        guard !remoteHidden.contains(name) else { return }
        if selectedRemote.contains(name) { selectedRemote.remove(name) }
        else { selectedRemote.insert(name) }
    }

    private func toggleAllRemote() {
        if allRemoteSelected { selectedRemote.removeAll() }
        else { selectedRemote = Set(visibleRemoteAlbums) }
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
        selectedRemote.formIntersection(Set(backup.remoteAlbums).subtracting(remoteHidden))
    }

    @MainActor
    private func syncSelected(_ targets: [String]) async {
        let allowed = Set(backup.remoteAlbums).subtracting(remoteHidden)
        let safeTargets = targets.filter { allowed.contains($0) }
        await backup.syncAlbums(safeTargets, address: address,
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
