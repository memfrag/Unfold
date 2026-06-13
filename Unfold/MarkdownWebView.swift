import SwiftUI
import WebKit
import UniformTypeIdentifiers

enum AppearanceMode: CaseIterable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@Observable
class NavigationState {
    var canGoBack = false
    var canGoForward = false
    var appearanceMode: AppearanceMode = .system
    var headings: [HeadingItem] = []
    var activeHeadingSlug: String?
    var isEditing = false
    weak var coordinator: MarkdownWebView.Coordinator?
}

struct MarkdownWebView: NSViewRepresentable {
    let markdown: String
    let fileURL: URL?
    let navigationState: NavigationState

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "navState")
        config.userContentController.add(context.coordinator, name: "tocData")
        config.userContentController.add(context.coordinator, name: "activeHeading")
        let baseDir = fileURL?.deletingLastPathComponent()
        let schemeHandler = LocalResourceSchemeHandler(baseDirectory: baseDir)
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "unfold-resource")
        context.coordinator.schemeHandler = schemeHandler
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        #if DEBUG
        webView.isInspectable = true
        #endif
        context.coordinator.webView = webView
        context.coordinator.navigationState = navigationState
        navigationState.coordinator = context.coordinator
        context.coordinator.fileURL = fileURL
        context.coordinator.lastMarkdown = markdown
        context.coordinator.loadShell(in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard markdown != context.coordinator.lastMarkdown else { return }
        context.coordinator.lastMarkdown = markdown
        // Live edits re-render in place (preserving scroll) after a debounce.
        // The very first render is driven from didFinish once the page loads.
        if context.coordinator.isPageLoaded {
            context.coordinator.scheduleRender()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var lastMarkdown: String?
        weak var webView: WKWebView?
        var navigationState: NavigationState?
        var schemeHandler: LocalResourceSchemeHandler?
        var fileURL: URL?
        var isPageLoaded = false
        private var renderWorkItem: DispatchWorkItem?
        private var syncWorkItem: DispatchWorkItem?
        private var pendingSyncLine: Int?

        /// Debounce for in-place preview re-renders while typing.
        private let renderDebounce: TimeInterval = 1.0

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            switch message.name {
            case "navState":
                guard let dict = message.body as? [String: Bool] else { return }
                navigationState?.canGoBack = dict["canGoBack"] ?? false
                navigationState?.canGoForward = dict["canGoForward"] ?? false

            case "tocData":
                guard let list = message.body as? [[String: Any]] else { return }
                let flat = list.compactMap { entry -> (text: String, depth: Int, slug: String)? in
                    guard let text = entry["text"] as? String,
                          let depth = entry["depth"] as? Int,
                          let slug = entry["slug"] as? String else { return nil }
                    return (text, depth, slug)
                }
                var newHeadings = buildHeadingTree(from: flat)
                if let nav = navigationState, !nav.headings.isEmpty {
                    preserveExpansionState(in: &newHeadings, from: nav.headings)
                }
                navigationState?.headings = newHeadings

            case "activeHeading":
                guard !suppressScrollTracking,
                      let slug = message.body as? String else { return }
                navigationState?.activeHeadingSlug = slug

            default:
                break
            }
        }

        func goBack() {
            webView?.evaluateJavaScript("window._goBack()", completionHandler: nil)
        }

        func goForward() {
            webView?.evaluateJavaScript("window._goForward()", completionHandler: nil)
        }

        func reload() {
            // Force a full preview re-render from the current in-memory text.
            // Never reads disk, so it's safe while editing.
            renderNow()
        }

        func setAppearance(_ mode: AppearanceMode) {
            webView?.appearance = mode.nsAppearance
        }

        private var suppressScrollTracking = false

        func scrollToHeading(_ slug: String) {
            navigationState?.activeHeadingSlug = slug
            suppressScrollTracking = true
            webView?.evaluateJavaScript("window._scrollToHeading('\(slug)')", completionHandler: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.suppressScrollTracking = false
            }
        }

        /// Loads the static HTML shell. The Markdown itself is rendered into the
        /// page by `renderNow()` once `didFinish` fires.
        func loadShell(in webView: WKWebView) {
            isPageLoaded = false
            schemeHandler?.pendingHTML = buildHTML()
            webView.load(URLRequest(url: URL(string: "unfold-resource://page")!))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isPageLoaded = true
            renderNow()
        }

        /// Re-render the current Markdown in place, immediately.
        func renderNow() {
            renderWorkItem?.cancel()
            renderWorkItem = nil
            guard isPageLoaded, let webView, let markdown = lastMarkdown else { return }
            webView.callAsyncJavaScript(
                "window._render(md)",
                arguments: ["md": markdown],
                in: nil,
                in: .page,
                completionHandler: nil
            )
        }

        /// Schedule a debounced in-place re-render (used while typing).
        func scheduleRender() {
            renderWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.renderNow() }
            renderWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + renderDebounce, execute: item)
        }

        /// Editor → preview sync: scroll the preview to the block at `line`.
        /// Throttled so a stream of caret events doesn't flood the bridge.
        func syncToLine(_ line: Int) {
            pendingSyncLine = line
            guard syncWorkItem == nil else { return }
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.syncWorkItem = nil
                guard self.isPageLoaded, let webView = self.webView,
                      let l = self.pendingSyncLine else { return }
                webView.callAsyncJavaScript(
                    "window._syncToLine(line)",
                    arguments: ["line": l],
                    in: nil,
                    in: .page,
                    completionHandler: nil
                )
            }
            syncWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
        }

        func exportPDF() {
            guard let webView else { return }
            let savedAppearance = webView.appearance
            webView.appearance = NSAppearance(named: .aqua)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                let config = WKPDFConfiguration()
                webView.createPDF(configuration: config) { result in
                    DispatchQueue.main.async {
                        webView.appearance = savedAppearance
                    }
                    switch result {
                    case .success(let data):
                        let panel = NSSavePanel()
                        if let fileURL = self.fileURL {
                            let baseName = fileURL.deletingPathExtension().lastPathComponent
                            panel.nameFieldStringValue = "\(baseName).pdf"
                        } else {
                            panel.nameFieldStringValue = "Untitled.pdf"
                        }
                        panel.allowedContentTypes = [UTType.pdf]
                        guard let win = webView.window else { return }
                        panel.beginSheetModal(for: win) { response in
                            guard response == .OK, let url = panel.url else { return }
                            do {
                                try data.write(to: url)
                            } catch {
                                let alert = NSAlert()
                                alert.messageText = "Failed to save PDF"
                                alert.informativeText = error.localizedDescription
                                alert.runModal()
                            }
                        }
                    case .failure(let error):
                        let alert = NSAlert()
                        alert.messageText = "Failed to create PDF"
                        alert.informativeText = error.localizedDescription
                        alert.runModal()
                    }
                }
            }
        }

        func printDocument() {
            guard let webView, let win = webView.window else { return }
            let printInfo = NSPrintInfo.shared
            let operation = webView.printOperation(with: printInfo)
            operation.runModal(for: win, delegate: nil, didRun: nil, contextInfo: nil)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url,
               let scheme = url.scheme,
               scheme == "http" || scheme == "https" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

class LocalResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    let baseDirectory: URL?
    var pendingHTML: String?

    init(baseDirectory: URL?) {
        self.baseDirectory = baseDirectory
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        // Serve the main HTML page
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

        // Serve local resource files
        guard let resolveDir = baseDirectory, url.host == "resource" else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        // Path is /docs/images/file.png — strip leading slash
        let rawPath = String(url.path.dropFirst())
        let decodedPath = rawPath.removingPercentEncoding ?? rawPath
        let fileURL = resolveDir.appendingPathComponent(decodedPath)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            urlSchemeTask.didFailWithError(error)
            return
        }

        let mimeType = mimeTypeForExtension(fileURL.pathExtension)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Type": mimeType,
                "Content-Length": "\(data.count)",
                "Access-Control-Allow-Origin": "*",
                "Cache-Control": "no-cache"
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
