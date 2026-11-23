import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

struct SharedFile: Identifiable { let id = UUID(); let url: URL }

struct WebScreen: View {
    let url: URL
    let cookie: String?
    @State private var file: SharedFile?
    @State private var error = ""
    var body: some View {
        VStack(spacing: 0) {
            if !error.isEmpty { Text(error).font(.caption).padding(8) }
            WebContent(url: url, cookie: cookie, onDownload: { file = SharedFile(url: $0) }, onError: { error = $0 })
        }.sheet(item: $file) { ShareSheet(url: $0.url) }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct WebContent: UIViewRepresentable {
    let url: URL
    let cookie: String?
    let onDownload: (URL) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        if let cookie, let host = url.host,
           let value = cookie.split(separator: "=", maxSplits: 1).last,
           let item = HTTPCookie(properties: [.domain: host, .path: "/api/", .name: "vuio_session",
                .value: String(value), .expires: Date().addingTimeInterval(43200)]) {
            web.configuration.websiteDataStore.httpCookieStore.setCookie(item) { web.load(URLRequest(url: self.url)) }
        } else { web.load(URLRequest(url: url)) }
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate,
                             UIDocumentPickerDelegate {
        let parent: WebContent
        var downloads: [ObjectIdentifier: URL] = [:]
        init(_ parent: WebContent) { self.parent = parent }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
        }
        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }
        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }
        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appendingPathComponent((suggestedFilename as NSString).lastPathComponent)
                downloads[ObjectIdentifier(download)] = file
                completionHandler(file)
            } catch { parent.onError(error.localizedDescription); completionHandler(nil) }
        }
        func downloadDidFinish(_ download: WKDownload) {
            if let file = downloads.removeValue(forKey: ObjectIdentifier(download)) { parent.onDownload(file) }
        }
        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            downloads.removeValue(forKey: ObjectIdentifier(download))
            parent.onError(error.localizedDescription)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.onError("页面加载失败：\(error.localizedDescription)。请检查服务端及网络后重新连接。")
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            webView.load(navigationAction.request); return nil
        }
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = UIAlertController(title: "linCY", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
            guard let controller = presenter(webView) else { completionHandler(); return }
            controller.present(alert, animated: true)
        }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = UIAlertController(title: "linCY", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
            guard let controller = presenter(webView) else { completionHandler(false); return }
            controller.present(alert, animated: true)
        }
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            let alert = UIAlertController(title: "linCY", message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
            guard let controller = presenter(webView) else { completionHandler(nil); return }
            controller.present(alert, animated: true)
        }
        private func presenter(_ webView: WKWebView) -> UIViewController? {
            var controller = webView.window?.rootViewController
            while let presented = controller?.presentedViewController { controller = presented }
            return controller
        }

        // MARK: - 网页里的文件 / 文件夹选择

        private var filePickerCompletion: (([URL]?) -> Void)?

        /// WKWebView 默认不处理 <input type="file">，必须由宿主 App 弹出选择器。
        /// 这是 WKUIDelegate 的 optional 方法，签名必须与 SDK 一致。
        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping ([URL]?) -> Void) {
            var allowsDirectories = false
            let selector = NSSelectorFromString("allowsDirectories")
            if parameters.responds(to: selector) {
                allowsDirectories = (parameters.value(forKey: "allowsDirectories") as? Bool) ?? false
            }

            let types: [UTType] = allowsDirectories ? [.folder] : [.data]
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
            picker.allowsMultipleSelection = false
            picker.delegate = self

            filePickerCompletion = completionHandler
            guard let host = presenter(webView) else {
                filePickerCompletion = nil
                completionHandler(nil)
                return
            }
            host.present(picker, animated: true)
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            let completion = filePickerCompletion
            filePickerCompletion = nil
            completion?(urls.isEmpty ? nil : urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            let completion = filePickerCompletion
            filePickerCompletion = nil
            completion?(nil)
        }
    }
}
