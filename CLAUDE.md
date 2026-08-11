# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Unfold is a Markdown viewer/editor for macOS (SwiftUI document app). It opens `.md` files, renders them to HTML via bundled JavaScript libraries, and displays the result in a `WKWebView`. By default it's a clean preview; an **Edit** toggle (Cmd+Shift+E / toolbar pencil) reveals a native source editor on the left in a split with the live preview on the right. Editing is **autosave in place** (standard SwiftUI document behavior) — `UnfoldDocument` is a writable `FileDocument`.

## Build & release

- **Build/run:** Open `Unfold.xcodeproj` in Xcode, Cmd+B / Cmd+R. There is no command-line test suite — this is a small SwiftUI app with no test target.
- **Release:** `scripts/build-and-notarize.sh` is the full pipeline — bumps version (Info.plist + pbxproj), archives (arm64, hardened runtime), exports, builds a DMG, notarizes (`notarytool` keychain profile `notary`), staples, signs for Sparkle, creates a GitHub release on `memfrag/Unfold`, and regenerates `appcast.xml`. It downloads Sparkle tools on first run and is interactive (prompts for version and release title).
- **Auto-update:** Sparkle reads `appcast.xml` (committed at repo root, served from GitHub). Bundle ID is `io.apparata.Unfold`.
- **Dependencies** (SwiftPM, pinned exact versions): `Sparkle` 2.9.1, `Zipcode` 1.0.1 (reading zip archives).

## Architecture

The rendering pipeline is the core of the app and spans Swift ↔ JavaScript:

1. **`UnfoldDocument`** loads/saves the file's UTF-8 text (a writable `FileDocument`; `fileWrapper` writes the text verbatim).
2. **`HTMLTemplate.swift` / `buildHTML()`** produces a self-contained HTML **shell** with an empty `#content`. `marked.min.js` + `highlight.min.js` + the two highlight CSS themes are inlined from `Unfold/Resources/`. The Markdown is **not** embedded in the page — instead the script defines `window._render(md)`, which parses the Markdown into `#content`, highlights code, wires copy buttons, extracts the TOC, tags each top-level block with a `data-line` source-line attribute, and preserves scroll. One-time setup (link/scroll/mousemove listeners, `_goBack`/`_goForward`/`_scrollToHeading`, `_syncToLine`, link-preview, scroll history) lives outside `_render`.
3. **`MarkdownWebView`** (`NSViewRepresentable`) hosts the `WKWebView` and owns the bridge. The initial render is driven from `webView(_:didFinish:)`; live edits re-render in place (debounced ~1s) without reloading the page.

### The Swift ↔ JS bridge

This is the part that requires reading multiple files together. Communication is bidirectional:

- **JS → Swift** via four `WKScriptMessage` handlers registered in `makeNSView` and handled in `Coordinator.userContentController`: `tocData` (flat heading list), `scrollState` (scroll offset + scroll-spy current heading), `historyPush` (the page jumped to an anchor), `openLink` (a clicked link to a path on disk).
- **Swift → JS** via two mechanisms: `evaluateJavaScript` for `window._scrollToHeading(slug)` and `window.scrollTo`, and `callAsyncJavaScript` for `window._render(md)` and `window._syncToLine(line)` — passing the Markdown/line as a real JS argument avoids all string-escaping concerns (there is no longer any `escapeForJSTemplateLiteral`).
- `suppressScrollTracking` guards against the scroll-spy fighting a programmatic `scrollToHeading`.

### Navigation history

Back/forward is **not** WebKit's page history — the page never navigates. It is a stack of `(file, scrollY)` entries in `NavigationState`, one per window, because the file identity exists only on the Swift side. Both kinds of destination live in it: another file, and a jump to an anchor within one.

Three things make it work:
- The page reports its scroll offset as it scrolls (`scrollState`); Swift stamps that into the entry it is *leaving*, so Back returns to where the reader was rather than the top. An entry's own offset is therefore filled in late — after the smooth scroll has settled.
- A history move sets the index **first**, then asks the owner to select that file. The selection round-trips through SwiftUI and lands back in `navigated(to:)`, which ignores an arrival at the file it is already on — that is what stops a move from recording itself, and is why there is no "am I restoring?" flag (one would be read after it had been cleared).
- A cross-file restore parks its offset in `pendingScroll`, **keyed by URL**, applied by the incoming file's coordinator after its first render. Keyed because the folder browser's `.id(file.url)` replaces the whole `WKWebView`: an unkeyed value could be swallowed by the outgoing one on its way out.

The single-document window seeds one entry (`ContentView.startWatching`) and only ever adds in-page jumps to it — a link elsewhere opens a window of its own.

### Custom URL scheme: `unfold-resource://`

The page is **not** loaded from disk or via `loadHTMLString`. Instead `LocalResourceSchemeHandler` serves everything through a custom scheme:
- `unfold-resource://page` → the generated HTML (stashed in `pendingHTML`).
- `unfold-resource://resource/<path>` → local image files, resolved relative to the document's directory.

The template's `renderer.image` rewrites every non-`http(s)` image `src` to this scheme. This exists so relative-path images in the Markdown can be displayed.

### Links to other files

