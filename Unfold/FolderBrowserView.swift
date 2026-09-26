import SwiftUI
import AppKit

/// The folder-browser window: a directory-tree sidebar on the left and a
/// Markdown viewer/editor on the right, opened by dropping a folder on the app.
///
/// Layout note: `.inspector()` is attached to the `NavigationSplitView` itself
/// (its documented placement), and the detail is a plain `VStack`-based pane
/// (`FolderDetailPane`) — never a nested split view. That combination is what
/// keeps the sidebar/detail/inspector layout stable on macOS.
struct FolderBrowserView: View {
    let root: URL

    /// Set when the folder was recognised as a Notion export (decided once, in
    /// `AppDelegate.openFolderWindow`, which needs the answer for the window
    /// title anyway). Purely a display concern — see `NotionExport`.
    let hidesNotionIDs: Bool

    /// Set when the folder is an archive's unpacked copy: nothing here may be
    /// edited, renamed, created or trashed, since none of it would reach the
    /// archive. See `ZipFolder`.
    let isReadOnly: Bool

    /// What the detail pane is showing. Markdown is loaded into a `LooseFile` —
    /// watched, editable, saved — while an HTML page is handed to WebKit as a
    /// file URL and only ever displayed.
    private enum Displayed {
        case markdown(LooseFile)
        case html(URL)

        var looseFile: LooseFile? {
            if case .markdown(let file) = self { return file }
            return nil
        }

        var url: URL {
            switch self {
            case .markdown(let file): file.url
            case .html(let url): url
            }
        }
    }

