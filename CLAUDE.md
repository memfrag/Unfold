# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Unfold is a read-only Markdown viewer for macOS (SwiftUI document app). It opens `.md` files, renders them to HTML via bundled JavaScript libraries, and displays the result in a `WKWebView`. The app never writes Markdown files — `UnfoldDocument` declares no `writableContentTypes` and its `fileWrapper` throws.

## Build & release

- **Build/run:** Open `Unfold.xcodeproj` in Xcode, Cmd+B / Cmd+R. There is no command-line test suite — this is a small SwiftUI app with no test target.
- **Release:** `scripts/build-and-notarize.sh` is the full pipeline — bumps version (Info.plist + pbxproj), archives (arm64, hardened runtime), exports, builds a DMG, notarizes (`notarytool` keychain profile `notary`), staples, signs for Sparkle, creates a GitHub release on `memfrag/Unfold`, and regenerates `appcast.xml`. It downloads Sparkle tools on first run and is interactive (prompts for version and release title).
- **Auto-update:** Sparkle reads `appcast.xml` (committed at repo root, served from GitHub). Bundle ID is `io.apparata.Unfold`.
- **Dependencies** (SwiftPM, pinned exact versions): `Sparkle` 2.9.1, `apparata/AttributionsUI` 1.1.1.

## Architecture

The rendering pipeline is the core of the app and spans Swift ↔ JavaScript:

1. **`UnfoldDocument`** loads the file's UTF-8 text (read-only `FileDocument`).
2. **`HTMLTemplate.swift` / `buildHTML()`** produces a complete self-contained HTML page. The Markdown text is embedded into a JS template literal (escaped via `escapeForJSTemplateLiteral`), and `marked.min.js` + `highlight.min.js` + the two highlight CSS themes are inlined from `Unfold/Resources/`. Rendering, slug generation for headings, the copy-button, link-preview, scroll history, and TOC extraction all happen in the injected `<script>`.
3. **`MarkdownWebView`** (`NSViewRepresentable`) hosts the `WKWebView` and owns the bridge.

### The Swift ↔ JS bridge

This is the part that requires reading multiple files together. Communication is bidirectional:

- **JS → Swift** via three `WKScriptMessage` handlers registered in `makeNSView` and handled in `Coordinator.userContentController`: `navState` (back/forward availability), `tocData` (flat heading list), `activeHeading` (scroll-spy current heading).
- **Swift → JS** via `evaluateJavaScript` calling globals the template defines: `window._goBack()`, `_goForward()`, `_scrollToHeading(slug)`.
- Scroll history (back/forward navigation) lives entirely in JS as an array — it is *not* WebKit's native page history.
- `suppressScrollTracking` guards against the scroll-spy fighting a programmatic `scrollToHeading`.

### Custom URL scheme: `unfold-resource://`

The page is **not** loaded from disk or via `loadHTMLString`. Instead `LocalResourceSchemeHandler` serves everything through a custom scheme:
- `unfold-resource://page` → the generated HTML (stashed in `pendingHTML`).
- `unfold-resource://resource/<path>` → local image files, resolved relative to the document's directory.

The template's `renderer.image` rewrites every non-`http(s)` image `src` to this scheme. This exists so relative-path images in sandboxed Markdown can be displayed.

### Sandboxing & file access (the tricky part)

The app is sandboxed (`Unfold.entitlements`: app-sandbox, user-selected read-write, app-scope bookmarks). A Markdown file the user opened is accessible, but **its sibling image files are not** without explicit grant. Flow:
- `hasLocalImages()` regex-scans the Markdown; only if it finds local images does the app request directory access *before* first render.
- `Coordinator.requestDirectoryAccess` checks readability, then a stored security-scoped bookmark (`BookmarkStore`), then falls back to an `NSOpenPanel` asking the user to grant the folder. Grants persist via `BookmarkStore` in `UserDefaults` so the panel isn't shown again.
- The granted directory (`schemeHandler.grantedDirectory`) is what the scheme handler uses to resolve image paths.

### Live reload

`FileWatcher` wraps a `DispatchSource` file-system-object source. On `.write` it reloads from disk; on `.delete`/`.rename` (atomic saves by editors) it cancels, re-opens the path after a short delay, and reloads. Reload re-reads the file and regenerates the whole HTML page.

### TOC / headings

`HeadingItem.swift` turns the flat heading list (sent from JS) into a nested tree (`buildHeadingTree`) for the inspector sidebar in `ContentView`. `preserveExpansionState` keeps disclosure-group open/closed state across reloads. Heading slugs must match between Swift and JS — both derive them from heading text, but the authoritative slugs are generated in JS (`renderer.heading`) and sent over, so the sidebar links resolve correctly even with duplicate headings.

### Commands & menus

`UnfoldApp` wires menu commands. Export PDF (Cmd+E), Print (Cmd+P), back/forward (Cmd+[ / Cmd+]), reload (Cmd+R), appearance toggle, and TOC toggle are driven through `NavigationState.coordinator` (a `@FocusedValue`). PDF export forces light appearance temporarily for legible output. `CLIInstaller` offers a copyable `sudo cp` command to install the bundled `unfold` CLI shim (`Unfold/Resources/unfold`) into `/usr/local/bin`.

## Conventions

- Vendored JS/CSS in `Unfold/Resources/` is minified third-party code — regenerate from upstream (marked, highlight.js) rather than hand-editing. Versions are tracked in `README.md` and the `AttributionsWindow` in `UnfoldApp.swift`; update both when bumping.
- When changing rendering behavior, remember the markdown string is interpolated into a JS template literal — anything that breaks the literal (backticks, `${`) must go through `escapeForJSTemplateLiteral`.
