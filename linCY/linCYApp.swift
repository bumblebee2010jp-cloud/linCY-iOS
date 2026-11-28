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
    @AppStorage("albumCompactLayout") private var smallIcons = false
    @AppStorage("remoteHiddenByServer") private var remoteHiddenJSON = "{}"
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
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("列表") { smallIcons = false }
                        Button("小图标") { smallIcons = true }
                    } label: { Label(smallIcons ? "小图标" : "列表", systemImage: smallIcons ? "square.grid.3x3" : "list.bullet") }
                }
            }
            .onChange(of: address) { _ in selectedRemote.removeAll(); backup.remoteAlbums = [] }
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
            HStack(spacing: 10) {
                HStack(spacing: 0) {
                    Button("开始备份") { Task { await startBackup() } }
                        .disabled(address.isEmpty || backup.selected.isEmpty || busy)
                    AlbumHelp(title: "开始备份", text: "备份全部勾选的本机相册到服务器，按文件名跳过已有文件，不覆盖、不删除。同步是服务器到手机，只下载缺失文件。")
                }
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    Button(backup.scanning ? "正在检查…" : "检查同名大小") { Task { await scanConflicts() } }
                        .disabled(address.isEmpty || backup.selected.isEmpty || busy)
                    AlbumHelp(title: "检查同名大小", text: "对全部勾选相册中服务器已有的同名文件逐张导出并比较大小，比较慢、可停止，不修改文件。备份仍按同名跳过、不覆盖。")
                }
            }.font(.subheadline).buttonStyle(.borderless)
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

    private var busy: Bool { backup.running || backup.scanning || backup.restoring }
    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 8), count: 3) }
    private var remoteHidden: Set<String> {
        guard let data = remoteHiddenJSON.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [] }
        return Set(map[address] ?? [])
    }
    private var visibleRemote: [String] { let hidden = remoteHidden; return backup.remoteAlbums.filter { !hidden.contains($0) } }
    private var hiddenRemote: [String] { let hidden = remoteHidden; return backup.remoteAlbums.filter { hidden.contains($0) } }
    private var remoteTargets: [String] { visibleRemote.filter { selectedRemote.contains($0) } }
    private func hideRemote(_ name: String, hidden: Bool) {
        var values = remoteHidden
        if hidden { values.insert(name); selectedRemote.remove(name) } else { values.remove(name) }
        var map = remoteHiddenJSON.data(using: .utf8).flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
        map[address] = values.sorted()
        if let data = try? JSONEncoder().encode(map), let text = String(data: data, encoding: .utf8) { remoteHiddenJSON = text }
    }

    @ViewBuilder
    private var localAlbumsSection: some View {
        Section {
            Button("读取 / 刷新手机相册") { Task { await backup.loadAlbums() } }.disabled(busy)
            HStack {
                Text("已选 \(backup.selected.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(localAllSelected ? "取消全选" : "全选") {
                    if localAllSelected { backup.selected.removeAll() }
                    else { backup.selected = Set(visibleAlbums.map(\.id)) }
                }.buttonStyle(.borderless).disabled(busy || visibleAlbums.isEmpty)
            }
            localCollection(visibleAlbums)
            if !hiddenAlbums.isEmpty {
                DisclosureGroup(isExpanded: $showHiddenAlbums) {
                    localCollection(hiddenAlbums)
                } label: { Label("已隐藏（\(hiddenAlbums.count)）", systemImage: "eye.slash") }
            }
        } header: { Text("本机相册（\(visibleAlbums.count)）") }
    }

    private var localAllSelected: Bool {
        !visibleAlbums.isEmpty && Set(visibleAlbums.map(\.id)).isSubset(of: backup.selected)
    }
    @ViewBuilder
    private func localCollection(_ albums: [PhoneAlbum]) -> some View {
        if smallIcons {
            LazyVGrid(columns: columns, spacing: 10) { ForEach(albums) { localCell($0) } }.padding(.vertical, 6)
        } else { ForEach(albums) { localCell($0) } }
    }
    private func localCell(_ album: PhoneAlbum) -> some View {
        AlbumChoiceCell(name: album.title, count: String(album.count), selected: backup.selected.contains(album.id),
            hidden: backup.hidden.contains(album.id), small: smallIcons, disabled: busy,
            toggle: {
                if backup.selected.contains(album.id) { backup.selected.remove(album.id) } else { backup.selected.insert(album.id) }
            }, hide: {
                if backup.hidden.contains(album.id) { backup.unhide(album.id) } else { backup.hide(album.id) }
            })
    }

    @ViewBuilder
    private var remoteAlbumsSection: some View {
        Section {
            if backup.loadingRemote { ProgressView("正在读取服务器相册…") }
            else {
                HStack {
                    Text("已选 \(remoteTargets.count)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(allRemoteSelected ? "取消全选" : "全选") { toggleAllRemote() }
                        .buttonStyle(.borderless).disabled(busy || visibleRemote.isEmpty)
                }
                remoteCollection(visibleRemote)
                if !hiddenRemote.isEmpty {
                    DisclosureGroup(isExpanded: $showHiddenRemote) {
                        remoteCollection(hiddenRemote)
                    } label: { Label("已隐藏（\(hiddenRemote.count)）", systemImage: "eye.slash") }
                }
                HStack {
                    Button("同步选中（\(remoteTargets.count)）") { syncRequest = .albums(remoteTargets) }
                        .disabled(busy || remoteTargets.isEmpty)
                    AlbumHelp(title: "服务器同步", text: "处理全部勾选的服务器相册，只下载手机缺失文件。隐藏相册不参与全选、同步选中或同步全部；隐藏只影响此 App，不删除服务器文件。")
                }.buttonStyle(.borderless)
                Button("同步全部（\(visibleRemote.count) 个相册）") { syncRequest = .albums(visibleRemote) }
                    .disabled(busy || visibleRemote.isEmpty)
            }
        } header: {
            HStack {
                Text("服务器相册（\(visibleRemote.count)）"); Spacer()
                Button("读取 / 刷新") { Task { await loadRemoteAlbums() } }.disabled(busy || backup.loadingRemote || address.isEmpty)
            }
        }
    }
    @ViewBuilder
    private func remoteCollection(_ names: [String]) -> some View {
        if smallIcons {
            LazyVGrid(columns: columns, spacing: 10) { ForEach(names, id: \.self) { remoteCell($0) } }.padding(.vertical, 6)
        } else { ForEach(names, id: \.self) { remoteCell($0) } }
    }
    private func remoteCell(_ name: String) -> some View {
        AlbumChoiceCell(name: name.isEmpty ? "根目录" : name, count: nil, selected: selectedRemote.contains(name),
            hidden: remoteHidden.contains(name), small: smallIcons, disabled: busy,
            toggle: { toggleRemote(name) }, hide: { hideRemote(name, hidden: !remoteHidden.contains(name)) })
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

    private var allRemoteSelected: Bool {
        !visibleRemote.isEmpty && Set(visibleRemote).isSubset(of: selectedRemote)
    }

    // MARK: - 动作

    private func toggleRemote(_ name: String) {
        guard !remoteHidden.contains(name) else { return }
        if selectedRemote.contains(name) { selectedRemote.remove(name) }
        else { selectedRemote.insert(name) }
    }

    private func toggleAllRemote() {
        if allRemoteSelected { selectedRemote.removeAll() }
        else { selectedRemote = Set(visibleRemote) }
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
        await backup.syncAlbums(targets.filter { visibleRemote.contains($0) }, address: address,
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

private struct AlbumHelp: View {
    let title: String
    let text: String
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: {
            Image(systemName: "info.circle").frame(width: 30, height: 40)
        }.buttonStyle(.borderless).accessibilityLabel(title + "说明")
        .alert(title, isPresented: $showing) { Button("知道了", role: .cancel) {} } message: { Text(text) }
    }
}

private struct AlbumChoiceCell: View {
    let name: String
    let count: String?
    let selected: Bool
    let hidden: Bool
    let small: Bool
    let disabled: Bool
    let toggle: () -> Void
    let hide: () -> Void
    var body: some View {
        Group {
            if small {
                VStack(spacing: 5) {
                    Button(action: toggle) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 32))
                                .frame(maxWidth: .infinity).frame(height: 64)
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle").padding(4)
                        }
                    }.disabled(disabled || hidden)
                    Text(name).font(.caption).lineLimit(2).frame(maxWidth: .infinity)
                    if let count { Text(count + " 项").font(.caption2).foregroundStyle(.secondary) }
                    Button(action: hide) {
                        Label(hidden ? "取消隐藏" : "隐藏", systemImage: hidden ? "eye" : "eye.slash").font(.caption2)
                    }.disabled(disabled)
                }.padding(6).background(Color.secondary.opacity(0.08)).cornerRadius(10)
            } else {
                HStack(spacing: 8) {
                    Button(action: toggle) {
                        HStack {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            Text(name).foregroundStyle(.primary).lineLimit(2)
                            Spacer()
                            if let count { Text(count).foregroundStyle(.secondary) }
                        }.contentShape(Rectangle()).frame(minHeight: 40)
                    }.disabled(disabled || hidden)
                    Button(action: hide) {
                        Image(systemName: hidden ? "eye" : "eye.slash").frame(width: 36, height: 40)
                    }.disabled(disabled)
                }
            }
        }.buttonStyle(.borderless)
        .contextMenu {
            Button(action: hide) { Label(hidden ? "取消隐藏" : "隐藏此相册", systemImage: hidden ? "eye" : "eye.slash") }.disabled(disabled)
        }
    }
}