    @State private var rootNodes: [FileNode] = []
    @State private var selectedURL: URL?
    @State private var displayed: Displayed?
    @State private var navigationState = NavigationState()
    @State private var showTOC = false
    @State private var watcher: FolderWatcher?
    @State private var emptyAreaClicks = EmptyAreaClickCatcher()

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedURL) {
                OutlineGroup(rootNodes, id: \.id, children: \.children) { node in
                    FileRow(node: node, name: label(for: node))
                        .background(SidebarTableFinder(catcher: emptyAreaClicks))
                        .tag(node.url)
                }
            }
            // Rows only: SwiftUI doesn't offer this on the empty space below
            // them, so the root's menu is `rootContextMenu`, shown by
            // `EmptyAreaClickCatcher`.
            .contextMenu(forSelectionType: URL.self) { urls in
                if let url = urls.first { contextMenu(for: url) }
            }
            .safeAreaBar(edge: .bottom) {
                // An unpacked archive can't be added to — see `isReadOnly`.
                if !isReadOnly { addBar }
            }
            .navigationTitle(rootTitle)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            Group {
                switch displayed {
                case .markdown(let file):
                    FolderDetailPane(file: file, navigationState: navigationState)
                case .html(let url):
                    // Deliberately no `.id(url)`: one web view serves every HTML
                    // file, so going to another page loads into it instead of
                    // building a new one that flashes white on the way in.
                    HTMLWebView(
                        fileURL: url,
                        readAccessRoot: root,
                        appearance: navigationState.appearanceMode,
                        navigationState: navigationState
                    )
                case nil:
                    ContentUnavailableView(
                        "No File Selected",
                        systemImage: "doc.text",
                        description: Text("Choose a file from the sidebar.")
                    )
                }
            }
        }
        .inspector(isPresented: $showTOC) {
            TOCSidebar(navigationState: navigationState)
                .inspectorColumnWidth(min: 150, ideal: 220, max: 400)
        }
        .frame(minWidth: 700, minHeight: 480)
        .focusedSceneValue(\.navigationState, navigationState)
        .toolbar { toolbarContent }
        .onAppear {
            emptyAreaClicks.onClick = { selectedURL = nil }
            emptyAreaClicks.menu = rootContextMenu
            loadTree()
        }
        .onChange(of: selectedURL) { _, newValue in openSelection(newValue) }
    }

    // MARK: - Toolbar

    /// See `ContentView.editIcon` — in external mode Edit launches another app
    /// rather than revealing a pane, so it isn't a toggle.
    private var editIcon: String {
        if ExternalEditor.shared.isEnabled { return "arrow.up.forward.app" }
        return navigationState.isEditing ? "pencil.circle.fill" : "pencil"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            BackForwardButtons(navigationState: navigationState)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                navigationState.edit()
            } label: {
                Image(systemName: editIcon)
            }
            .help(navigationState.editLabel)
            .disabled(displayed == nil || !navigationState.canEdit)
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(placement: .primaryAction) {
            Button {
                navigationState.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload Preview")
            .disabled(displayed == nil)
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(placement: .primaryAction) {
            Button {
                let modes = AppearanceMode.allCases
                let currentIndex = modes.firstIndex(of: navigationState.appearanceMode) ?? 0
                let next = modes[(currentIndex + 1) % modes.count]
                navigationState.appearanceMode = next
                navigationState.coordinator?.setAppearance(next)
            } label: {
                Image(systemName: navigationState.appearanceMode.icon)
            }
            .help("Appearance: \(navigationState.appearanceMode.label)")
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(placement: .primaryAction) {
            Button {
                showTOC.toggle()
            } label: {
                Image(systemName: "list.bullet.indent")
            }
            .help(showTOC ? "Hide Table of Contents" : "Show Table of Contents")
        }
        .sharedBackgroundVisibility(.hidden)
    }

    // MARK: - Add bar

    /// The + menu under the sidebar. With nothing selected both go to the top
    /// level. Otherwise a new page needs a folder selected and goes into it,
    /// while a new folder goes into the selected folder or beside the selected
    /// file.
    private var addBar: some View {
        HStack {
            Menu {
                Button("New Folder…") {
                    promptForNewFolder(in: selectedDirectory ?? root)
                }
                Button("New Markdown File…") {
                    promptForNewMarkdownFile(in: selectedFolder ?? root)
                }
                .disabled(selectedURL != nil && selectedFolder == nil)
            } label: {
                Label("Add", systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add a folder or Markdown file")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The selected row, if it is a folder.
    private var selectedFolder: URL? {
        guard let selectedURL, Self.isDirectory(selectedURL) else { return nil }
        return selectedURL
    }

    /// The folder the selection lives in: the selected folder itself, or the
    /// one holding the selected file.
    private var selectedDirectory: URL? {
        selectedFolder ?? selectedURL?.deletingLastPathComponent()
    }

    // MARK: - Names

    /// What a row is called on screen, which in a Notion export is not what the
    /// file is called on disk.
    private func label(for node: FileNode) -> String {
        label(for: node.url, isDirectory: node.isDirectory)
    }

    private func label(for url: URL, isDirectory: Bool) -> String {
        guard hidesNotionIDs else { return url.lastPathComponent }
        return NotionExport.displayName(for: url, isDirectory: isDirectory)
    }

    private var rootTitle: String {
        guard hidesNotionIDs else { return root.lastPathComponent }
        return NotionExport.displayName(for: root, isDirectory: true)
    }

    // MARK: - Selection & loading

    private func loadTree() {
        // Links between files in the tree are followed in place, by selecting
        // the target — a link that points outside the folder has no row to
        // select, so it gets a window of its own. Both sides are compared as
        // physical paths: the tree's URLs come from `FileManager` while the root
        // may have been opened through a symlink, and a mismatch there would
        // send a link that is plainly inside the folder off to its own window.
        let rootPath = root.physicalURL.path
        navigationState.openFile = { url in
            let target = url.physicalURL
            if target.path.hasPrefix(rootPath + "/") {
                selectedURL = target
            } else {
                NavigationState.openInNewWindow(target)
            }
        }
        navigationState.refreshTree = { refreshTree() }
        rootNodes = FileNode.topLevelNodes(of: root)
        // Auto-open the first file, preferring top-level ones.
        if selectedURL == nil {
            selectedURL = FileNode.firstViewableFile(in: rootNodes)?.url
        }
        // An unpacked archive is a private copy that nothing else writes to, so
        // there is nothing to watch for.
        if !isReadOnly {
            watcher = FolderWatcher(url: root) { refreshTree() }
        }
    }

    /// Bring the tree back in step with the folder — a file added, renamed or
    /// removed by something outside the app. Driven by `FolderWatcher` and by
    /// View ▸ Refresh Folder.
    private func refreshTree() {
        // The top level is reconciled the same way a directory's children are,
        // so nodes (and the subtrees they have loaded) survive the refresh.
        let fresh = FileNode.reconcile(FileNode.topLevelNodes(of: root), with: rootNodes)
        if fresh.map(\.url) != rootNodes.map(\.url) {
            rootNodes = fresh
        }
        for node in fresh where node.isDirectory {
            node.refresh()
        }

        // The file on screen may be the one that just disappeared.
        if let selectedURL, !FileManager.default.fileExists(atPath: selectedURL.path) {
            self.selectedURL = nil
        }
    }

    private func openSelection(_ url: URL?) {
        // Deselecting — a click on the empty part of the sidebar — only changes
        // where new items go; the page stays on screen. (The file vanishing
        // from disk also clears the selection, and that does clear the pane.)
        // Clicking the page's own row again afterwards has nothing to load.
        if let current = displayed?.url {
            if url == current { return }
            if url == nil, FileManager.default.fileExists(atPath: current.path) { return }
        }

        // Flush any pending save on the file we're leaving.
        displayed?.looseFile?.flush()

        // Hooks belonging to the outgoing file, cleared before the incoming one
        // sets whichever of them apply to it.
        navigationState.reloadFromDisk = nil
        navigationState.flushPendingEdits = nil
        navigationState.reloadDisplay = nil
        navigationState.fileURL = url
        navigationState.isEditable = false

        guard let url, FileNode.isViewable(url) else {
            displayed = nil
            navigationState.fileURL = nil
            navigationState.headings = []
            return
        }

        // Every way of arriving at a file — the sidebar, a followed link, a
        // history move — passes through here, so this is the one place the
        // history has to be told. It ignores arrivals at the file we're already
        // on, which is what keeps a history move from recording itself.
        navigationState.navigated(to: url)

        guard FileNode.isMarkdown(url) else {
            // An HTML page: nothing to edit, and no headings to offer — the TOC
            // is built by the Markdown renderer, so the outgoing file's would
            // otherwise linger in the inspector.
            displayed = .html(url)
            navigationState.headings = []
            return
        }

        let file = LooseFile(url: url)
        displayed = .markdown(file)
        // Files in an unpacked archive are a cached copy; editing them would
        // never reach the archive.
        navigationState.isEditable = !isReadOnly
        // Capture the file itself rather than reading `displayed` later, so
        // these can't outlive their selection and act on the wrong file.
        navigationState.reloadFromDisk = { file.reloadFromDisk() }
        navigationState.flushPendingEdits = { file.flush() }
        file.onExternalChange = { [navigationState] text in
            navigationState.coordinator?.render(markdown: text)
        }
    }

    // MARK: - File operations

    /// The context menu for a row.
    @ViewBuilder
    private func contextMenu(for url: URL) -> some View {
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        // Everything below writes to disk, which for an unpacked archive means
        // writing to a cached copy the archive will never see.
        if !isReadOnly {
            let dir = targetDirectory(for: url)
            Divider()
            Button("New Folder…") {
                promptForNewFolder(in: dir)
            }
            Button("New Markdown File…") {
                promptForNewMarkdownFile(in: dir)
            }
            Divider()
            Button("Rename…") {
                rename(url)
            }
            Button("Move to Trash") {
                moveToTrash(url)
            }
        }
    }

    /// The context menu for the empty space below the rows: the root's. An
    /// `NSMenu` because it is shown from AppKit — see `EmptyAreaClickCatcher`.
    private func rootContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Reveal in Finder") { [root] in
            NSWorkspace.shared.activateFileViewerSelecting([root])
        })
        if !isReadOnly {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("New Folder…") { promptForNewFolder(in: root) })
            menu.addItem(ClosureMenuItem("New Markdown File…") { promptForNewMarkdownFile(in: root) })
        }
        return menu
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// Directory to create a new item in: the URL itself if it's a folder,
    /// otherwise the folder containing it.
    private func targetDirectory(for url: URL) -> URL {
        Self.isDirectory(url) ? url : url.deletingLastPathComponent()
    }

    private func promptForNewMarkdownFile(in dir: URL) {
        guard let name = promptForName(title: "New Markdown File", defaultName: "Untitled") else { return }
        // Typing the extension is optional; anything the app wouldn't show
        // in the sidebar gets `.md` added so the new file doesn't vanish.
        let filename = FileNode.isMarkdown(URL(fileURLWithPath: name)) ? name : name + ".md"
        createMarkdownFile(at: dir.appendingPathComponent(filename))
    }

    private func createMarkdownFile(at url: URL) {
        let title = url.deletingPathExtension().lastPathComponent
        do {
            try Data("# \(title)\n".utf8).write(to: url, options: .withoutOverwriting)
            refreshTree()
            selectedURL = url
        } catch {
            presentError("Couldn’t create file", error)
        }
    }

    private func promptForNewFolder(in dir: URL) {
        guard let name = promptForName(title: "New Folder", defaultName: "untitled folder") else { return }
        let url = dir.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            refreshTree()
            selectedURL = url
        } catch {
            presentError("Couldn’t create folder", error)
        }
    }

    /// Ask for the name of something about to be created. Returns nil on Cancel,
    /// and for a name that can't be a single visible item in a folder: a slash
    /// would make it a path, and a leading dot would hide it from the sidebar.
    private func promptForName(title: String, defaultName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultName
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else {
            NSSound.beep()
            return nil
        }
        return name
    }

    private func rename(_ url: URL) {
        let isDirectory = Self.isDirectory(url)
        let currentName = label(for: url, isDirectory: isDirectory)
        let alert = NSAlert()
        alert.messageText = "Rename “\(currentName)”"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = currentName
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != currentName else { return }

        // The reader was shown the name without its page ID and extension, so
        // the rename has to put both back — losing the ID would break every
        // link pointing at this page.
        let filename = hidesNotionIDs
            ? NotionExport.filename(for: url, isDirectory: isDirectory, renamedTo: newName)
            : newName
        let dest = url.deletingLastPathComponent().appendingPathComponent(filename)
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            let wasSelected = selectedURL == url
            refreshTree()
            if wasSelected { selectedURL = dest }
        } catch {
            presentError("Couldn’t rename", error)
        }
    }

    private func moveToTrash(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            if selectedURL == url { selectedURL = nil }
            refreshTree()
        } catch {
            presentError("Couldn’t move to Trash", error)
        }
    }

    private func presentError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// A single row in the directory tree: an icon plus the file/folder name.
