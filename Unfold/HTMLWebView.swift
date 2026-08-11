import SwiftUI
import AppKit
import WebKit

/// Shows an HTML file in the folder browser's detail pane.
///
/// Deliberately separate from `MarkdownWebView`: that one owns a generated
/// shell, renders Markdown into it through `_render`, and keeps a bridge alive
/// for the TOC, the editor and scroll sync. An HTML file is already a page, so
/// WebKit loads it straight from disk and everything it references —
/// stylesheets, scripts, images, sibling pages — resolves relative to it the way
/// it would in a browser. None of the Markdown machinery applies, and the file
/// is never edited here.
///
/// Following a link, though, is the app's business rather than WebKit's: a page
/// that navigated itself would leave the sidebar pointing at the old file and
/// the window's history none the wiser. Link activations are intercepted and
/// handed to `NavigationState.openFile`, so an HTML page reaches another file
/// exactly the way a Markdown link does — one history, one selection.
struct HTMLWebView: NSViewRepresentable {
    let fileURL: URL

    /// The folder the browser is showing. Read access is granted for the whole
    /// tree, not just the file's own directory, so a page that pulls its CSS
    /// from a shared folder further up still renders.
    let readAccessRoot: URL

    let appearance: AppearanceMode
    let navigationState: NavigationState

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "scrollState")
        config.userContentController.addUserScript(WKUserScript(
            source: Self.scrollReporter,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.appearance = appearance.nsAppearance

        context.coordinator.webView = webView
        context.coordinator.fileURL = fileURL
        context.coordinator.navigationState = navigationState
        context.coordinator.watch(fileURL)

        // The reader has no bridge to a Markdown coordinator here, so Reload has
        // to be told what it means for this pane.
        navigationState.reloadDisplay = { [weak webView] in webView?.reload() }

        // Both sides must be the *same* spelling of the path, or WebKit refuses
        // the load as being outside the directory it just granted.
        webView.loadFileURL(fileURL.physicalURL, allowingReadAccessTo: readAccessRoot.physicalURL)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.appearance = appearance.nsAppearance
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Reports the scroll offset, so the window's history can stamp it into the
    /// entry it leaves and land back here on the way in. The same job the
    /// Markdown shell's own listener does, and throttled the same way.
    private static let scrollReporter = """
    (function() {
        var timer = null;
        window.addEventListener('scroll', function() {
            if (timer) return;
            timer = setTimeout(function() {
                timer = null;
                window.webkit.messageHandlers.scrollState.postMessage({ y: window.scrollY });
            }, 100);
        });
    })();
    """

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var fileURL: URL?
        var navigationState: NavigationState?
        private var watcher: FileWatcher?

        /// Pick up edits made elsewhere, as the Markdown side does.
        func watch(_ url: URL) {
            watcher = FileWatcher(url: url) { [weak self] in
                self?.webView?.reload()
            }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "scrollState",
                  let dict = message.body as? [String: Any],
                  let y = dict["y"] as? Double else { return }
            navigationState?.currentScrollY = y
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // A history move parks the offset until the file it belongs to is on
            // screen; keyed by URL, so the page being left can't consume it.
            guard let pending = navigationState?.pendingScroll, pending.url == fileURL else { return }
            navigationState?.pendingScroll = nil
            webView.evaluateJavaScript("window.scrollTo(0, \(pending.scrollY))", completionHandler: nil)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            // The web belongs in a browser.
            if url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            // Everything else the page does to itself — the initial load, a
            // redirect, an iframe — is WebKit's business. Only a link the reader
            // clicked in the page itself becomes a navigation of the window's.
            guard navigationAction.navigationType == .linkActivated,
                  navigationAction.targetFrame?.isMainFrame != false,
                  url.isFileURL else {
                decisionHandler(.allow)
                return
            }

            // A jump within the same page stays a jump within the same page.
            if isSameDocument(url, as: webView.url) {
                decisionHandler(.allow)
                return
            }

            decisionHandler(.cancel)
            let target = url.physicalURL
            if FileNode.isViewable(target) {
                // Selects it in the sidebar and records it in the history —
                // or opens a window of its own if it lies outside the folder.
                if let openFile = navigationState?.openFile {
                    openFile(target)
                } else {
                    NavigationState.openInNewWindow(target)
                }
            } else {
                // Not something this app shows: a PDF, an archive, a stray
                // spreadsheet. The system knows what to do with it.
                NSWorkspace.shared.open(target)
            }
        }

        /// Whether these two differ only by their fragment.
        private func isSameDocument(_ url: URL, as current: URL?) -> Bool {
            guard let current else { return false }
            var target = URLComponents(url: url, resolvingAgainstBaseURL: false)
            var here = URLComponents(url: current, resolvingAgainstBaseURL: false)
            target?.fragment = nil
            here?.fragment = nil
            return target?.url == here?.url
        }
    }
}
