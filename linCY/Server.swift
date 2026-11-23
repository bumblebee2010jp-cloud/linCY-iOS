import Foundation
import Security

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

enum Credentials {
    static func password(for server: String) -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "linCY-iOS", kSecAttrAccount as String: server,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ password: String, for server: String) throws {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "linCY-iOS", kSecAttrAccount as String: server]
        SecItemDelete(q as CFDictionary)
        var value = q
        value[kSecValueData as String] = Data(password.utf8)
        value[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(value as CFDictionary, nil) == errSecSuccess else {
            throw AppError.message("无法将密码保存到钥匙串")
        }
    }
}

struct Server: @unchecked Sendable {
    let base: URL
    let session: URLSession

    init(address: String, wifiOnly: Bool, sessionConfiguration: URLSessionConfiguration? = nil) throws {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var c = URLComponents(string: raw.contains("://") ? raw : "http://" + raw),
              ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
              c.host != nil, c.user == nil, c.password == nil,
              c.path.isEmpty || c.path == "/", c.query == nil, c.fragment == nil else {
            throw AppError.message("请输入电脑的访问地址，例如 http://192.168.1.10:8091，不要添加页面路径")
        }
        c.path = ""
        guard let url = c.url else { throw AppError.message("服务器地址无效") }
        base = url
        let config = sessionConfiguration ?? URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = !wifiOnly
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    func request(_ path: String, query: [URLQueryItem] = [], cookie: String? = nil) -> URLRequest {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        var request = URLRequest(url: c.url!)
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        return request
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AppError.message("服务器响应无效") }
        guard (200..<300).contains(response.statusCode) else {
            let detail = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw AppError.message("服务器 HTTP \(response.statusCode)：\(detail)")
        }
        return (data, response)
    }

