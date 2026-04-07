import Foundation

private func loadBundleResource(_ name: String, _ ext: String) -> String {
    guard let url = Bundle.main.url(forResource: name, withExtension: ext),
          let contents = try? String(contentsOf: url, encoding: .utf8) else {
        return ""
    }
    return contents
}

private func escapeForJSTemplateLiteral(_ s: String) -> String {
    var result = s
    result = result.replacingOccurrences(of: "\\", with: "\\\\")
    result = result.replacingOccurrences(of: "`", with: "\\`")
    result = result.replacingOccurrences(of: "${", with: "\\${")
    return result
}

func buildHTML(markdown: String, title: String) -> String {
    let escapedMarkdown = escapeForJSTemplateLiteral(markdown)
    let escapedTitle = title
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")

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
    <title>\(escapedTitle)</title>
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
        }
        body { padding: 0; }
        .copy-btn { display: none !important; }
        #link-preview { display: none !important; }
        pre, li, blockquote { break-inside: avoid; }
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
        const md = `\(escapedMarkdown)`;
        const renderer = new marked.Renderer();
        renderer.heading = function({ tokens, depth }) {
            const text = this.parser.parseInline(tokens);
            const raw = text.replace(/<[^>]+>/g, '');
            const slug = raw.toLowerCase().trim()
                .replace(/[^\\w\\s-]/g, '')
                .replace(/\\s+/g, '-');
            return '<h' + depth + ' id="' + slug + '">' + text + '</h' + depth + '>';
        };
        marked.setOptions({
            gfm: true,
            breaks: false,
            renderer: renderer
        });
        document.getElementById('content').innerHTML = marked.parse(md);
        hljs.highlightAll();
        document.querySelectorAll('pre').forEach(function(pre) {
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

        var scrollHistory = [];
        var scrollHistoryIndex = -1;

        function postNavState() {
            window.webkit.messageHandlers.navState.postMessage({
                canGoBack: scrollHistoryIndex > 0,
                canGoForward: scrollHistoryIndex < scrollHistory.length - 1
            });
        }

        window._goBack = function() {
            if (scrollHistoryIndex > 0) {
                scrollHistoryIndex--;
                window.scrollTo(0, scrollHistory[scrollHistoryIndex]);
                postNavState();
            }
        };
        window._goForward = function() {
            if (scrollHistoryIndex < scrollHistory.length - 1) {
                scrollHistoryIndex++;
                window.scrollTo(0, scrollHistory[scrollHistoryIndex]);
                postNavState();
            }
        };

        document.body.addEventListener('click', function(e) {
            var a = e.target.closest('a[href]');
            if (!a) return;
            if (/^https?:/.test(a.href)) {
                e.preventDefault();
                window.location.href = a.href;
                return;
            }
            var hash = a.getAttribute('href');
            if (hash && hash.charAt(0) === '#') {
                var target = document.getElementById(hash.substring(1));
                if (target) {
                    e.preventDefault();
                    scrollHistory.splice(scrollHistoryIndex + 1);
                    scrollHistory.push(window.scrollY);
                    scrollHistoryIndex++;
                    target.scrollIntoView({ behavior: 'smooth' });
                    setTimeout(function() {
                        scrollHistory.splice(scrollHistoryIndex + 1);
                        scrollHistory.push(window.scrollY);
                        scrollHistoryIndex++;
                        postNavState();
                    }, 500);
                }
            }
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
