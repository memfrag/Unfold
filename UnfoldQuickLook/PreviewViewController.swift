import Cocoa
import QuickLookUI
import WebKit

class PreviewViewController: NSViewController, QLPreviewingController {

    private var webView: WKWebView?
    private var schemeHandler: PreviewResourceSchemeHandler?
    private var completionHandler: ((Error?) -> Void)?

    override func loadView() {
        view = NSView()
    }

    func preparePreviewOfFile(
        at url: URL,
        completionHandler handler: @escaping (Error?) -> Void
    ) {
        let markdown: String
        do {
            markdown = try String(contentsOf: url, encoding: .utf8)
        } catch {
            handler(error)
            return
        }

        let schemeHandler = PreviewResourceSchemeHandler(
            baseDirectory: url.deletingLastPathComponent()
        )
        schemeHandler.pendingHTML = buildHTML(markdown: markdown, title: url.lastPathComponent)
        self.schemeHandler = schemeHandler

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "unfold-resource")

        let webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .clear
        view.addSubview(webView)
        self.webView = webView

        completionHandler = handler
        webView.load(URLRequest(url: URL(string: "unfold-resource://page")!))
    }
}

extension PreviewViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        completionHandler?(nil)
        completionHandler = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        completionHandler?(error)
        completionHandler = nil
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // The preview is read-only; only the initial page load may navigate.
        if navigationAction.request.url?.scheme == "unfold-resource" {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }
}

// Serves the rendered page and local images referenced by the markdown.
// The Quick Look sandbox only guarantees read access to the previewed file
// itself, so sibling images may fail to load; that failure is graceful.
class PreviewResourceSchemeHandler: NSObject, WKURLSchemeHandler {

    let baseDirectory: URL
    var pendingHTML: String?

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        if url.host == "page" {
            guard let html = pendingHTML, let data = html.data(using: .utf8) else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
            return
        }

        guard url.host == "resource" else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        // Path is /docs/images/file.png — strip leading slash
        let rawPath = String(url.path.dropFirst())
        let decodedPath = rawPath.removingPercentEncoding ?? rawPath
        let fileURL = baseDirectory.appendingPathComponent(decodedPath)

        guard let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Type": mimeTypeForExtension(fileURL.pathExtension),
                "Content-Length": "\(data.count)"
            ]
        )!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private func mimeTypeForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "webp": "image/webp"
        case "bmp": "image/bmp"
        case "ico": "image/x-icon"
        default: "application/octet-stream"
        }
    }
}
