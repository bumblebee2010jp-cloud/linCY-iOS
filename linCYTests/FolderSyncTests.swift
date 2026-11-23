import XCTest
import SwiftUI
import UniformTypeIdentifiers
@testable import linCY

final class FolderSyncTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func put(_ path: String, _ value: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url)
    }
    func entry(_ path: String, _ value: String) throws -> SyncEntry {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(value.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let hash = try SyncFiles.hash(url)
        return SyncEntry(path: path, kind: "file", size: hash.0, sha256: hash.1)
    }
    @MainActor func testSamePathAndSizeSkipsEvenWhenContentDiffers() throws {
        let a = SyncEntry(path: "A", kind: "file", size: 3, sha256: "local")
        let b = SyncEntry(path: "A", kind: "file", size: 3, sha256: "server")
        let diff = try FolderSyncManager.difference(local: [a], remote: [b])
        XCTAssertEqual(diff.skipped, 1); XCTAssertEqual(diff.updated, 0); XCTAssertEqual(diff.deleted, 0)
    }
    @MainActor func testSizeChangeUpdatesAndRemoteExtrasAreNeverDeleted() throws {
        let local = [SyncEntry(path: "A", kind: "file", size: 4, sha256: ""), SyncEntry(path: "B", kind: "file", size: 1, sha256: "")]
        let remote = [SyncEntry(path: "A", kind: "file", size: 3, sha256: ""), SyncEntry(path: "C", kind: "file", size: 1, sha256: "")]
        let diff = try FolderSyncManager.difference(local: local, remote: remote)
        XCTAssertEqual(diff.updated, 1); XCTAssertEqual(diff.added, 1); XCTAssertEqual(diff.deleted, 0)
        XCTAssertEqual(try FolderSyncManager.difference(local: [], remote: remote).deleted, 0)
    }
    @MainActor func testFileDirectoryConflictStopsWithoutDeleting() {
        XCTAssertThrowsError(try FolderSyncManager.difference(local: [SyncEntry(path: "A", kind: "dir", size: 0, sha256: "")], remote: [SyncEntry(path: "A", kind: "file", size: 1, sha256: "")]))
    }
    func testSHA256DetectsSameSizeDifferentContent() throws {
        try put("A", "one"); try put("B", "two")
        let a = try SyncFiles.hash(root.appendingPathComponent("A"))
        let b = try SyncFiles.hash(root.appendingPathComponent("B"))
        XCTAssertEqual(a.0, b.0); XCTAssertNotEqual(a.1, b.1)
        XCTAssertEqual(a.1, "7692c3ad3540bb803c020b3aee66cd8887123234ea0c6e7143c0add73ff431ed")
    }
    func testRecursiveScanIncludesEmptyAndHiddenDirectories() throws {
        try put("sub/A", "A"); try put(".hidden", "hidden")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: false)
        let entries = try SyncFiles.scan(root)
        XCTAssertEqual(Set(entries.map(\.path)), Set(["sub", "sub/A", ".hidden", "empty"]))
        XCTAssertEqual(entries.first { $0.path == "empty" }?.kind, "dir")
    }
    func testFailedScanDoesNotProduceAnEmptyManifest() {
        XCTAssertThrowsError(try SyncFiles.scan(root.appendingPathComponent("missing")))
    }
    func testBrokenBookmarkRequiresReauthorization() {
        var auth = FolderAuthorization(bookmark: Data("broken".utf8), name: "moved")
        XCTAssertThrowsError(try auth.resolve())
    }
    func testMergeKeepsExtraFilesAndReplacesOnlyVerifiedFile() throws {
        try put("Movies/A.mp4", "old"); try put("Movies/C.mp4", "keep")
        let temp = root.appendingPathComponent("source")
        try Data("new".utf8).write(to: temp)
        let expected = try entry("A.mp4", "new")
        try SyncFiles.mergeFile(temp: temp, root: root, relative: "Movies/A.mp4", expected: expected)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Movies/A.mp4"), encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Movies/C.mp4"), encoding: .utf8), "keep")
    }
    func testCorruptDownloadNeverReplacesExistingFile() throws {
        try put("A", "original"); try put("partial", "bad")
        XCTAssertThrowsError(try SyncFiles.mergeFile(temp: root.appendingPathComponent("partial"), root: root, relative: "A", expected: entry("A", "correct")))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("A"), encoding: .utf8), "original")
    }
    func testSymbolicLinkAndTraversalFailClosed() throws {
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root)
        XCTAssertThrowsError(try SyncFiles.scan(root))
        for path in ["../escape", "/absolute", "C:/file", "a//b", "a/../b", ".vuio-sync-trash"] {
            XCTAssertThrowsError(try SyncFiles.validate(path))
        }
    }
    func testSnapshotRejectsSourceChangedAfterPreview() throws {
        try put("A", "first")
        let expected = try entry("A", "first")
        try put("A", "other")
        let temp = root.appendingPathComponent("snapshot")
        XCTAssertThrowsError(try SyncFiles.snapshot(root: root, entry: expected, to: temp))
    }
    @MainActor func testNativePickerCallbackDeliversSelectedFolder() {
        var received: URL?
        let picker = NativeFolderPicker(onPick: { received = $0 }, onCancel: {})
        let coordinator = picker.makeCoordinator()
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
        coordinator.documentPicker(controller, didPickDocumentsAt: [root])
        XCTAssertEqual(received, root)
    }
}

