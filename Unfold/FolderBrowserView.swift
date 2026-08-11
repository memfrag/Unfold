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
    }

    @State private var rootNodes: [FileNode] = []
    @State private var selectedURL: URL?
    @State private var displayed: Displayed?
    @State private var navigationState = NavigationState()
    @State private var showTOC = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedURL) {
                OutlineGroup(rootNodes, id: \.id, children: \.children) { node in
                    FileRow(node: node, name: label(for: node))
                        .contextMenu { contextMenu(for: node) }
                        .tag(node.url)
                }
            }
            .navigationTitle(rootTitle)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            Group {
                switch displayed {
                case .markdown(let file):
                    FolderDetailPane(file: file, navigationState: navigationState)
                case .html(let url):
                    HTMLWebView(
                        fileURL: url,
                        readAccessRoot: root,
                        appearance: navigationState.appearanceMode,
                        navigationState: navigationState
                    )
                    .id(url)
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
        .onAppear(perform: loadTree)
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

    // MARK: - Names

    /// What a row is called on screen, which in a Notion export is not what the
    /// file is called on disk.
    private func label(for node: FileNode) -> String {
        guard hidesNotionIDs else { return node.name }
        return NotionExport.displayName(for: node.url, isDirectory: node.isDirectory)
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
        rootNodes = FileNode.topLevelNodes(of: root)
        // Auto-open the first file, preferring top-level ones.
        if selectedURL == nil {
            selectedURL = FileNode.firstViewableFile(in: rootNodes)?.url
        }
    }

    private func openSelection(_ url: URL?) {
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

    @ViewBuilder
    private func contextMenu(for node: FileNode) -> some View {
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        }
        // Everything below writes to disk, which for an unpacked archive means
        // writing to a cached copy the archive will never see.
        if !isReadOnly {
            Button("New Markdown File") {
                newMarkdownFile(in: node)
            }
            Divider()
            Button("Rename…") {
                rename(node)
            }
            Button("Move to Trash") {
                moveToTrash(node)
            }
        }
    }

    /// Directory to create a new file in: the node itself if it's a folder,
    /// otherwise the folder containing it.
    private func targetDirectory(for node: FileNode) -> URL {
        node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    }

    private func newMarkdownFile(in node: FileNode) {
        let dir = targetDirectory(for: node)
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent("Untitled.md")
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("Untitled \(n).md")
            n += 1
        }
        do {
            try Data("# Untitled\n".utf8).write(to: candidate, options: .withoutOverwriting)
            refresh(directory: dir)
            selectedURL = candidate
        } catch {
            presentError("Couldn’t create file", error)
        }
    }

    private func rename(_ node: FileNode) {
        let currentName = label(for: node)
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
            ? NotionExport.filename(for: node.url, isDirectory: node.isDirectory, renamedTo: newName)
            : newName
        let dir = node.url.deletingLastPathComponent()
        let dest = dir.appendingPathComponent(filename)
        do {
            try FileManager.default.moveItem(at: node.url, to: dest)
            let wasSelected = selectedURL == node.url
            refresh(directory: dir)
            if wasSelected { selectedURL = dest }
        } catch {
            presentError("Couldn’t rename", error)
        }
    }

    private func moveToTrash(_ node: FileNode) {
        let dir = node.url.deletingLastPathComponent()
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            if selectedURL == node.url { selectedURL = nil }
            refresh(directory: dir)
        } catch {
            presentError("Couldn’t move to Trash", error)
        }
    }

    /// Reload the tree so a directory's changed contents show up. Reloads the
    /// specific directory node when found; falls back to rebuilding the top level.
    private func refresh(directory: URL) {
        if directory == root {
            rootNodes = FileNode.topLevelNodes(of: root)
        } else if let node = findNode(url: directory, in: rootNodes) {
            node.reload()
        } else {
            rootNodes = FileNode.topLevelNodes(of: root)
        }
    }

    private func findNode(url: URL, in nodes: [FileNode]) -> FileNode? {
        for node in nodes {
            if node.url == url { return node }
            if let children = node.children, let found = findNode(url: url, in: children) {
                return found
            }
        }
        return nil
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
