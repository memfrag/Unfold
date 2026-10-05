import SwiftUI
import WebKit

/// Find in the page shown by a web view — the Markdown preview or an HTML file.
///
/// AppKit's find bar (`NSTextFinder`) would be the stock answer, but `WKWebView`
/// doesn't support it publicly: it doesn't respond to `performTextFinderAction:`
/// and sending that crashes. The only public find API, `find(_:configuration:)`,
/// selects one match at a time and can't count them or highlight the rest. So
/// the page searches itself, and `FindBar` is the window's half of it.
///
/// Matches are painted with the CSS Custom Highlight API, which styles ranges
/// without touching the DOM. Wrapping them in `<mark>` would split the text
/// nodes that highlight.js produced and leave elements behind in the page.
enum FindInPage {
    /// More than this and the bar reads "1000+", as Safari's does.
    static let maxMatches = 1000

    static func install(in config: WKWebViewConfiguration, navigationState: NavigationState) {
        config.userContentController.addUserScript(WKUserScript(
            source: script,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        config.userContentController.add(
            ResultHandler(navigationState: navigationState),
            name: "findResult"
        )
    }

    /// Reports the match count and position after every search or step. A
    /// separate object, not a coordinator, so both kinds of web view share it.
    /// The user content controller retains it, so it holds the state weakly.
    private final class ResultHandler: NSObject, WKScriptMessageHandler {
        weak var navigationState: NavigationState?

        init(navigationState: NavigationState) {
            self.navigationState = navigationState
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            // A page on its way out can still report, after its replacement
            // has taken over.
            guard let navigationState, message.webView === navigationState.findTarget,
                  let dict = message.body as? [String: Any],
                  let count = dict["count"] as? Int,
                  let current = dict["current"] as? Int else { return }
            navigationState.findMatchCount = count
            navigationState.findCurrentMatch = current
        }
    }

    /// `window._unfoldFind`: `search(q)` starts a new search at the first match
    /// on screen or below it, `step(±1)` moves through the matches, `refresh()`
    /// re-runs the same query after the Markdown shell re-renders (keeping its
    /// place, not scrolling), `clear()` takes the highlights down, and
    /// `setInset(px)` makes room at the top of the page for the bar.
    ///
    /// The text nodes are searched as one string, so a match can run across
    /// the spans highlight.js puts in code blocks. Matches that aren't rendered
    /// (inside `display: none`) are left out, since stepping to one would show
    /// nothing.
    private static let script = """
    (function() {
        if (window._unfoldFind) return;
        var MAX = \(maxMatches);
        var query = '';
        var ranges = [];
        var current = -1;
        var supported = !!(window.CSS && CSS.highlights && window.Highlight);
        // How much of the top of the window the find bar covers.
        var inset = 0;

        var style = document.createElement('style');
        style.textContent =
            '::highlight(unfold-find) { background-color: rgba(255, 214, 10, 0.45); }' +
            '::highlight(unfold-find-current) { background-color: rgb(255, 159, 10); color: black; }' +
            '@media print { html { margin-top: 0 !important; } }';
        (document.head || document.documentElement).appendChild(style);

        var SKIP = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEXTAREA: 1, TEMPLATE: 1 };

        // Text outside what the reader sees as the page: the shell's copy
        // buttons and link preview, and anything that isn't rendered text.
        function skipped(node) {
            for (var el = node.parentElement; el && el !== document.body; el = el.parentElement) {
                if (SKIP[el.tagName] || el.id === 'link-preview' ||
                    (el.classList && el.classList.contains('copy-btn'))) return true;
            }
            return false;
        }

        function collect() {
            var nodes = [], starts = [], text = '';
            var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
                acceptNode: function(n) {
                    return skipped(n) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
                }
            });
            for (var n = walker.nextNode(); n; n = walker.nextNode()) {
                starts.push(text.length);
                nodes.push(n);
                text += n.data;
            }
            return { nodes: nodes, starts: starts, text: text };
        }

        // The last node starting at or before `offset` — the one containing it.
        function locate(doc, offset) {
            var lo = 0, hi = doc.starts.length - 1;
            while (lo < hi) {
                var mid = (lo + hi + 1) >> 1;
                if (doc.starts[mid] <= offset) lo = mid; else hi = mid - 1;
            }
            return lo;
        }

        function run(q) {
            ranges = [];
            query = q || '';
            if (!query || !document.body) return;
            var doc = collect();
            var hay = doc.text.toLowerCase();
            var needle = query.toLowerCase();
            // Lowercasing can change a string's length (a dotted capital I),
            // which would throw every offset off. Match exactly instead.
            if (hay.length !== doc.text.length) { hay = doc.text; needle = query; }
            var from = 0, at;
            while (ranges.length < MAX && (at = hay.indexOf(needle, from)) !== -1) {
                from = at + needle.length;
                var a = locate(doc, at), b = locate(doc, from - 1);
                var r = document.createRange();
                r.setStart(doc.nodes[a], at - doc.starts[a]);
                r.setEnd(doc.nodes[b], from - doc.starts[b]);
                if (r.getClientRects().length === 0) continue;
                ranges.push(r);
            }
        }

        function paint() {
            if (!supported) {
                var sel = window.getSelection();
                sel.removeAllRanges();
                if (current >= 0) sel.addRange(ranges[current]);
                return;
            }
            CSS.highlights.delete('unfold-find');
            CSS.highlights.delete('unfold-find-current');
            if (!ranges.length) return;
            CSS.highlights.set('unfold-find', new Highlight(...ranges));
            if (current >= 0) {
                var h = new Highlight(ranges[current]);
                h.priority = 1;
                CSS.highlights.set('unfold-find-current', h);
            }
        }

        // Bring the current match on screen: into the middle of the window if
        // it's above or below it, and sideways within any scrolling box it sits
        // in (a long line in a code block).
        function reveal() {
            if (current < 0) return;
            var r = ranges[current];
            for (var el = r.startContainer.parentElement; el && el !== document.body; el = el.parentElement) {
                if (el.scrollWidth > el.clientWidth) {
                    var box = el.getBoundingClientRect(), m = r.getBoundingClientRect();
                    if (m.left < box.left) el.scrollLeft -= box.left - m.left + 24;
                    else if (m.right > box.right) el.scrollLeft += m.right - box.right + 24;
                }
            }
            var rect = r.getBoundingClientRect();
            var margin = 40;
            if (rect.top < inset + margin || rect.bottom > window.innerHeight - margin) {
                var middle = inset + (window.innerHeight - inset) / 2;
                window.scrollBy(0, rect.top - middle + rect.height / 2);
            }
        }

        function post() {
            if (window.webkit && window.webkit.messageHandlers.findResult) {
                window.webkit.messageHandlers.findResult.postMessage({
                    count: ranges.length, current: current
                });
            }
        }

        window._unfoldFind = {
            search: function(q) {
                run(q);
                current = -1;
                for (var i = 0; i < ranges.length; i++) {
                    if (ranges[i].getBoundingClientRect().bottom >= inset) { current = i; break; }
                }
                if (current < 0 && ranges.length) current = 0;
                paint();
                reveal();
                post();
            },
            step: function(delta) {
                if (ranges.length) {
                    current = (current + delta + ranges.length) % ranges.length;
                    paint();
                    reveal();
                }
                post();
            },
            refresh: function() {
                if (!query) return;
                var keep = current;
                run(query);
                current = ranges.length ? Math.min(Math.max(keep, 0), ranges.length - 1) : -1;
                paint();
                post();
            },
            // Make room for the bar by pushing the page down, animated in step
            // with the bar's slide. The web view itself can't follow it: its
            // frame is AppKit's, and SwiftUI would only snap it to size.
            setInset: function(px, animated) {
                var root = document.documentElement;
                root.style.transition = animated ? 'margin-top 0.2s ease-in-out' : '';
                root.style.marginTop = px ? px + 'px' : '';
                inset = px;
            },
            clear: function() {
                run('');
                current = -1;
                paint();
            }
        };
    })();
    """
}

/// The bar above the page while finding: the query, where the current match
/// is among them, and the arrows to step. Return steps forward, Escape closes.
struct FindBar: View {
    let navigationState: NavigationState
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            // The field commits its text again as it loses focus — which is
            // what closing the bar does — so only a real change searches.
            TextField("Find", text: Binding(
                get: { navigationState.findQuery },
                set: { query in
                    guard query != navigationState.findQuery else { return }
                    navigationState.findQuery = query
                    navigationState.searchFind()
                }
            ))
            .textFieldStyle(.roundedBorder)
            // AppKit draws the focus ring outside the view hierarchy, so it
            // appears at once while the bar is still sliding in.
            .focusEffectDisabled()
            .frame(maxWidth: 260)
            .focused($fieldFocused)
            .onSubmit { navigationState.stepFind(1) }
            .onExitCommand { navigationState.hideFindBar() }

            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)

            Spacer(minLength: 0)

            ControlGroup {
                Button {
                    navigationState.stepFind(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Previous")

                Button {
                    navigationState.stepFind(1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .help("Next")
            }
            .fixedSize()
            .disabled(navigationState.findMatchCount == 0)

            Button("Done") { navigationState.hideFindBar() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            navigationState.findBarHeight = height
            navigationState.applyFindInset(animated: true)
        }
        .onAppear { fieldFocused = true }
        .onChange(of: navigationState.findFocusRequest) { fieldFocused = true }
    }

    private var status: String {
        guard !navigationState.findQuery.isEmpty else { return "" }
        let count = navigationState.findMatchCount
        guard count > 0 else { return "No matches" }
        let total = count >= FindInPage.maxMatches ? "\(count)+" : "\(count)"
        return "\(navigationState.findCurrentMatch + 1) of \(total)"
    }
}

extension View {
    /// Shows the find bar over the top of this view while finding, sliding
    /// down from under the toolbar and back up. An overlay rather than a
    /// container, so the web view underneath keeps its identity (and scroll
    /// position) — and an overlay rather than a safe-area inset, so the web
    /// view keeps its size too: an inset resizes it, and that resize can't be
    /// animated. The page makes room for the bar itself (`setInset`).
    ///
    /// The container is what carries the animation (the bar itself comes and
    /// goes), and it clips so the bar emerges from the edge rather than over
    /// the toolbar.
    func findBar(_ navigationState: NavigationState) -> some View {
        overlay(alignment: .top) {
            VStack(spacing: 0) {
                if navigationState.isFinding {
                    FindBar(navigationState: navigationState)
                        .transition(.move(edge: .top))
                }
            }
            .clipped()
            .animation(.easeInOut(duration: 0.2), value: navigationState.isFinding)
        }
    }
}
