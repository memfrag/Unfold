# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Unfold is a Markdown viewer/editor for macOS (SwiftUI document app). It opens `.md` files, renders them to HTML via bundled JavaScript libraries, and displays the result in a `WKWebView`. By default it's a clean preview; an **Edit** toggle (Cmd+Shift+E / toolbar pencil) reveals a native source editor on the left in a split with the live preview on the right. Editing is **autosave in place** (standard SwiftUI document behavior) — `UnfoldDocument` is a writable `FileDocument`.

## Build & release

- **Build/run:** Open `Unfold.xcodeproj` in Xcode, Cmd+B / Cmd+R. There is no command-line test suite — this is a small SwiftUI app with no test target.
- **Release:** `scripts/build-and-notarize.sh` is the full pipeline — bumps version (Info.plist + pbxproj), archives (arm64, hardened runtime), exports, builds a DMG, notarizes (`notarytool` keychain profile `notary`), staples, signs for Sparkle, creates a GitHub release on `memfrag/Unfold`, and regenerates `appcast.xml`. It downloads Sparkle tools on first run and is interactive (prompts for version and release title).
- **Auto-update:** Sparkle reads `appcast.xml` (committed at repo root, served from GitHub). Bundle ID is `io.apparata.Unfold`.
- **Dependencies** (SwiftPM, pinned exact versions): `Sparkle` 2.9.1.

## Architecture

The rendering pipeline is the core of the app and spans Swift ↔ JavaScript:

1. **`UnfoldDocument`** loads/saves the file's UTF-8 text (a writable `FileDocument`; `fileWrapper` writes the text verbatim).
2. **`HTMLTemplate.swift` / `buildHTML()`** produces a self-contained HTML **shell** with an empty `#content`. `marked.min.js` + `highlight.min.js` + the two highlight CSS themes are inlined from `Unfold/Resources/`. The Markdown is **not** embedded in the page — instead the script defines `window._render(md)`, which parses the Markdown into `#content`, highlights code, wires copy buttons, extracts the TOC, tags each top-level block with a `data-line` source-line attribute, and preserves scroll. One-time setup (link/scroll/mousemove listeners, `_goBack`/`_goForward`/`_scrollToHeading`, `_syncToLine`, link-preview, scroll history) lives outside `_render`.
3. **`MarkdownWebView`** (`NSViewRepresentable`) hosts the `WKWebView` and owns the bridge. The initial render is driven from `webView(_:didFinish:)`; live edits re-render in place (debounced ~1s) without reloading the page.

### The Swift ↔ JS bridge

This is the part that requires reading multiple files together. Communication is bidirectional:

- **JS → Swift** via three `WKScriptMessage` handlers registered in `makeNSView` and handled in `Coordinator.userContentController`: `navState` (back/forward availability), `tocData` (flat heading list), `activeHeading` (scroll-spy current heading).
- **Swift → JS** via two mechanisms: `evaluateJavaScript` for the navigation globals (`window._goBack()`, `_goForward()`, `_scrollToHeading(slug)`), and `callAsyncJavaScript` for `window._render(md)` and `window._syncToLine(line)` — passing the Markdown/line as a real JS argument avoids all string-escaping concerns (there is no longer any `escapeForJSTemplateLiteral`).
- Scroll history (back/forward navigation) lives entirely in JS as an array — it is *not* WebKit's native page history.
- `suppressScrollTracking` guards against the scroll-spy fighting a programmatic `scrollToHeading`.

### Custom URL scheme: `unfold-resource://`

The page is **not** loaded from disk or via `loadHTMLString`. Instead `LocalResourceSchemeHandler` serves everything through a custom scheme:
- `unfold-resource://page` → the generated HTML (stashed in `pendingHTML`).
- `unfold-resource://resource/<path>` → local image files, resolved relative to the document's directory.

The template's `renderer.image` rewrites every non-`http(s)` image `src` to this scheme. This exists so relative-path images in the Markdown can be displayed.

### File access

The app is **not** sandboxed (`Unfold.entitlements` only retains the Sparkle mach-lookup exceptions). It has full filesystem read access, so `LocalResourceSchemeHandler` resolves `unfold-resource://resource/<path>` image requests directly against the document's directory (`baseDirectory`) with no permission prompt or security-scoped bookmarks.

### Editing & live preview

The editor is **`MarkdownTextView`** (`NSViewRepresentable` around `NSTextView`, not SwiftUI `TextEditor` — `TextEditor` force-applies smart quote/dash substitution that corrupts Markdown). It disables all substitutions, soft-wraps, follows the appearance toggle, and uses native undo. **`MarkdownSyntaxHighlighter`** styles the text storage with a regex pass (headings, emphasis, code, links, lists, quotes) using dynamic system colors.

`ContentView` is an `HSplitView`; the editor is conditionally inserted while the `MarkdownWebView` is **always present with a stable `.id("preview")`** so toggling edit mode does not recreate the `WKWebView` (which would reset scroll). Entering edit mode widens the window (see `Coordinator.adjustWindow`, right-edge anchored, Core-Animation animated).

Editor → preview **sync** is one-directional and caret-driven: on caret move/typing the editor computes the source line and calls `Coordinator.syncToLine`, which calls `window._syncToLine` to scroll the matching `data-line` block into view *only if off-screen*.

### Staying in step with the file on disk

`FileWatcher` (a `DispatchSource` file-system source) watches the open file and adopts external edits. It re-opens the path on `.rename`/`.delete` rather than just reporting a change, because atomic saves — how most editors write — replace the inode and would otherwise leave the watcher deaf after the first external save. Events are coalesced behind a short debounce.

