# Unfold

A lightweight Markdown viewer for macOS built with SwiftUI and WKWebView.

## Features

- Renders GitHub-flavored Markdown with full styling
- Syntax highlighting for 190+ languages via highlight.js
- Dark and light mode support (follows system appearance)
- Copy button on code blocks
- Link hover preview
- Anchor navigation with smooth scrolling
- Back/forward navigation through scroll history
- File watching — auto-reloads when the file is saved externally
- PDF export (Cmd+E)
- Print support (Cmd+P)

## Building

Open `Unfold.xcodeproj` in Xcode and build (Cmd+B).

## Third-Party Software

Unfold bundles the following libraries:

- [marked](https://github.com/markedjs/marked) v15.0.12 — Markdown parser (MIT License)
- [highlight.js](https://github.com/highlightjs/highlight.js) v11.11.1 — Syntax highlighter (BSD 3-Clause License)

## License

0BSD — See [LICENSE](LICENSE) for details.
