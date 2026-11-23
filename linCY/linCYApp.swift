import SwiftUI
import UIKit

enum AlbumSource: String, CaseIterable, Identifiable {
    case local = "本机相册"
    case remote = "服务器相册"
    var id: String { rawValue }
}

enum SyncRequest: Identifiable {
    case all
    case album(String)

    var id: String {
        switch self {
        case .all: return "__all__"
        case .album(let name): return name
        }
    }

    var title: String {
        switch self {
        case .all: return "同步全部服务器相册？"
        case .album(let name): return "同步「\(name)」到手机相册？"
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions:
        [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = BackupManager.shared
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
    @State private var connectionStatus = ""
    @State private var connecting = false
    @State private var webToken = UUID()
    @State private var webCookie: String?

    var body: some View {
        TabView {
            NavigationStack {
                if let url = URL(string: address), !address.isEmpty {
                    WebScreen(url: url, cookie: webCookie).id(webToken)
                        .navigationTitle("linCY").navigationBarTitleDisplayMode(.inline)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "network").font(.largeTitle)
                        Text("先在“连接”页面填写电脑上的 linCY 访问地址")
                            .multilineTextAlignment(.center)
                    }.padding()
                }
            }.tabItem { Label("原版功能", systemImage: "globe") }
            NavigationStack {
                List {
                    Section {
                        Text(backup.status)
                        if backup.running { ProgressView(value: backup.progress) }
                        Text("上传 \(backup.uploaded) · 下载 \(backup.downloaded) · 已有 \(backup.skipped) · 失败 \(backup.failed)")
                            .font(.footnote).foregroundStyle(.secondary)
                        if backup.running {
                            Button("停止当前任务") { backup.stop() }
                        } else {
                            Button {
                                Task { await backup.start(address: address,
                                    password: Credentials.password(for: address), wifiOnly: wifiOnly) }
                            } label: { Label("开始备份", systemImage: "icloud.and.arrow.up") }
                                .disabled(address.isEmpty || backup.selected.isEmpty || backup.restoring)
                        }
                    } footer: {
                        Text("备份是手机 → 服务器：对比同名文件夹，缺少则新建，按文件名跳过已有文件，不覆盖、不删除。同步是服务器 → 手机：在下方切到「服务器相册」，点相册或「同步全部」下载缺失文件。首次备份建议保持此页在前台。")
                    }
                    Section {
                        Picker("相册来源", selection: $albumSource) {
                            ForEach(AlbumSource.allCases) { source in
                                Text(source.rawValue).tag(source)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    if albumSource == .local {
                    Section {
                        Button("读取 / 刷新手机相册") { Task { await backup.loadAlbums() } }
                            .disabled(backup.running)
                        ForEach(visibleAlbums) { album in
                            albumRow(album)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        backup.hide(album.id)
                                    } label: { Label("隐藏此相册", systemImage: "eye.slash") }
                                }
                        }
                        if !hiddenAlbums.isEmpty {
                            DisclosureGroup(isExpanded: $showHiddenAlbums) {
                                ForEach(hiddenAlbums) { album in
                                    albumRow(album)
                                        .contextMenu {
                                            Button {
                                                backup.unhide(album.id)
                                            } label: { Label("取消隐藏", systemImage: "eye") }
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
                    } else {
                    Section {
                        if backup.loadingRemote {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("正在读取服务器相册…").foregroundStyle(.secondary)
                            }
                        } else if backup.remoteAlbums.isEmpty {
                            Text("还没有读取。点右上角「读取 / 刷新」。")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            ForEach(backup.remoteAlbums, id: \.self) { name in
                                Button {
                                    syncRequest = .album(name)
                                } label: {
                                    HStack {
                                        Image(systemName: "folder")
                                        Text(name).foregroundStyle(.primary).lineLimit(1)
                                        Spacer()
                                        Image(systemName: "arrow.down.circle")
                                            .foregroundStyle(.tint)
                                    }
                                }
                                .disabled(backup.running || backup.restoring)
                            }
                            Button {
                                syncRequest = .all
                            } label: {
                                Label("同步全部（\(backup.remoteAlbums.count) 个相册）",
                                      systemImage: "arrow.down.circle.fill")
                            }
                            .disabled(backup.running || backup.restoring)
                        }
                    } header: {
                        HStack {
                            Text("服务器相册（\(backup.remoteAlbums.count)）")
                            Spacer()
                            Button {
                                Task { await backup.loadRemoteAlbums(address: address,
                                    password: Credentials.password(for: address), wifiOnly: wifiOnly) }
                            } label: {
                                Text(backup.loadingRemote ? "读取中…" : "读取 / 刷新")
                                    .font(.footnote)
                            }
                            .disabled(backup.running || backup.loadingRemote)
                        }
                    } footer: {
                        Text("点某个相册即可把它同步到手机同名相册：手机上没有该相册会新建，只下载缺失文件。与已隐藏手机相册同名的会跳过。")
                    }
                    }
                    if !backup.logs.isEmpty {
                        Section("本次记录") {
                            ForEach(Array(backup.logs.enumerated()), id: \.offset) { _, text in
                                Text(text).font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                }.navigationTitle("相册备份")
                    .onChange(of: albumSource) { source in
                        guard source == .remote, backup.remoteAlbums.isEmpty,
                              !address.isEmpty, !backup.loadingRemote, !backup.running else { return }
                        Task { await backup.loadRemoteAlbums(address: address,
                            password: Credentials.password(for: address), wifiOnly: wifiOnly) }
                    }
                    .confirmationDialog(syncRequest?.title ?? "", isPresented: Binding(
                        get: { syncRequest != nil },
                        set: { if !$0 { syncRequest = nil } }
                    ), titleVisibility: .visible) {
                        Button("开始同步") {
                            guard let request = syncRequest else { return }
                            let targets: [String]
                            switch request {
                            case .all: targets = backup.remoteAlbums
                            case .album(let name): targets = [name]
                            }
                            Task { await backup.syncAlbums(targets, address: address,
                                password: Credentials.password(for: address), wifiOnly: wifiOnly) }
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("对比服务器与手机相册，只下载手机里没有的文件；手机上缺的同名相册会自动新建。")
                    }
            }.tabItem { Label("相册备份", systemImage: "photo.on.rectangle.angled") }
            NavigationStack {
                Form {
                    Section("电脑上的 linCY 服务") {
                        TextField("http://192.168.1.10:8091", text: $draft)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        SecureField("访问密码（未设置则留空）", text: $password)
                        Toggle("备份仅使用 Wi-Fi", isOn: $wifiOnly)
                            .disabled(backup.running)
                        Button(connecting ? "正在连接…" : "连接并保存") {
                            Task { await connect() }
                        }.disabled(connecting || backup.running)
                        if !connectionStatus.isEmpty { Text(connectionStatus).font(.footnote) }
                    }
                    Section {
                        Text("填写服务端“手机传输”的访问地址，默认端口 8091。手机需能访问电脑，服务端需保持开启。备份保存到服务端已配置的“相册备份文件夹”。")
                        Text("相册内容只在你点击备份后上传。Live Photo 会分别备份原始照片与视频；仅 iCloud 中的原件会先下载。后台只尝试完成已提交的上传，其余内容下次手动继续。")
                        Button("打开系统权限设置") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }.font(.footnote)
                }.navigationTitle("连接")
            }.tabItem { Label("连接", systemImage: "gearshape") }
        }.task {
            draft = address
            password = Credentials.password(for: address)
            // Read remembered choices, but never start an upload on launch.
            if !backup.selected.isEmpty { await backup.loadAlbums() }
        }
    }

    private var visibleAlbums: [PhoneAlbum] {
        backup.albums.filter { !backup.hidden.contains($0.id) }
    }

    private var hiddenAlbums: [PhoneAlbum] {
        backup.albums.filter { backup.hidden.contains($0.id) }
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

    @MainActor private func connect() async {
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
        } catch { connectionStatus = error.localizedDescription }
    }
}
