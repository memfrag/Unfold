import Foundation

private func loadBundleResource(_ name: String, _ ext: String) -> String {
    guard let url = Bundle.main.url(forResource: name, withExtension: ext),
          let contents = try? String(contentsOf: url, encoding: .utf8) else {
        return ""
    }
    return contents
}

/// Builds the static HTML shell. The page starts with an empty `#content`;
/// the actual Markdown is rendered by calling `window._render(md)` from Swift
/// once the page has loaded (see MarkdownWebView). This keeps a single render
/// path and avoids embedding/escaping the Markdown into the document.
func buildHTML() -> String {
    let markedJS = loadBundleResource("marked.min", "js")
    let highlightJS = loadBundleResource("highlight.min", "js")
    let highlightLightCSS = loadBundleResource("theme.min", "css")
    let highlightDarkCSS = loadBundleResource("theme-dark.min", "css")

    return """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title></title>
    <style>
    :root {
        --bg: #ffffff;
        --fg: #1d1d1f;
        --fg-secondary: #6e6e73;
        --link: #0066cc;
        --border: #d2d2d7;
        --code-bg: #f5f5f7;
        --code-fg: #1d1d1f;
        --blockquote-border: #0066cc;
        --blockquote-bg: #f5f5f7;
        --table-header-bg: #f5f5f7;
        --table-border: #d2d2d7;
        --error: #d70015;
    }

    @media (prefers-color-scheme: dark) {
        :root {
            --bg: #1d1d1f;
            --fg: #f5f5f7;
            --fg-secondary: #a1a1a6;
            --link: #4da3ff;
            --border: #424245;
            --code-bg: #2c2c2e;
            --code-fg: #f5f5f7;
            --blockquote-border: #4da3ff;
            --blockquote-bg: #2c2c2e;
            --table-header-bg: #2c2c2e;
            --table-border: #424245;
            --error: #ff6961;
        }
    }

    * {
        margin: 0;
        padding: 0;
        box-sizing: border-box;
    }

    html {
        font-size: 16px;
        -webkit-text-size-adjust: 100%;
    }

    body {
        font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", Helvetica, Arial, sans-serif;
        font-size: 1rem;
        line-height: 1.6;
        color: var(--fg);
        background: var(--bg);
        margin: 0;
        padding: 2rem 3rem 4rem;
        -webkit-font-smoothing: antialiased;
    }

    h1, h2, h3, h4, h5, h6 {
        margin-top: 1.5em;
        margin-bottom: 0.5em;
        font-weight: 600;
        line-height: 1.3;
    }

    h1 { font-size: 2rem; margin-top: 0; }
    h2 { font-size: 1.5rem; }
    h3 { font-size: 1.25rem; }
    h4 { font-size: 1.1rem; }
    h5 { font-size: 1rem; }
    h6 { font-size: 0.9rem; color: var(--fg-secondary); }

    h1 + h2, h2 + h3, h3 + h4 {
        margin-top: 0.5em;
    }

    p {
        margin-bottom: 1em;
    }

    a {
        color: var(--link);
        text-decoration: none;
    }

    a:hover {
        text-decoration: underline;
    }

    strong { font-weight: 600; }

    img {
        max-width: 100%;
        height: auto;
        border-radius: 6px;
        margin: 0.5em 0;
    }

    hr {
        border: none;
        border-top: 1px solid var(--border);
        margin: 2em 0;
    }

    ul, ol {
        margin-bottom: 1em;
        padding-left: 1.5em;
    }

    li {
        margin-bottom: 0.25em;
    }

    li > ul, li > ol {
        margin-bottom: 0;
        margin-top: 0.25em;
    }

    blockquote {
        border-left: 3px solid var(--blockquote-border);
        background: var(--blockquote-bg);
        margin: 1em 0;
        padding: 0.75em 1em;
        border-radius: 0 6px 6px 0;
    }

    blockquote p:last-child {
        margin-bottom: 0;
    }

    code {
        font-family: "SF Mono", Menlo, Consolas, "Liberation Mono", monospace;
        font-size: 0.875em;
        background: var(--code-bg);
        padding: 0.15em 0.35em;
        border-radius: 4px;
    }

    :not(pre) > code {
        color: var(--code-fg);
    }

    pre {
        position: relative;
        margin: 1em 0;
        padding: 1em;
        background: var(--code-bg);
        border-radius: 8px;
        overflow-x: auto;
        line-height: 1.45;
    }

    .copy-btn {
        position: absolute;
        top: 8px;
        right: 8px;
        background: var(--code-bg);
        border: 1px solid var(--border);
        border-radius: 6px;
        color: var(--fg-secondary);
        font-family: -apple-system, BlinkMacSystemFont, sans-serif;
        font-size: 0.75rem;
        padding: 3px 8px;
        cursor: pointer;
        opacity: 0.6;
        transition: opacity 0.15s ease;
        z-index: 1;
    }

    .copy-btn:hover {
        opacity: 1;
        color: var(--fg);
    }

    #link-preview {
        position: fixed;
        bottom: 0;
        left: 0;
        background: var(--code-bg);
        border: 1px solid var(--border);
        border-bottom: none;
        border-left: none;
        border-radius: 0 6px 0 0;
        color: var(--fg-secondary);
        font-family: -apple-system, BlinkMacSystemFont, sans-serif;
        font-size: 0.75rem;
        padding: 4px 10px;
        max-width: 60%;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
        opacity: 0;
        transition: opacity 0.15s ease;
        pointer-events: none;
        z-index: 100;
    }

    #link-preview.visible {
        opacity: 1;
    }

    pre code {
        background: none;
        padding: 0;
        border-radius: 0;
        font-size: 0.85em;
    }

    pre code.hljs {
        background: transparent;
    }

    table {
        width: 100%;
        border-collapse: collapse;
        margin: 1em 0;
        font-size: 0.95em;
    }

    th, td {
        padding: 0.6em 0.8em;
        border: 1px solid var(--table-border);
        text-align: left;
    }

    th {
        background: var(--table-header-bg);
        font-weight: 600;
    }

    ul.contains-task-list {
        list-style: none;
        padding-left: 0;
    }

    li.task-list-item {
        padding-left: 0.25em;
    }

    li input[type="checkbox"] {
        -webkit-appearance: none !important;
        appearance: none !important;
        display: inline-block;
        width: 16px;
        height: 16px;
        min-width: 16px;
        min-height: 16px;
        border: 1.5px solid var(--border);
        border-radius: 4px;
        background: var(--bg);
        vertical-align: middle;
        position: relative;
        top: -1px;
        margin: 0 0.5em 0 0;
        padding: 0;
        transition: background 0.15s ease, border-color 0.15s ease;
    }

    li input[type="checkbox"]:checked {
        background: var(--link);
        border-color: var(--link);
    }

    li input[type="checkbox"]:checked::after {
        content: "";
        display: block;
        position: absolute;
        left: 50%;
        top: 45%;
        width: 5px;
        height: 9px;
        border: solid #fff;
        border-width: 0 1.5px 1.5px 0;
        transform: translate(-50%, -55%) rotate(45deg);
    }

    /* Each diagram is drawn in both themes; the scheme picks one, as it does
       for the highlight.js themes below. */
    .mermaid-diagram {
        margin: 1em 0;
        text-align: center;
        overflow-x: auto;
    }

    .mermaid-dark { display: none; }

    @media (prefers-color-scheme: dark) {
        .mermaid-light { display: none; }
        .mermaid-dark { display: block; }
    }

    .mermaid-error {
        text-align: left;
        background: var(--code-bg);
        border-left: 3px solid var(--error);
        border-radius: 0 6px 6px 0;
        padding: 0.75em 1em;
        font-family: "SF Mono", Menlo, Consolas, "Liberation Mono", monospace;
        font-size: 0.8em;
        line-height: 1.45;
    }

    .mermaid-error-message {
        color: var(--error);
        white-space: pre-wrap;
        margin-bottom: 0.75em;
    }

    .mermaid-error-source {
        color: var(--fg-secondary);
        white-space: pre;
        overflow-x: auto;
    }

    @media print {
        :root {
            --bg: #ffffff;
            --fg: #1d1d1f;
            --fg-secondary: #6e6e73;
            --link: #0066cc;
            --border: #d2d2d7;
            --code-bg: #f5f5f7;
            --code-fg: #1d1d1f;
            --blockquote-border: #0066cc;
            --blockquote-bg: #f5f5f7;
            --table-header-bg: #f5f5f7;
            --table-border: #d2d2d7;
            --error: #d70015;
        }
        body { padding: 0; }
        .copy-btn { display: none !important; }
        #link-preview { display: none !important; }
        .mermaid-light { display: block !important; }
        .mermaid-dark { display: none !important; }
        pre, li, blockquote, .mermaid-diagram { break-inside: avoid; }
        h1, h2, h3, h4, h5, h6 { break-after: avoid; }
    }
    </style>
    <style>
    @media (prefers-color-scheme: light) {
        \(highlightLightCSS)
    }
    @media (prefers-color-scheme: dark) {
        \(highlightDarkCSS)
    }
    </style>
    </head>
    <body>
    <div id="content"></div>

    <script>\(markedJS)</script>
    <script>\(highlightJS)</script>
    <script>
    (function() {
        var contentEl = document.getElementById('content');

        function buildRenderer() {
            var renderer = new marked.Renderer();
            var usedSlugs = {};
            renderer.heading = function({ tokens, depth }) {
                var text = this.parser.parseInline(tokens);
                var raw = text.replace(/<[^>]+>/g, '');
                var baseSlug = raw.toLowerCase().trim()
                    .replace(/[^\\w\\s-]/g, '')
                    .replace(/\\s+/g, '-');
                var slug = baseSlug;
                if (usedSlugs[baseSlug] !== undefined) {
                    usedSlugs[baseSlug]++;
                    slug = baseSlug + '-' + usedSlugs[baseSlug];
                } else {
                    usedSlugs[baseSlug] = 0;
                }
                return '<h' + depth + ' id="' + slug + '">' + text + '</h' + depth + '>';
            };
            renderer.image = function({ href, title, text }) {
                if (href && !/^https?:/i.test(href)) {
                    href = href.split('?')[0];
                    href = 'unfold-resource://resource/' + encodeURI(href);
                }
                var html = '<img src="' + href + '" alt="' + (text || '') + '"';
                if (title) html += ' title="' + title + '"';
                html += '>';
                return html;
            };
            // A mermaid fence becomes an empty placeholder carrying its source;
            // the diagram is drawn into it after the page is parsed.
            var defaultCode = renderer.code;
            renderer.code = function(token) {
                if ((token.lang || '').trim().split(' ')[0] === 'mermaid') {
                    return '<div class="mermaid-diagram" data-source="' + escapeHTML(token.text) + '"></div>';
                }
                return defaultCode.call(this, token);
            };
            return renderer;
        }

        function escapeHTML(s) {
            return s.replace(/&/g, '&amp;').replace(/</g, '&lt;')
                .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
        }

        // ---- Mermaid ----
        // The library is ~3.5 MB, so it isn't inlined into this shell like
        // marked and highlight.js: a page fetches it the first time it has a
        // diagram to draw.
        var mermaidReady = null;
        function loadMermaid() {
            if (!mermaidReady) {
                mermaidReady = new Promise(function(resolve, reject) {
                    var script = document.createElement('script');
                    script.src = 'unfold-resource://bundle/mermaid.min.js';
                    script.onload = function() { resolve(window.mermaid); };
                    script.onerror = function() {
                        mermaidReady = null;
                        reject(new Error('The Mermaid library could not be loaded.'));
                    };
                    document.head.appendChild(script);
                });
            }
            return mermaidReady;
        }

        // Rendered diagrams by source, so a re-render while typing elsewhere
        // refills them at once instead of blanking and redrawing each one.
        var diagramCache = new Map();
        var diagramCount = 0;

        // The theme is global Mermaid config, so renders must not interleave:
        // each waits for the one before it.
        var mermaidQueue = Promise.resolve();
        function renderDiagram(mermaid, source) {
            var job = mermaidQueue.then(async function() {
                var fontFamily = getComputedStyle(document.body).fontFamily;
                var entry = {};
                var variants = [['light', 'default'], ['dark', 'dark']];
                for (var i = 0; i < variants.length; i++) {
                    mermaid.initialize({
                        startOnLoad: false,
                        securityLevel: 'strict',
                        suppressErrorRendering: true,
                        theme: variants[i][1],
                        fontFamily: fontFamily,
                        themeVariables: { fontFamily: fontFamily }
                    });
                    var id = 'unfold-mermaid-' + (++diagramCount);
                    try {
                        var result = await mermaid.render(id, source);
                        entry[variants[i][0]] = uniquifyIds(result.svg, id);
                    } catch (e) {
                        return { error: (e && e.message) || String(e) };
                    }
                }
                return entry;
            });
            mermaidQueue = job.catch(function() {});
            return job;
        }

        // Some of Mermaid's ids are fixed (#arrowhead, #drop-shadow), and
        // url(#…) resolves to the first match in the document — with a light
        // and a dark copy of every diagram on the page, often the hidden one.
        // Suffix every id but the root's (already unique, and what the
        // diagram's own stylesheet is scoped to) and rewrite references.
        function uniquifyIds(svg, rootId) {
            var template = document.createElement('template');
            template.innerHTML = svg;
            var renamed = {};
            template.content.querySelectorAll('[id]').forEach(function(el) {
                if (el.id === rootId) return;
                renamed[el.id] = el.id + '--' + rootId;
                el.id = renamed[el.id];
            });
            template.content.querySelectorAll('*').forEach(function(el) {
                for (var i = 0; i < el.attributes.length; i++) {
                    var attr = el.attributes[i];
                    var value = attr.value.replace(/url\\((['"]?)#([^)'"]+)\\1\\)/g, function(m, q, id) {
                        return renamed[id] ? 'url(' + q + '#' + renamed[id] + q + ')' : m;
                    });
                    if (value.charAt(0) === '#' && renamed[value.substring(1)]) {
                        value = '#' + renamed[value.substring(1)];
                    } else if (attr.name.indexOf('aria-') === 0) {
                        value = value.split(' ').map(function(t) { return renamed[t] || t; }).join(' ');
                    }
                    if (value !== attr.value) attr.value = value;
                }
            });
            return template.innerHTML;
        }

        function fillDiagram(el, entry) {
            if (entry.error) {
                el.innerHTML = '<div class="mermaid-error">'
                    + '<div class="mermaid-error-message">' + escapeHTML(entry.error) + '</div>'
                    + '<div class="mermaid-error-source">' + escapeHTML(el.getAttribute('data-source')) + '</div>'
                    + '</div>';
            } else {
                el.innerHTML = '<div class="mermaid-light">' + entry.light + '</div>'
                    + '<div class="mermaid-dark">' + entry.dark + '</div>';
            }
        }

        // Fills every diagram already in the cache and returns the rest.
        function fillCachedDiagrams() {
            var pending = [];
            var seen = new Set();
            contentEl.querySelectorAll('.mermaid-diagram').forEach(function(el) {
                var source = el.getAttribute('data-source');
                seen.add(source);
                var entry = diagramCache.get(source);
                if (entry) fillDiagram(el, entry); else pending.push(el);
            });
            diagramCache.forEach(function(_, source) {
                if (!seen.has(source)) diagramCache.delete(source);
            });
            return pending;
        }

        async function renderPendingDiagrams(els, generation) {
            var mermaid;
            try {
                mermaid = await loadMermaid();
            } catch (e) {
                els.forEach(function(el) { fillDiagram(el, { error: e.message }); });
                return;
            }
            for (var i = 0; i < els.length; i++) {
                if (generation !== renderGeneration) return;
                var source = els[i].getAttribute('data-source');
                var entry = diagramCache.get(source);
                if (!entry) {
                    entry = await renderDiagram(mermaid, source);
                    if (generation !== renderGeneration) return;
                    diagramCache.set(source, entry);
                }
                fillDiagram(els[i], entry);
            }
        }

        var renderGeneration = 0;

        // Render Markdown into #content, tagging each top-level block element
        // with its 0-based source line (data-line) for editor->preview sync.
        // Preserves scroll position across re-renders. Returns a Promise that
        // settles once any diagrams not yet in the cache have been drawn.
        window._render = function(md) {
            var generation = ++renderGeneration;
            var y = window.scrollY;
            var renderer = buildRenderer();
            marked.setOptions({ gfm: true, breaks: false, renderer: renderer });

            var tokens = marked.lexer(md);
            var line = 0;
            var html = '';
            for (var i = 0; i < tokens.length; i++) {
                var token = tokens[i];
                var startLine = line;
                var nl = (token.raw.match(/\\n/g) || []).length;
                line += nl;
                var single = [token];
                single.links = tokens.links;
                var piece = marked.parser(single, { renderer: renderer });
                // Inject data-line into the first opening tag of this block.
                piece = piece.replace(/^(\\s*<[a-zA-Z][\\w-]*)/, '$1 data-line="' + startLine + '"');
                html += piece;
            }
            contentEl.innerHTML = html;
            var pendingDiagrams = fillCachedDiagrams();

            hljs.highlightAll();

            contentEl.querySelectorAll('pre').forEach(function(pre) {
                var btn = document.createElement('button');
                btn.className = 'copy-btn';
                btn.textContent = 'Copy';
                btn.addEventListener('click', function() {
                    var code = pre.querySelector('code');
                    var text = code ? code.textContent : pre.textContent;
                    var ta = document.createElement('textarea');
                    ta.value = text;
                    ta.style.position = 'fixed';
                    ta.style.opacity = '0';
                    document.body.appendChild(ta);
                    ta.select();
                    document.execCommand('copy');
                    document.body.removeChild(ta);
                    btn.textContent = 'Copied!';
                    setTimeout(function() { btn.textContent = 'Copy'; }, 1500);
                });
                pre.appendChild(btn);
            });

            // Send TOC data to Swift
            var headings = [];
            contentEl.querySelectorAll('h1,h2,h3,h4,h5,h6').forEach(function(el) {
                headings.push({ text: el.textContent, depth: parseInt(el.tagName[1]), slug: el.id });
            });
            if (window.webkit && window.webkit.messageHandlers.tocData) {
                window.webkit.messageHandlers.tocData.postMessage(headings);
            }

            window.scrollTo(0, y);

            // The ranges an open search highlighted belonged to the old #content.
            if (window._unfoldFind) window._unfoldFind.refresh();

            if (pendingDiagrams.length === 0) return Promise.resolve();
            // Until they're drawn the page is shorter, so the offset may have
            // been clamped; put it back unless the reader has scrolled since.
            var settledY = window.scrollY;
            return renderPendingDiagrams(pendingDiagrams, generation).then(function() {
                if (generation !== renderGeneration) return;
                if (window.scrollY === settledY) window.scrollTo(0, y);
                if (window._unfoldFind) window._unfoldFind.refresh();
            });
        };

        // Scroll the block at/above the given source line into view, but only
        // when it isn't already visible (no jitter while editing in place).
        window._syncToLine = function(line) {
            var els = contentEl.querySelectorAll('[data-line]');
            var target = null;
            for (var i = 0; i < els.length; i++) {
                var l = parseInt(els[i].getAttribute('data-line'), 10);
                if (l <= line) target = els[i]; else break;
            }
            if (!target) return;
            var rect = target.getBoundingClientRect();
            var h = window.innerHeight;
            var fullyVisible = rect.top >= 0 && rect.bottom <= h;
            var tallCovering = rect.top <= 0 && rect.bottom >= h;
            if (!fullyVisible && !tallCovering) {
                target.scrollIntoView({ block: 'nearest' });
            }
        };

        // ---- One-time setup (survives #content re-renders via event delegation) ----

        // Navigation history lives in Swift, which is the only side that knows
        // which *file* is on screen. The page's part is to report where it is
        // scrolled to and to say when it has jumped somewhere new.
        function postJump() {
            if (window.webkit && window.webkit.messageHandlers.historyPush) {
                window.webkit.messageHandlers.historyPush.postMessage(null);
            }
        }

        function jumpTo(target) {
            postJump();
            target.scrollIntoView({ behavior: 'smooth' });
        }

        window._scrollToHeading = function(slug) {
            var target = document.getElementById(slug);
            if (target) jumpTo(target);
        };

        document.body.addEventListener('click', function(e) {
            var a = e.target.closest('a[href]');
            if (!a) return;
            if (/^https?:/.test(a.href)) {
                e.preventDefault();
                window.location.href = a.href;
                return;
            }
            var href = a.getAttribute('href');
            if (!href) return;
            if (href.charAt(0) === '#') {
                var target = document.getElementById(href.substring(1));
                if (target) {
                    e.preventDefault();
                    jumpTo(target);
                }
                return;
            }
            // No scheme means a path on disk, relative to the document's folder
            // (e.g. a Notion export's links between pages). The raw attribute is
            // sent rather than a.href, which the browser has already resolved
            // against unfold-resource://page and normalised — losing any '..'.
            if (!/^[a-z][a-z0-9+.-]*:/i.test(href)) {
                e.preventDefault();
                if (window.webkit && window.webkit.messageHandlers.openLink) {
                    window.webkit.messageHandlers.openLink.postMessage(href);
                }
            }
        });

        // Scroll tracking: the heading the reader is under (for the TOC) and the
        // offset itself (so Swift can stamp it into the history entry it leaves).
        var scrollTimer = null;
        window.addEventListener('scroll', function() {
            if (scrollTimer) return;
            scrollTimer = setTimeout(function() {
                scrollTimer = null;
                var active = null;
                document.querySelectorAll('h1,h2,h3,h4,h5,h6').forEach(function(el) {
                    if (el.getBoundingClientRect().top <= 20) active = el.id;
                });
                if (window.webkit && window.webkit.messageHandlers.scrollState) {
                    window.webkit.messageHandlers.scrollState.postMessage({
                        heading: active, y: window.scrollY
                    });
                }
            }, 100);
        });

        var linkPreview = document.createElement('div');
        linkPreview.id = 'link-preview';
        document.body.appendChild(linkPreview);

        document.body.addEventListener('mousemove', function(e) {
            var a = e.target.closest('a[href]');
            if (a) {
                linkPreview.textContent = a.href;
                linkPreview.classList.add('visible');
            } else {
                linkPreview.classList.remove('visible');
            }
        });
    })();
    </script>
    </body>
    </html>
    """
}
