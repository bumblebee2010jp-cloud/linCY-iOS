import SwiftUI
import UIKit
import Foundation
import Photos
import AVKit
import WebKit

enum AlbumDisplayMode: String, CaseIterable, Identifiable {
    case list, small, medium, large
    var id: String { rawValue }
    var title: String {
        switch self { case .list: return "列表"; case .small: return "小图标"
        case .medium: return "中等图标"; case .large: return "大图标" }
    }
    var columns: Int {
        switch self { case .list: return 1; case .small: return 4; case .medium: return 3; case .large: return 2 }
    }
    var grid: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 8), count: columns) }
}

struct AlbumLayoutMenu: View {
    @Binding var mode: String
    var body: some View {
        Menu {
            Picker("排列方式", selection: $mode) {
                ForEach(AlbumDisplayMode.allCases) { value in Text(value.title).tag(value.rawValue) }
            }
        } label: { Label("排列", systemImage: "square.grid.2x2") }
        .accessibilityLabel("相册和照片排列方式")
    }
}

struct AlbumInfoButton: View {
    let title: String
    let message: String
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: {
            Image(systemName: "info.circle").font(.body).frame(width: 32, height: 40)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title + "说明")
        .alert(title, isPresented: $showing) { Button("知道了", role: .cancel) {} } message: { Text(message) }
    }
}

// Remote hiding belongs to the server, rather than to album names globally.
enum RemoteAlbumVisibility {
    static func hidden(in stored: String, server: String) -> Set<String> {
        guard let data = stored.data(using: .utf8),
              let values = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [] }
        return Set(values[server] ?? [])
    }
    static func updating(_ stored: String, server: String, hidden: Set<String>) -> String {
        var values = stored.data(using: .utf8).flatMap {
            try? JSONDecoder().decode([String: [String]].self, from: $0)
        } ?? [:]
        values[server] = hidden.sorted()
        guard let data = try? JSONEncoder().encode(values), let text = String(data: data, encoding: .utf8) else { return stored }
        return text
    }
    static func syncTargets(selected: Set<String>, available: [String], hidden: Set<String>) -> [String] {
        available.filter { selected.contains($0) && !hidden.contains($0) }
    }
}

// PhotoKit requests are cancelled when thumbnails/previews leave the screen.
// A generation also prevents callbacks from old assets replacing the new image.
final class LocalPhotoLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var player: AVPlayer?
    @Published var message = ""
    private var request: PHImageRequestID = PHInvalidImageRequestID
    private var generation = UUID()
    func cancel() {
        generation = UUID()
        if request != PHInvalidImageRequestID { PHImageManager.default().cancelImageRequest(request) }
        request = PHInvalidImageRequestID; player?.pause(); player = nil; image = nil
    }
    func load(_ asset: PHAsset, full: Bool) {
        cancel(); image = nil; message = ""; let token = generation
        if full && asset.mediaType == .video {
            let options = PHVideoRequestOptions(); options.isNetworkAccessAllowed = true
            request = PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { [weak self] item, info in
                DispatchQueue.main.async {
                    guard let self = self, self.generation == token else { return }
                    if let item { self.player = AVPlayer(playerItem: item) }
                    else { self.message = (info?[PHImageErrorKey] as? Error)?.localizedDescription ?? "视频暂时无法加载，请检查 iCloud 和网络。" }
                }
            }
        } else {
            let options = PHImageRequestOptions(); options.isNetworkAccessAllowed = true
            options.deliveryMode = .opportunistic; options.resizeMode = .fast
            let size = full ? CGSize(width: 2400, height: 2400) : CGSize(width: 360, height: 360)
            request = PHImageManager.default().requestImage(for: asset, targetSize: size,
                contentMode: full ? .aspectFit : .aspectFill, options: options) { [weak self] image, info in
                    DispatchQueue.main.async {
                        guard let self = self, self.generation == token else { return }
                        if let image { self.image = image }
                        else if let error = info?[PHImageErrorKey] as? Error { self.message = error.localizedDescription }
                        else if (info?[PHImageCancelledKey] as? Bool) != true {
                            self.message = "照片暂时无法加载，请检查照片权限、iCloud 和网络。"
                        }
                    }
                }
        }
    }
    deinit {
        if request != PHInvalidImageRequestID { PHImageManager.default().cancelImageRequest(request) }
        player?.pause()
    }
}