private struct FileRow: View {
    let node: FileNode
    let name: String

    var body: some View {
        Label {
            Text(name).lineLimit(1)
        } icon: {
            Image(systemName: node.isDirectory ? "folder" : "doc.text")
                .foregroundStyle(node.isDirectory ? Color.accentColor : Color.secondary)
        }
    }
}

/// Gives the empty space below the sidebar's rows the behavior the list
/// doesn't: a click there clears the selection — which is what decides where
/// the + menu puts new items, so without it there'd be no way back to "the top
/// level" once anything had been clicked — and a right-click (or Control-click)
/// there shows the root's context menu, which `contextMenu(forSelectionType:)`
/// only offers on rows.
///
/// The table is found from inside a row (`SidebarTableFinder`), since that is
/// the one place guaranteed to be in its view hierarchy — a background on the
/// `List` itself is never hosted in a window. A mouse-down is acted on only
/// when it hits that table (or the clip view around it, when the rows don't
/// fill the column) with no row under it, so rows, disclosure triangles and
/// the + button floating over the bottom are left alone.
final class EmptyAreaClickCatcher {
    var onClick: (() -> Void)?
    var menu: (() -> NSMenu)?
    private var monitor: Any?

    weak var table: NSTableView? {
        didSet {
            guard table != nil, monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                self?.handle(event) ?? event
            }
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    /// Returns the event to let it through, nil to swallow it.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let table, isEmptyArea(of: table, event) else { return event }
        let isMenuClick = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
        guard isMenuClick else {
            onClick?()
            return event
        }
        if let menu = menu?() {
            NSMenu.popUpContextMenu(menu, with: event, for: table)
        }
        return nil
    }

    private func isEmptyArea(of table: NSTableView, _ event: NSEvent) -> Bool {
        guard let window = table.window, event.window === window,
              let content = window.contentView
        else { return false }
        let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
        guard hit === table || (hit as? NSClipView)?.documentView === table else { return false }
        return table.row(at: table.convert(event.locationInWindow, from: nil)) == -1
    }
}

/// An `NSMenuItem` that runs a closure, for menus built in SwiftUI code.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// Hands the sidebar's table view to an `EmptyAreaClickCatcher`, by looking
/// up from a row once that row is in a window.
private struct SidebarTableFinder: NSViewRepresentable {
    let catcher: EmptyAreaClickCatcher

    func makeNSView(context: Context) -> Probe { Probe(catcher: catcher) }
    func updateNSView(_ view: Probe, context: Context) {}

    final class Probe: NSView {
        let catcher: EmptyAreaClickCatcher

        init(catcher: EmptyAreaClickCatcher) {
            self.catcher = catcher
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, catcher.table == nil else { return }
            catcher.table = sequence(first: self as NSView, next: \.superview)
                .lazy.compactMap { $0 as? NSTableView }.first
        }
    }
}
