import SwiftUI
import AppKit
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
    var appearanceMode: AppearanceMode = .system
    var headings: [HeadingItem] = []
    var activeHeadingSlug: String?
    var isEditing = false
    weak var coordinator: MarkdownWebView.Coordinator?

    /// Set by whichever view owns the file (`ContentView` / `FolderBrowserView`)
    /// so Reload can re-read from disk rather than merely re-rendering the text
    /// already in memory. Returns the text to render.
    var reloadFromDisk: (() -> String)?

    /// The file being shown, set by its owner. An external editor is handed a
    /// path, so there is nothing to open while this is nil (an unsaved File > New).
    var fileURL: URL?

    /// Set by the file's owner to write pending edits to disk immediately.
    /// An external editor reads the file, so in-memory work has to land first.
    var flushPendingEdits: (() -> Void)?

    /// Set by the file's owner to follow a Markdown link to another file in the
    /// same folder. The folder browser shows it in place (selecting it in the
    /// sidebar); left unset, the link opens in a new document window.
    var openFile: ((URL) -> Void)?

    /// Set by a pane that reloads itself rather than through the Markdown
    /// coordinator — an HTML page has no bridge, so Reload is just WebKit's.
    var reloadDisplay: (() -> Void)?

    /// Set by the folder browser to re-read its tree. Left nil by the
    /// single-document window, which has no tree — and that is what the
    /// View ▸ Refresh Folder command keys its availability off.
    var refreshTree: (() -> Void)?

    /// Open a Markdown file in a document window of its own — the fallback when
    /// the current window can't show it itself.
    static func openInNewWindow(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if error != nil { NSWorkspace.shared.open(url) }
        }
    }

    /// Whether what's on screen can be edited at all. Cleared for an HTML page,
    /// which WebKit displays rather than the source editor, and for every file in
    /// an unpacked archive, where an edit would be written to a cached copy the
    /// archive never sees. Better to offer no editing than editing that quietly
    /// goes nowhere.
    var isEditable = true

    /// Edit is unavailable when an external editor is configured but the document
    /// has never been saved — there is no path to hand over.
    var canEdit: Bool {
        guard isEditable else { return false }
        return !ExternalEditor.shared.isEnabled || fileURL != nil
    }

    /// The Edit action behind the toolbar button and Cmd+Shift+E.
    ///
    /// With an external editor configured this deliberately never touches
    /// `isEditing`: that would widen the window (`adjustWindow(forEditing:)`) to
    /// make room for a source editor that is never going to appear.
    func edit() {
        guard ExternalEditor.shared.isEnabled else {
            isEditing.toggle()
            return
        }
        guard let fileURL else { return }
        flushPendingEdits?()
        ExternalEditor.shared.open(fileURL)
    }

    /// Label for the Edit affordance, which stops being a toggle in external mode.
    var editLabel: String {
        if ExternalEditor.shared.isEnabled {
            return "Edit in \(ExternalEditor.shared.applicationName ?? "External Editor")"
        }
        return isEditing ? "Done Editing" : "Edit"
    }

    /// Reload: pick up external edits, then render immediately.
    ///
    /// The fresh text is handed straight to the coordinator rather than left for
    /// SwiftUI to propagate — `updateNSView` won't have run yet at this point, so
    /// rendering off `lastMarkdown` here would show the stale copy.
    func reload() {
        if let reloadDisplay {
            reloadDisplay()
        } else if let text = reloadFromDisk?() {
            coordinator?.render(markdown: text)
        } else {
            coordinator?.reload()
        }
    }

    // MARK: - Navigation history

    /// One place the reader has been: a file and how far down it they were.
    ///
    /// A jump to a heading is an entry of its own, as it is in a browser — only
    /// the scroll offset distinguishes it from its neighbours. `url` is optional
    /// because an unsaved File > New document has no path; such a window simply
    /// has a single file's worth of history.
    private struct HistoryEntry {
        let url: URL?
        var scrollY: Double
    }

    private var history: [HistoryEntry] = []
    private var historyIndex = -1

    /// Where the page is scrolled to right now, reported by the page as it
    /// scrolls. It is stamped into the current entry whenever we leave it, so
    /// going back lands where the reader left off rather than at the top.
    var currentScrollY: Double = 0

    /// A scroll position waiting for its file to finish rendering, consumed by
    /// that file's coordinator. Keyed by URL because a history move replaces the
    /// whole web view: the outgoing one must not swallow the incoming one's
    /// restore on its way out.
    var pendingScroll: (url: URL, scrollY: Double)?

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex >= 0 && historyIndex < history.count - 1 }

    /// Record arriving at a file — a sidebar selection, a followed link, or the
    /// first file the window shows. Anything ahead is dropped, exactly as a
    /// browser discards the forward stack when you follow a new link.
    ///
    /// Arriving at the file we are already on is not a navigation, which is also
    /// what makes a history move self-cancelling: `go(to:)` moves the index
    /// first and only then asks the owner to select that file, so the selection
    /// it triggers lands here and matches.
    func navigated(to url: URL?) {
        if historyIndex >= 0, history[historyIndex].url == url { return }
        stampScroll()
        history.removeSubrange((historyIndex + 1)...)
        history.append(HistoryEntry(url: url, scrollY: 0))
        historyIndex = history.count - 1
        currentScrollY = 0
    }

    /// Record an in-page jump (a TOC entry, a `#heading` link). The entry we are
    /// leaving keeps the position it was at before the jump; the new entry's own
    /// position is stamped later, when it is left in turn — by then the smooth
    /// scroll has settled and the page has reported where it ended up.
    func navigatedInPage() {
        guard historyIndex >= 0 else { return }
        stampScroll()
        history.removeSubrange((historyIndex + 1)...)
        history.append(HistoryEntry(url: history[historyIndex].url, scrollY: 0))
        historyIndex = history.count - 1
    }

    func goBack() { go(to: historyIndex - 1) }
    func goForward() { go(to: historyIndex + 1) }

    private func go(to index: Int) {
        guard history.indices.contains(index), index != historyIndex else { return }
        stampScroll()
        let leaving = history[historyIndex]
        historyIndex = index
        let entry = history[index]
        currentScrollY = entry.scrollY

        guard entry.url != leaving.url, let url = entry.url else {
            coordinator?.scroll(to: entry.scrollY)
            return
        }
        pendingScroll = (url, entry.scrollY)
        openFile?(url)
    }

    private func stampScroll() {
        guard historyIndex >= 0 else { return }
        history[historyIndex].scrollY = currentScrollY
    }
}