struct LocalAlbumThumbnail: View {
    let asset: PHAsset?
    @StateObject private var loader = LocalPhotoLoader()
    var body: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            if let image = loader.image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
            if asset?.mediaType == .video {
                VStack { Spacer(); HStack { Image(systemName: "play.fill"); Spacer() } }.padding(5).foregroundStyle(.white)
            }
        }
        .clipped().accessibilityHidden(true)
        .onAppear { if let asset { loader.load(asset, full: false) } }
        .onDisappear { loader.cancel() }
    }
}

struct LocalAlbumCover: View {
    let album: PhoneAlbum
    @State private var asset: PHAsset?
    var body: some View {
        LocalAlbumThumbnail(asset: asset).id(asset?.localIdentifier)
            .task(id: album.id) {
                let options = PhotoLibrary.options(); options.fetchLimit = 1
                asset = PHAsset.fetchAssets(in: album.collection, options: options).firstObject
            }
    }
}

struct LocalAlbumBrowser: View {
    let album: PhoneAlbum
    @AppStorage("albumPhotoDisplayMode") private var mode = AlbumDisplayMode.list.rawValue
    @State private var assets: [PHAsset] = []
    @State private var result: PHFetchResult<PHAsset>?
    @State private var selection: AlbumPreviewSelection?
    private var display: AlbumDisplayMode { AlbumDisplayMode(rawValue: mode) ?? .list }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Text("\(assets.count) / \(result?.count ?? 0) 项照片与视频").font(.caption).foregroundStyle(.secondary)
                if assets.isEmpty { Text("相册为空，或尚未授权访问其中的照片。").padding(.vertical) }
                if display == .list {
                    ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { index, asset in
                        Button { selection = AlbumPreviewSelection(index: index) } label: {
                            HStack {
                                LocalAlbumThumbnail(asset: asset).frame(width: 72, height: 60).cornerRadius(8)
                                VStack(alignment: .leading) {
                                    Text(assetName(asset)).lineLimit(2)
                                    Text(asset.mediaType == .video ? "视频" : "照片").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(); Image(systemName: "chevron.right").font(.caption)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                } else {
                    LazyVGrid(columns: display.grid, spacing: 12) {
                        ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { index, asset in
                            Button { selection = AlbumPreviewSelection(index: index) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    LocalAlbumThumbnail(asset: asset).aspectRatio(1, contentMode: .fit).cornerRadius(8)
                                    Text(assetName(asset)).font(.caption2).lineLimit(2)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
                if assets.count < (result?.count ?? 0) {
                    Button("加载更多") { appendPage() }.task { appendPage() }.id(assets.count)
                }
            }.padding()
        }
        .navigationTitle(album.title).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { AlbumLayoutMenu(mode: $mode) } }
        .task {
            guard result == nil else { return }
            result = PHAsset.fetchAssets(in: album.collection, options: PhotoLibrary.options()); appendPage()
        }
        .fullScreenCover(item: $selection) { value in
            if let result { LocalAlbumPreview(result: result, initialIndex: value.index) }
        }
    }
    private func appendPage() {
        guard let result else { return }
        let end = min(assets.count + 60, result.count)
        guard assets.count < end else { return }
        for index in assets.count..<end { assets.append(result.object(at: index)) }
    }
}

struct AlbumPreviewSelection: Identifiable { let id = UUID(); let index: Int }
private func assetName(_ asset: PHAsset) -> String {
    PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "照片"
}

struct LocalAlbumPreview: View {
    let result: PHFetchResult<PHAsset>
    @State private var index: Int
    @StateObject private var loader = LocalPhotoLoader()
    @Environment(\.dismiss) private var dismiss
    init(result: PHFetchResult<PHAsset>, initialIndex: Int) {
        self.result = result; _index = State(initialValue: initialIndex)
    }
    var body: some View {
        NavigationStack {
            Group {
                if let player = loader.player { VideoPlayer(player: player) }
                else if let image = loader.image { ZoomableAlbumImage(image: image).id(index) }
                else if !loader.message.isEmpty {
                    VStack { Text(loader.message); Button("重试") { load() } }.padding()
                } else { ProgressView("正在加载（iCloud 原件可能需要等待）…") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(.white).background(Color.black)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("上一个") { index -= 1 }.disabled(index == 0)
                    Spacer(); Text("\(index + 1) / \(result.count)").font(.caption); Spacer()
                    Button("下一个") { index += 1 }.disabled(index + 1 >= result.count)
                }.padding().background(.bar)
            }
            .navigationTitle(assetName(result.object(at: index))).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("关闭") { dismiss() } } }
            .onAppear { load() }.onChange(of: index) { _ in load() }.onDisappear { loader.cancel() }
        }
    }
    private func load() { loader.load(result.object(at: index), full: true) }
}

private struct ZoomableAlbumImage: View {
    let image: UIImage
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(width: geometry.size.width * max(1, min(5, scale * pinch)),
                           height: geometry.size.height * max(1, min(5, scale * pinch)))
            }
            .gesture(MagnificationGesture().updating($pinch) { value, state, _ in state = value }
                .onEnded { value in scale = max(1, min(5, scale * value)) })
            .onTapGesture(count: 2) { scale = scale > 1 ? 1 : 2 }
        }
    }
}

