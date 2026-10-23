# Unfold

A lightweight Markdown viewer for macOS built with SwiftUI and WKWebView.

## Features

- Renders GitHub-flavored Markdown with full styling
- Syntax highlighting for 190+ languages via highlight.js
- Mermaid diagrams in ` ```mermaid ` code blocks, and Graphviz in ` ```dot ` / ` ```graphviz `
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
- [Mermaid](https://github.com/mermaid-js/mermaid) v11.17.2 — Diagrams from text (MIT License)
- [Viz.js](https://github.com/mdaines/viz-js) v3.31.0 — Graphviz 16.1.0 compiled to WebAssembly (MIT License; Graphviz under the Eclipse Public License 1.0)

## License

0BSD — See [LICENSE](LICENSE) for details.