Adoption **never clobbers unsaved local work**, but the two windows establish that differently:

- **Folder browser:** `LooseFile` owns both the text and its watcher. It skips adoption while one of its own saves is pending; an explicit Reload flushes first, then re-reads.
- **Single document:** `ContentView` owns the watcher. `DocumentGroup`'s autosave timing isn't observable, so it tracks `lastKnownDiskText` and treats any divergence from it as unsaved work — external changes are skipped until the document autosaves. For the same reason an explicit Reload on a dirty document re-renders rather than re-reading.

Reload goes through `NavigationState.reload()`, not the coordinator directly: it calls the view-supplied `reloadFromDisk` closure and hands the resulting text to `Coordinator.render(markdown:)`. Passing the text explicitly matters — `updateNSView` hasn't run yet at that point, so rendering off `lastMarkdown` would show the stale copy. `Coordinator.reload()` (in-memory re-render only) remains the fallback when no closure is set.

### TOC / headings

`HeadingItem.swift` turns the flat heading list (sent from JS) into a nested tree (`buildHeadingTree`) for the inspector sidebar in `ContentView`. `preserveExpansionState` keeps disclosure-group open/closed state across reloads. Heading slugs must match between Swift and JS — both derive them from heading text, but the authoritative slugs are generated in JS (`renderer.heading`) and sent over, so the sidebar links resolve correctly even with duplicate headings.

### Commands & menus

`UnfoldApp` wires menu commands. Export PDF (Cmd+E), Print (Cmd+P), back/forward (Cmd+[ / Cmd+]), reload (Cmd+R), Show/Hide Editor (Cmd+Shift+E), appearance toggle, and TOC toggle are driven through `NavigationState` / its `coordinator` (a `@FocusedValue`). The shared `@Observable NavigationState` (notably `isEditing`) ties the menu/toolbar toggles, the split layout, and the coordinator together. File > New (Cmd+N) creates a blank untitled document. PDF export forces light appearance temporarily for legible output. `CLIInstaller` offers a copyable `sudo cp` command to install the bundled `unfold` CLI shim (`Unfold/Resources/unfold`) into `/usr/local/bin`.

File > Open Folder... (Cmd+Shift+O) opens a folder-browser window through `AppDelegate.showOpenFolderPanel()`. It is deliberately *not* folded into File > Open: that item belongs to `DocumentGroup`, its panel offers only `UnfoldDocument.readableContentTypes`, and SwiftUI publishes no command placement for it — `.newItem` covers `New` alone (verified by dumping the live `NSApp.mainMenu`). Two things that look like fixes and are not: adding `public.folder` to `readableContentTypes` makes the panel accept a directory but then feeds it to `UnfoldDocument.init(configuration:)`, which fails because `regularFileContents` is nil for a directory; and installing an `NSDocumentController` subclass to intercept directories **crashes on launch** — SwiftUI builds its own `PlatformDocumentController` in `applicationWillFinishLaunching` and segfaults if something else already claimed `NSDocumentController.shared`.

About is AppKit's **standard** About panel — there is no custom About window or scene. Third-party licenses live in `Unfold/Resources/Credits.html`, which the panel picks up automatically (it looks for `Credits.html`/`.rtf`/`.rtfd` in `Contents/Resources`) and shows in its scrollable credits area. Two constraints on that file: it must declare `<meta charset="utf-8">` or the `NSAttributedString` HTML importer decodes it as Latin-1 and mangles em dashes, and it must not set text colors or the credits go unreadable in dark mode.

### External editor

`ExternalEditor` (an `@Observable` singleton, `UserDefaults`-backed like `EditorTheme`) decides whether Edit opens the built-in `MarkdownTextView` or hands the file to another app. It needs no syncing machinery of its own — `FileWatcher` and the adoption logic already pick up another program's writes and re-render.

All three Edit affordances (both toolbar buttons, Cmd+Shift+E) route through `NavigationState.edit()`, which is where the branch lives. Two rules it encodes: in external mode it must **not** touch `isEditing` (that would trigger `adjustWindow(forEditing:)` and widen the window for an editor that never appears), and it flushes pending edits first, since the external app reads from disk. Flushing differs per owner — `LooseFile.flush()` in the folder browser, a direct atomic write in `ContentView` (going through `DocumentGroup` would race the launch, as its save is asynchronous). `NavigationState.fileURL` / `flushPendingEdits` are set by the file's owner, following the same closure idiom as `reloadFromDisk`.

### Preferences / theme

A `Settings` scene (`SettingsView`) has a **Theme** tab of color wells for the editor's Markdown syntax-highlighting colors. `EditorTheme` (an `@Observable` singleton) stores per-element overrides in `UserDefaults` (hex), falling back to adaptive system-color defaults. `MarkdownSyntaxHighlighter` reads `EditorTheme.shared`; changing a color posts `.editorThemeChanged`, which the editor's coordinator observes to re-highlight.

## Conventions

- Vendored JS/CSS in `Unfold/Resources/` is minified third-party code — regenerate from upstream (marked, highlight.js) rather than hand-editing. Versions are tracked in `README.md` and in `Unfold/Resources/Credits.html`; update both when bumping.
- The Markdown reaches the page only through `window._render(md)` via `callAsyncJavaScript` (a real JS argument), so there is no string escaping to worry about. If you change how blocks are emitted in `_render`, keep the `data-line` attribute on top-level blocks or editor→preview sync breaks.