    func login(password: String) async throws -> String {
        var r = request("api/login")
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["password": password])
        let (_, response) = try await send(r)
        let cookies = HTTPCookie.cookies(withResponseHeaderFields:
            response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                if let key = pair.key as? String { result[key] = String(describing: pair.value) }
            }, for: base)
        guard let cookie = cookies.first(where: { $0.name == "vuio_session" }) else {
            throw AppError.message("登录响应缺少会话，请确认连接的是 linCY 手机传输端口")
        }
        return "\(cookie.name)=\(cookie.value)"
    }

    func albums(cookie: String) async throws -> [String] {
        let (data, _) = try await send(request("api/albums", cookie: cookie))
        return try JSONDecoder().decode([String].self, from: data)
    }

    func ensureAlbum(_ name: String, known: inout Set<String>, cookie: String) async throws -> String {
        if known.contains(name) { return name }
        var r = request("api/album/create", cookie: cookie)
        r.httpMethod = "POST"
        r.setValue("1", forHTTPHeaderField: "x-vuio-upload")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "parent": ""])
        let (data, _) = try await send(r)
        struct Created: Decodable { let name: String }
        let created = try JSONDecoder().decode(Created.self, from: data).name
        // The desktop API renames on a create race. Re-read to use the original folder.
        known = Set(try await albums(cookie: cookie))
        return known.contains(name) ? name : created
    }

    func exists(album: String, name: String, cookie: String) async throws -> Bool {
        let (data, _) = try await send(request("api/upload-check", query: [
            URLQueryItem(name: "album", value: album), URLQueryItem(name: "name", value: name)
        ], cookie: cookie))
        struct Check: Decodable { let exists: Bool }
        guard let check = try? JSONDecoder().decode(Check.self, from: data) else {
            // 响应不是 {"exists":bool}（空 body 或字段名不同）时不阻断整轮备份：
            // 按「服务器没有」处理，由上传接口的 conflict=skip 负责去重。
            return false
        }
        return check.exists
    }

    func uploadRequest(album: String, name: String, cookie: String, size: Int64) -> URLRequest {
        var r = request("api/upload", query: [URLQueryItem(name: "album", value: album),
            URLQueryItem(name: "name", value: name), URLQueryItem(name: "conflict", value: "skip")], cookie: cookie)
        r.httpMethod = "POST"
        r.setValue("1", forHTTPHeaderField: "x-vuio-upload")
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        r.setValue(String(size), forHTTPHeaderField: "Content-Length")
        return r
    }

    // MARK: - 相册反向同步（服务器 → 手机）

    struct AlbumPage: Decodable {
        struct Item: Decodable {
            let name: String
            let kind: String      // "image" / "video"
        }
        let photos: [Item]
        let total: Int
        let nextOffset: Int?

        enum CodingKeys: String, CodingKey {
            case photos, total
            case nextOffset = "next_offset"
        }
    }

    /// GET /api/album/photos?album=&offset= — 服务端固定每页返回 12 条。
    func photos(album: String, offset: Int, cookie: String) async throws -> AlbumPage {
        let (data, _) = try await send(request("api/album/photos", query: [
            URLQueryItem(name: "album", value: album),
            URLQueryItem(name: "offset", value: String(offset))
        ], cookie: cookie))
        return try JSONDecoder().decode(AlbumPage.self, from: data)
    }

    /// GET /api/album/photo?album=&name= — 下载原始文件到指定位置。
    func downloadPhoto(album: String, name: String, cookie: String, to destination: URL) async throws {
        let req = request("api/album/photo", query: [
            URLQueryItem(name: "album", value: album),
            URLQueryItem(name: "name", value: name)
        ], cookie: cookie)
        let (temp, response) = try await session.download(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            try? FileManager.default.removeItem(at: temp)
            throw AppError.message("下载 \(name) HTTP \(code)")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
    }

    // MARK: - 备份根目录（upload）操作，供文件夹镜像同步

    struct UploadEntry: Decodable {
        let name: String
        let path: String
        let isDir: Bool
        /// 旧版服务端不返回 size；缺失时按 0 处理，只会导致多传一次。
        let size: Int64?

        enum CodingKeys: String, CodingKey {
            case name, path, size
            case isDir = "is_dir"
        }
    }

    struct UploadContents: Decodable {
        let path: String
        let entries: [UploadEntry]
    }

    /// GET /api/upload-contents?path= — 列出备份根下某一层目录。
    func uploadContents(path: String, cookie: String) async throws -> UploadContents {
        var query: [URLQueryItem] = []
        if !path.isEmpty { query.append(URLQueryItem(name: "path", value: path)) }
        let (data, _) = try await send(request("api/upload-contents", query: query, cookie: cookie))
        return try JSONDecoder().decode(UploadContents.self, from: data)
    }

    /// POST /api/upload-folder — 在备份根下新建文件夹，返回最终目录名。
    @discardableResult
    func createFolder(name: String, parent: String, cookie: String) async throws -> String {
        var r = request("api/upload-folder", cookie: cookie)
        r.httpMethod = "POST"
        r.setValue("1", forHTTPHeaderField: "x-vuio-upload")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "path": parent, "conflict": "overwrite"])
        let (data, _) = try await send(r)
        struct Created: Decodable { let directory: String; let skipped: Bool? }
        return try JSONDecoder().decode(Created.self, from: data).directory
    }

    /// POST /api/upload?path=&name=&conflict= — 把本地文件直传到备份根下的相对目录。
    func uploadFile(path: String, name: String, fileURL: URL, size: Int64,
                    overwrite: Bool, cookie: String) async throws {
        var query = [URLQueryItem(name: "name", value: name)]
        if !path.isEmpty { query.append(URLQueryItem(name: "path", value: path)) }
        query.append(URLQueryItem(name: "conflict", value: overwrite ? "overwrite" : "skip"))
        var r = request("api/upload", query: query, cookie: cookie)
        r.httpMethod = "POST"
        r.timeoutInterval = 3600
        r.setValue("1", forHTTPHeaderField: "x-vuio-upload")
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        r.setValue(String(size), forHTTPHeaderField: "Content-Length")
        let (data, response) = try await session.upload(for: r, fromFile: fileURL)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw AppError.message("上传 \(name) HTTP \(code)：\(String(data: data.prefix(200), encoding: .utf8) ?? "")")
        }
        struct Receipt: Decodable { let name: String; let size: Int64?; let skipped: Bool? }
        let receipt = try JSONDecoder().decode(Receipt.self, from: data)
        guard receipt.name == name, receipt.size == size || (!overwrite && receipt.skipped == true) else { throw AppError.message("上传回执大小不符：\(name)") }
    }

}