struct MarkdownWebView: NSViewRepresentable {
    let markdown: String
    let fileURL: URL?
    let navigationState: NavigationState

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "tocData")
        config.userContentController.add(context.coordinator, name: "scrollState")
        config.userContentController.add(context.coordinator, name: "historyPush")
        config.userContentController.add(context.coordinator, name: "openLink")
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

            case "scrollState":
                guard let dict = message.body as? [String: Any] else { return }
                if let y = dict["y"] as? Double {
                    navigationState?.currentScrollY = y
                }
                guard !suppressScrollTracking,
                      let slug = dict["heading"] as? String else { return }
                navigationState?.activeHeadingSlug = slug

            case "historyPush":
                navigationState?.navigatedInPage()

            case "openLink":
                guard let href = message.body as? String else { return }
                openLocalLink(href)

            default:
                break
            }
        }

        /// Follow a link to a path on disk, resolved against the document's own
        /// folder. Markdown is opened by the app (in place where the owner
        /// supplied `openFile`, otherwise in a new window); anything else is
        /// handed to the system, which picks the right application for it.
        func openLocalLink(_ href: String) {
            guard let baseDirectory = fileURL?.deletingLastPathComponent() else { return }

            // A #fragment or ?query is no part of the path on disk.
            var path = href
            if let cut = path.firstIndex(where: { $0 == "#" || $0 == "?" }) {
                path = String(path[..<cut])
            }
            let decoded = path.removingPercentEncoding ?? path
            guard !decoded.isEmpty else { return }

            let target = (decoded.hasPrefix("/")
                ? URL(fileURLWithPath: decoded)
                : baseDirectory.appendingPathComponent(decoded)).standardizedFileURL

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
                NSSound.beep()
                return
            }

            if !isDirectory.boolValue, FileNode.isViewable(target) {
                if let openFile = navigationState?.openFile {
                    openFile(target)
                } else {
                    NavigationState.openInNewWindow(target)
                }
            } else {
                NSWorkspace.shared.open(target)
            }
        }

        /// Jump straight to a scroll offset — a history restore, so no smooth
        /// animation: the reader is going back to where they were, not being
        /// taken somewhere new.
        func scroll(to y: Double) {
            webView?.evaluateJavaScript("window.scrollTo(0, \(y))", completionHandler: nil)
        }

        func reload() {
            // Force a full preview re-render from the current in-memory text.
            // Never reads disk, so it's safe while editing.
            renderNow()
        }

        /// Render `markdown` immediately, bypassing the debounce, and treat it as
        /// the current text — so the `updateNSView` that follows sees no change
        /// and doesn't render it a second time.
        func render(markdown: String) {
            lastMarkdown = markdown
            renderNow()
        }

        func setAppearance(_ mode: AppearanceMode) {
            webView?.appearance = mode.nsAppearance
        }

        /// Widen the window to make room for the editor pane when entering edit
        /// mode, and shrink it back to the viewer's size when leaving. The right
        /// edge is anchored — the window grows/shrinks on the left, so the
        /// preview stays put while the editor slides in. Clamped to the screen
        /// and animated.
        func adjustWindow(forEditing editing: Bool, by delta: CGFloat = 600) {
            guard let window = webView?.window else { return }
            var frame = window.frame
            let rightEdge = frame.maxX
            frame.size.width = editing
                ? frame.size.width + delta
                : max(frame.size.width - delta, 300)

            if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
                frame.size.width = min(frame.size.width, visible.size.width)
            }

            // Anchor the right edge: keep maxX fixed, move the left edge.
            frame.origin.x = rightEdge - frame.size.width

            if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
                if frame.minX < visible.minX {
                    frame.origin.x = visible.minX
                }
                if frame.maxX > visible.maxX {
                    frame.origin.x = visible.maxX - frame.size.width
                }
            }

            let target = frame
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(target, display: true)
            }
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
                completionHandler: { [weak self] _ in self?.restorePendingScroll() }
            )
        }

        /// A history move sets the scroll position aside until the file it
        /// belongs to has been rendered — there is nothing to scroll before that.
        private func restorePendingScroll() {
            guard let pending = navigationState?.pendingScroll, pending.url == fileURL else { return }
            navigationState?.pendingScroll = nil
            scroll(to: pending.scrollY)
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
            guard let url = navigationAction.request.url, let scheme = url.scheme else {
                decisionHandler(.allow)
                return
            }
            if scheme == "http" || scheme == "https" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else if scheme == "unfold-resource", navigationAction.navigationType == .linkActivated {
                // A relative link the page's click handler didn't intercept.
                // Its href was resolved against unfold-resource://page, so the
                // path is really relative to the document's folder — following
                // it as a navigation would just re-serve the shell.
                let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .percentEncodedPath ?? url.path
                openLocalLink(String(encodedPath.drop(while: { $0 == "/" })))
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