@MainActor
final class RemoteAlbumBrowserModel: ObservableObject {
    @Published var items: [Server.AlbumPage.Item] = []
    @Published var total = 0
    @Published var loading = false
    @Published var error = ""
    @Published var cookie: String?
    var server: Server?
    private var nextOffset: Int? = 0
    private var loadedOffsets = Set<Int>()
    var hasMore: Bool { nextOffset != nil }
    func load(album: String, address: String, wifiOnly: Bool) async {
        guard !loading, let offset = nextOffset else { return }
        loading = true; error = ""; defer { loading = false }
        do {
            if server == nil { server = try Server(address: address, wifiOnly: wifiOnly) }
            guard let server else { return }
            if cookie == nil { cookie = try await server.login(password: Credentials.password(for: address)) }
            guard let cookie else { return }
            let page = try await server.photos(album: album, offset: offset, cookie: cookie)
            try Task.checkCancellation()
            if let next = page.nextOffset, next <= offset || loadedOffsets.contains(next) {
                throw AppError.message("服务器分页未前进，请刷新重试。")
            }
            var names = Set(items.map(\.name))
            items.append(contentsOf: page.photos.filter { names.insert($0.name).inserted })
            total = page.total; loadedOffsets.insert(offset); nextOffset = page.nextOffset
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    func reset() {
        guard !loading else { return }
        items = []; total = 0; cookie = nil; server = nil; nextOffset = 0; loadedOffsets = []; error = ""
    }
    func request(album: String, name: String, thumbnail: Bool) -> URLRequest? {
        guard let server, let cookie else { return nil }
        return server.request(thumbnail ? "api/album/thumbnail" : "api/album/photo", query: [
            URLQueryItem(name: "album", value: album), URLQueryItem(name: "name", value: name)
        ], cookie: cookie)
    }
}

@MainActor
struct RemoteAlbumBrowser: View {
    let album: String
    let address: String
    let wifiOnly: Bool
    @StateObject private var model = RemoteAlbumBrowserModel()
    @AppStorage("albumPhotoDisplayMode") private var mode = AlbumDisplayMode.list.rawValue
    @State private var selection: AlbumPreviewSelection?
    private var display: AlbumDisplayMode { AlbumDisplayMode(rawValue: mode) ?? .list }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text("已显示 \(model.items.count) / \(model.total) 项照片与视频").font(.caption).foregroundStyle(.secondary)
                if display == .list {
                    ForEach(Array(model.items.enumerated()), id: \.element.name) { index, item in
                        Button { selection = AlbumPreviewSelection(index: index) } label: {
                            HStack {
                                thumbnail(item).frame(width: 72, height: 60).cornerRadius(8)
                                VStack(alignment: .leading) {
                                    Text(item.name).lineLimit(2)
                                    Text(item.kind == "video" ? "视频" : "照片").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(); Image(systemName: "chevron.right").font(.caption)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                } else {
                    LazyVGrid(columns: display.grid, spacing: 12) {
                        ForEach(Array(model.items.enumerated()), id: \.element.name) { index, item in
                            Button { selection = AlbumPreviewSelection(index: index) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    thumbnail(item).aspectRatio(1, contentMode: .fit).cornerRadius(8)
                                    Text(item.name).font(.caption2).lineLimit(2)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
                if model.loading { ProgressView("正在读取…") }
                if !model.error.isEmpty {
                    Text(model.error).font(.footnote).foregroundStyle(.red)
                    Button("重新连接并刷新") { Task { await refresh() } }
                } else if model.items.isEmpty && !model.loading { Text("相册里还没有照片或视频。") }
                // Keep the sentinel mounted during its request. Removing a
                // .task view when loading=true would cancel its own URLSession.
                if model.hasMore && model.error.isEmpty {
                    Button("加载更多") { Task { await load() } }
                        .disabled(model.loading).task { await load() }.id(model.items.count)
                }
            }.padding()
        }
        .navigationTitle(album.isEmpty ? "根目录" : album).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { AlbumLayoutMenu(mode: $mode) } }
        .task { if model.items.isEmpty { await load() } }.refreshable { await refresh() }
        .fullScreenCover(item: $selection) { value in
            RemoteAlbumPreview(model: model, album: album, address: address, wifiOnly: wifiOnly, initialIndex: value.index)
        }
    }
    private func thumbnail(_ item: Server.AlbumPage.Item) -> some View {
        RemoteAlbumThumbnail(request: model.request(album: album, name: item.name, thumbnail: true),
                             session: model.server?.session, isVideo: item.kind == "video")
    }
    private func load() async { await model.load(album: album, address: address, wifiOnly: wifiOnly) }
    private func refresh() async { guard !model.loading else { return }; model.reset(); await load() }
}

private struct RemoteAlbumThumbnail: View {
    let request: URLRequest?
    let session: URLSession?
    let isVideo: Bool
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: isVideo ? "video" : "photo").foregroundStyle(.secondary) }
            if isVideo { VStack { Spacer(); HStack { Image(systemName: "play.fill"); Spacer() } }.padding(5).foregroundStyle(.white) }
        }.clipped().accessibilityHidden(true)
        .onDisappear { image = nil }
        .task(id: request?.url) {
            image = nil
            guard let request, let session else { return }
            do {
                let (data, response) = try await session.data(for: request)
                guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
                      !Task.isCancelled else { return }
                image = UIImage(data: data)
            } catch { /* The preview button remains usable if a thumbnail is unavailable. */ }
        }
    }
}

@MainActor
struct RemoteAlbumPreview: View {
    @ObservedObject var model: RemoteAlbumBrowserModel
    let album: String
    let address: String
    let wifiOnly: Bool
    @State private var index: Int
    @Environment(\.dismiss) private var dismiss
    init(model: RemoteAlbumBrowserModel, album: String, address: String, wifiOnly: Bool, initialIndex: Int) {
        self.model = model; self.album = album; self.address = address; self.wifiOnly = wifiOnly
        _index = State(initialValue: initialIndex)
    }
    var body: some View {
        NavigationStack {
            Group {
                if model.items.indices.contains(index), let server = model.server, let cookie = model.cookie {
                    RemoteAlbumMedia(server: server, cookie: cookie, album: album, item: model.items[index])
                        .id(model.items[index].name)
                } else { Text("无法打开预览，请返回刷新。").padding() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(.white).background(Color.black)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    if !model.error.isEmpty { Text(model.error).font(.caption).foregroundStyle(.red) }
                    HStack {
                        Button("上一个") { index -= 1 }.disabled(index == 0 || model.loading)
                        Spacer(); Text("\(index + 1) / \(model.total)").font(.caption); Spacer()
                        Button(model.loading ? "加载中…" : "下一个") {
                            Task {
                                if index + 1 >= model.items.count && model.hasMore {
                                    await model.load(album: album, address: address, wifiOnly: wifiOnly)
                                }
                                if index + 1 < model.items.count { index += 1 }
                            }
                        }.disabled(model.loading || (index + 1 >= model.items.count && !model.hasMore))
                    }
                }.padding().background(.bar)
            }
            .navigationTitle(model.items.indices.contains(index) ? model.items[index].name : "预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("关闭") { dismiss() } } }
        }
    }
}

// Cookies stay in WebKit's cookie store rather than the URL. Video uses native
// controls and streaming; it is not downloaded in full before playback.
private struct RemoteAlbumMedia: UIViewRepresentable {
    let server: Server
    let cookie: String
    let album: String
    let item: Server.AlbumPage.Item
    final class Coordinator { var active = true }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.allowsInlineMediaPlayback = true; config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false; web.backgroundColor = .black; web.scrollView.backgroundColor = .black
        let pieces = cookie.split(separator: "=", maxSplits: 1).map(String.init)
        let values: [HTTPCookiePropertyKey: Any] = [.domain: server.base.host ?? "", .path: "/api/",
            .name: pieces.first ?? "vuio_session", .value: pieces.count > 1 ? pieces[1] : ""]
        let coordinator = context.coordinator
        let load = { [weak web] in
            guard coordinator.active, let web else { return }
            let original = server.request("api/album/photo", query: [URLQueryItem(name: "album", value: album),
                URLQueryItem(name: "name", value: item.name)]).url!.absoluteString
            let preview = server.request("api/album/photo", query: [URLQueryItem(name: "album", value: album),
                URLQueryItem(name: "name", value: item.name), URLQueryItem(name: "preview", value: "true")]).url!.absoluteString
            func attribute(_ text: String) -> String {
                text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                    .replacingOccurrences(of: "<", with: "&lt;")
            }
            let media = item.kind == "video"
                ? "<video controls playsinline preload='metadata' src=\"\(attribute(original))\"></video>"
                : "<img alt='图片预览' src=\"\(attribute(preview))\" data-original=\"\(attribute(original))\" onerror=\"if(!this.dataset.retried){this.dataset.retried='1';this.src=this.dataset.original;}else{document.getElementById('error').hidden=false;}\">"
            let html = """
            <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=5">
            <style>html,body{margin:0;background:#000;color:#fff;height:100%;}body{display:flex;align-items:center;justify-content:center;}img,video{max-width:100%;max-height:100%;object-fit:contain;}#error{position:fixed;bottom:16px;padding:12px;}</style>
            </head><body>\(media)<p id="error" hidden>无法预览，请检查连接或文件格式，返回后可重试。</p>
            <script>document.querySelector('video')?.addEventListener('error',()=>{document.getElementById('error').hidden=false;});</script></body></html>
            """
            web.loadHTMLString(html, baseURL: server.base)
        }
        if let storedCookie = HTTPCookie(properties: values) {
            config.websiteDataStore.httpCookieStore.setCookie(storedCookie, completionHandler: load)
        } else { load() }
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.active = false
        uiView.stopLoading(); uiView.loadHTMLString("", baseURL: nil)
    }
}
