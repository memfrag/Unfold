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

    @State private var rootNodes: [FileNode] = []
    @State private var selectedURL: URL?
    @State private var currentFile: LooseFile?
    @State private var navigationState = NavigationState()
    @State private var showTOC = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedURL) {
                OutlineGroup(rootNodes, id: \.id, children: \.children) { node in
                    FileRow(node: node)
                        .contextMenu { contextMenu(for: node) }
                        .tag(node.url)
                }
            }
            .navigationTitle(root.lastPathComponent)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            Group {
                if let currentFile {
                    FolderDetailPane(file: currentFile, navigationState: navigationState)
                } else {
                    ContentUnavailableView(
                        "No File Selected",
                        systemImage: "doc.text",
                        description: Text("Choose a Markdown file from the sidebar.")
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
        ToolbarItem(placement: .primaryAction) {
            Button {
                navigationState.edit()
            } label: {
                Image(systemName: editIcon)
            }
            .help(navigationState.editLabel)
            .disabled(currentFile == nil || !navigationState.canEdit)
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(placement: .primaryAction) {
            Button {
                navigationState.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload Preview")
            .disabled(currentFile == nil)
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

    // MARK: - Selection & loading

    private func loadTree() {
        rootNodes = FileNode.topLevelNodes(of: root)
        // Auto-open the first Markdown file, preferring top-level files.
        if selectedURL == nil {
            selectedURL = FileNode.firstMarkdownFile(in: rootNodes)?.url
        }
    }

    private func openSelection(_ url: URL?) {
        // Flush any pending save on the file we're leaving.
        currentFile?.flush()

        guard let url, isMarkdown(url) else {
            currentFile = nil
            navigationState.reloadFromDisk = nil
            navigationState.flushPendingEdits = nil
            navigationState.fileURL = nil
            return
        }
        let file = LooseFile(url: url)
        currentFile = file
        navigationState.fileURL = url
        // Capture the file itself rather than reading `currentFile` later, so
        // these can't outlive their selection and act on the wrong file.
        navigationState.reloadFromDisk = { file.reloadFromDisk() }
        navigationState.flushPendingEdits = { file.flush() }
        file.onExternalChange = { [navigationState] text in
            navigationState.coordinator?.render(markdown: text)
        }
    }

    private func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
    }

    // MARK: - File operations

    @ViewBuilder
    private func contextMenu(for node: FileNode) -> some View {
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        }
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
        let alert = NSAlert()
        alert.messageText = "Rename “\(node.name)”"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = node.name
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != node.name else { return }

        let dir = node.url.deletingLastPathComponent()
        let dest = dir.appendingPathComponent(newName)
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

    var body: some View {
        Label {
            Text(node.name).lineLimit(1)
        } icon: {
            Image(systemName: node.isDirectory ? "folder" : "doc.text")
                .foregroundStyle(node.isDirectory ? Color.accentColor : Color.secondary)
        }
    }
}
