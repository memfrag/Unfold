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
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        context.coordinator.webView = webView
        context.coordinator.navigationState = navigationState
        navigationState.coordinator = context.coordinator
        let html = buildHTML(markdown: markdown, title: "")
        webView.loadHTMLString(html, baseURL: nil)
        context.coordinator.lastMarkdown = markdown
        if let fileURL {
            context.coordinator.startFileWatching(url: fileURL)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard markdown != context.coordinator.lastMarkdown else { return }
        let html = buildHTML(markdown: markdown, title: "")
        webView.loadHTMLString(html, baseURL: nil)
        context.coordinator.lastMarkdown = markdown
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var lastMarkdown: String?
        weak var webView: WKWebView?
        var navigationState: NavigationState?
        private var fileWatcher: FileWatcher?
        private var fileURL: URL?

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

        func startFileWatching(url: URL) {
            fileURL = url
            fileWatcher = FileWatcher(path: url.path) { [weak self] in
                self?.reloadFromDisk()
            }
        }

        func goBack() {
            webView?.evaluateJavaScript("window._goBack()", completionHandler: nil)
        }

        func goForward() {
            webView?.evaluateJavaScript("window._goForward()", completionHandler: nil)
        }

        func reload() {
            reloadFromDisk()
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

        private func reloadFromDisk() {
            guard let fileURL,
                  let data = FileManager.default.contents(atPath: fileURL.path),
                  let markdown = String(data: data, encoding: .utf8) else {
                // Fall back to last known markdown
                guard let markdown = lastMarkdown else { return }
                let html = buildHTML(markdown: markdown, title: "")
                webView?.loadHTMLString(html, baseURL: nil)
                return
            }
            lastMarkdown = markdown
            let html = buildHTML(markdown: markdown, title: "")
            webView?.loadHTMLString(html, baseURL: nil)
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