private final class StockServerProtocol: URLProtocol {
    static var respond: ((URLRequest) throws -> (Int, Any))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let respond = Self.respond, let url = request.url else { throw URLError(.badURL) }
            let (status, json) = try respond(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: json))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class StockServerAPITests: XCTestCase {
    private func server() throws -> Server {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StockServerProtocol.self]
        return try Server(address: "http://stock-lincy.invalid:8091", wifiOnly: true, sessionConfiguration: config)
    }
    override func tearDown() { StockServerProtocol.respond = nil }
    func testUsesStockListingsForExactFileSizes() async throws {
        StockServerProtocol.respond = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "vuio_session=test")
            let c = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let path = c.queryItems?.first { $0.name == "path" }?.value ?? ""
            if c.path == "/api/upload-contents" {
                if path.isEmpty { return (200, ["path": "/actual/upload", "entries": [["name": "Phone", "path": "/actual/upload/Phone", "is_dir": true]]]) }
                return (200, ["path": "/actual/upload/Phone", "entries": [["name": "A", "path": "/actual/upload/Phone/A", "is_dir": false]]])
            }
            XCTAssertEqual(c.path, "/api/files")
            XCTAssertEqual(path, "Phone")
            return (200, [["name": "A", "size": 123, "is_dir": false]])
        }
        let result = try await server().legacyUploadManifest(root: "Phone", sharedRoot: true, cookie: "vuio_session=test")
        XCTAssertEqual(result.count, 1); XCTAssertEqual(result[0].path, "A"); XCTAssertEqual(result[0].size, 123)
    }
    func testPermissionFailureIsNotMisreportedAsEmptyDirectory() async throws {
        StockServerProtocol.respond = { _ in (403, ["error": "denied"]) }
        do {
            _ = try await server().legacyUploadManifest(root: "Phone", sharedRoot: true, cookie: "vuio_session=test")
            XCTFail("A failed scan must not become an empty manifest")
        } catch { XCTAssertTrue(error.localizedDescription.contains("403")) }
    }
    func testDirectoryCreationUsesPathNotParentParameter() async throws {
        var seenPath: String?
        StockServerProtocol.respond = { request in
            if request.httpMethod == "GET" { return (200, ["path": "/upload", "entries": []]) }
            let data: Data
            if let body = request.httpBody { data = body }
            else if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; bytes.append(contentsOf: buffer.prefix(n)) }
                data = bytes
            } else { throw URLError(.badServerResponse) }
            let body = try JSONSerialization.jsonObject(with: data) as! [String: String]
            XCTAssertNil(body["parent"]); XCTAssertEqual(body["conflict"], "overwrite")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-vuio-upload"), "1")
            seenPath = body["path"]
            return (200, ["directory": "Phone", "skipped": false])
        }
        try await server().ensureUploadDirectory("Phone", cookie: "vuio_session=test")
        XCTAssertEqual(seenPath, "")
    }
    func testDownloadManifestRecursesAndPreservesEmptyDirectories() async throws {
        StockServerProtocol.respond = { request in
            XCTAssertEqual(request.url?.path, "/api/files")
            let c = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let path = c.queryItems?.first { $0.name == "path" }?.value ?? ""
            switch path {
            case "": return (200, [["name": "Movies", "size": 0, "is_dir": true]])
            case "Movies": return (200, [["name": "A.mp4", "size": 4, "is_dir": false], ["name": "empty", "size": 0, "is_dir": true]])
            case "Movies/empty": return (200, [])
            default: throw URLError(.badURL)
            }
        }
        let manifest = try await server().legacyDownloadManifest(root: "Movies", cookie: "vuio_session=test")
        XCTAssertEqual(manifest.kind, "dir")
        XCTAssertEqual(Set(manifest.entries.map(\.path)), Set(["A.mp4", "empty"]))
    }
}