Anchor hrefs are *not* rewritten — a link with no scheme is intercepted in the page's click handler, which `preventDefault`s and posts the **raw** `href` attribute over `openLink`. Raw matters: `a.href` has already been resolved against `unfold-resource://page` and normalised, which swallows any `../`. `Coordinator.openLocalLink` strips `#fragment`/`?query`, percent-decodes, and resolves the rest against the document's directory; Markdown goes to `NavigationState.openFile` (the folder browser selects it in the sidebar; unset, or a target outside the browsed root, means a new document window via `NavigationState.openInNewWindow`), anything else to `NSWorkspace`, and a missing path just beeps. `decidePolicyFor` cancels any `unfold-resource:` *link activation* that escapes the JS handler and routes it the same way — letting it navigate would silently re-serve the shell, which looks exactly like a dead link.

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

### Folder browser sidebar

`FileNode` loads children lazily and shows only Markdown files and directories with Markdown *somewhere beneath them* (`containsMarkdown`, which checks each level's files before descending and skips symlinks so an ancestor link can't recurse forever). A Notion export is mostly per-page image folders; without that test the tree is dominated by rows that open nothing. The cost is that a genuinely empty directory has no row at all.

**Notion mode** (`NotionExport.swift`) hides the 32-character page ID Notion appends to every exported filename, plus the extension. There is no setting: `looksLikeExport` samples up to 40 Markdown files under the root and turns it on when ≥60% match the pattern. The answer is computed **once**, in `AppDelegate.openFolderWindow` (which needs it for the window title too) and handed to `FolderBrowserView` — it reads directories, so it must not sit anywhere a view update can reach it. It affects display *only*: the real names are what the links between pages resolve against. `Rename…` is the single place the two meet — it offers the short name and `NotionExport.filename(for:isDirectory:renamedTo:)` puts the ID and extension back, since dropping the ID would break every link to that page. `displayName`/`filename` take `isDirectory` explicitly rather than inferring it, so a folder named `v1.0` doesn't lose its `.0`.

### Zip archives

A `.zip` opens as a folder-browser window: `ZipFolder.unpack` (Zipcode) unpacks it into `~/Library/Caches/<bundle id>/Archives/<name>-<digest of path>/` and the existing browser is pointed at that. Serving entries from the archive instead would have meant a virtual filesystem — `FileNode`, `LooseFile`, `FileWatcher`, the scheme handler and `openLocalLink` are all URL-and-disk based — so unpacking buys every one of them unchanged.

What that costs and how each cost is met:
- Edits to the unpacked copy would never reach the archive, so those windows are **read-only**: `NavigationState.isReadOnly` folds into `canEdit` (covering the toolbar button, Cmd+Shift+E *and* the menu item, which all route through it) and `FolderBrowserView` drops the mutating context-menu items.
- A stamp file (`.unfold-unpacked`, holding the archive's mtime and size) makes re-opening instant and a rebuilt archive re-unpack. It is written **last**, so an unpack that died halfway isn't mistaken for a finished one. `pruneCache` drops copies untouched for 30 days, at launch.
- Unpacking runs off the main thread (a large archive would freeze the app before any window appeared), with an in-flight `Set` so a double-drop doesn't open two windows. Windows are keyed by the **archive** URL, never the unpacked copy.
- Entry names are input, not fact: `safeRelativePath` refuses absolute paths and `..` components (zip slip), and drops `__MACOSX`, `._*` and `.DS_Store`.

Two shapes real exports come in, both handled in `unpack`: Notion's outer zip contains **nothing but** the real archive (`ExportBlock-…-Part-1.zip`, plus Part-2… when large), so `unpackNestedParts` unpacks an archive-of-only-archives in place and merges the parts — "nothing but" being what stops it touching a docs folder that merely ships a zip. And an archive that wraps everything in one folder is browsed at that folder, not the wrapper (`browsableRoot`), which is also where the window title comes from: Notion names its zip after two internal IDs, so `Unpacked.titleSource` prefers the wrapper's name.

### TOC / headings

`HeadingItem.swift` turns the flat heading list (sent from JS) into a nested tree (`buildHeadingTree`) for the inspector sidebar in `ContentView`. `preserveExpansionState` keeps disclosure-group open/closed state across reloads. Heading slugs must match between Swift and JS — both derive them from heading text, but the authoritative slugs are generated in JS (`renderer.heading`) and sent over, so the sidebar links resolve correctly even with duplicate headings.

### Commands & menus

`UnfoldApp` wires menu commands. Export PDF (Cmd+E), Print (Cmd+P), reload (Cmd+R), Show/Hide Editor (Cmd+Shift+E), appearance toggle, and TOC toggle are driven through `NavigationState` / its `coordinator` (a `@FocusedValue`). Back/forward (Cmd+[ / Cmd+]) are a **Go** menu rather than shortcuts on the toolbar buttons (`BackForwardButtons`, shared by both windows) — on the buttons they only fired in whichever window declared them, so the folder browser never got them. The shared `@Observable NavigationState` (notably `isEditing`) ties the menu/toolbar toggles, the split layout, and the coordinator together. File > New (Cmd+N) creates a blank untitled document. PDF export forces light appearance temporarily for legible output. `CLIInstaller` offers a copyable `sudo cp` command to install the bundled `unfold` CLI shim (`Unfold/Resources/unfold`) into `/usr/local/bin`.

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
