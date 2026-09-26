import Foundation

/// A lazily-loaded node in the folder browser's directory tree.
///
/// Only subdirectories and Markdown files are surfaced; dotfiles and a set of
/// well-known "noise" directories are hidden. Children are loaded on first
/// access (when a `DisclosureGroup` expands) so opening a large tree stays cheap.
@Observable
final class FileNode: Identifiable {
    let url: URL
    let isDirectory: Bool

    /// `nil` until first loaded. `OutlineGroup`/`DisclosureGroup` reads this to
    /// decide whether a row is expandable, so directories always return a
    /// (possibly empty) array while files return `nil`.
    private var loadedChildren: [FileNode]?

    var id: URL { url }

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    /// A directory whose children are already decided — a filtered tree's,
    /// which shows only the matching part of what's on disk.
    private init(directory url: URL, children: [FileNode]) {
        self.url = url
        self.isDirectory = true
        self.loadedChildren = children
    }

    var name: String { url.lastPathComponent }

    /// Lazily-loaded, filtered, sorted children. `nil` for files (a leaf row).
    var children: [FileNode]? {
        guard isDirectory else { return nil }
        if let loadedChildren { return loadedChildren }
        let loaded = Self.loadChildren(of: url)
        loadedChildren = loaded
        return loaded
    }

    /// Re-read every directory that has been loaded and reconcile it with what
    /// is on screen, so files added or removed by something outside the app show
    /// up. Directories nobody has expanded are left alone — they are still lazy,
    /// and will read fresh when they are opened.
    ///
    /// The children list is only replaced when it genuinely differs, since
    /// assigning it tells every view observing this node to update.
    func refresh() {
        guard isDirectory, let existing = loadedChildren else { return }
        let reconciled = Self.reconcile(Self.loadChildren(of: url), with: existing)
        if reconciled.map(\.url) != existing.map(\.url) {
            loadedChildren = reconciled
        }
        for child in reconciled where child.isDirectory {
            child.refresh()
        }
    }

    /// Match a freshly-read directory listing against the nodes already on
    /// screen, keeping the existing instance wherever the URL is unchanged.
    ///
    /// Identity is the point. Handing `OutlineGroup` a wholly new set of nodes
    /// would take the disclosure state with it and collapse folders the reader
    /// had opened — and each surviving node also carries its own loaded
    /// children, which a replacement would throw away and have to read again.
    static func reconcile(_ fresh: [FileNode], with existing: [FileNode]) -> [FileNode] {
        let byURL = Dictionary(existing.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        return fresh.map { byURL[$0.url] ?? $0 }
    }

    /// The first file to auto-open when the browser window appears. Prefers a
    /// file directly in this directory over one nested in a subdirectory, so
    /// e.g. a top-level `README.md` wins over `docs/intro.md`.
    var firstViewableFile: FileNode? {
        if !isDirectory { return Self.isViewable(url) ? self : nil }
        return Self.firstViewableFile(in: children ?? [])
    }

    /// Among sibling nodes, return the first file directly present; otherwise
    /// descend into subdirectories in order. (All non-directory nodes are
    /// already viewable thanks to the load-time filter.)
    static func firstViewableFile(in nodes: [FileNode]) -> FileNode? {
        if let file = nodes.first(where: { !$0.isDirectory }) { return file }
        for dir in nodes where dir.isDirectory {
            if let found = dir.firstViewableFile { return found }
        }
        return nil
    }

    // MARK: - Loading & filtering

    private static func loadChildren(of directory: URL) -> [FileNode] {
        listing(of: directory).map { FileNode(url: $0.url, isDirectory: $0.isDirectory) }
    }

    /// What a directory shows, in order: filtered and sorted, but not yet
    /// nodes — so it can be read off the main thread (the sidebar filter does).
    nonisolated private static func listing(of directory: URL) -> [Entry] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var shown: [Entry] = []
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard shouldShow(entry, isDirectory: isDir) else { continue }
            shown.append(Entry(url: entry, isDirectory: isDir))
        }

        // Directories first, then files; each group alphabetical, case-insensitive.
        return shown.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        }
    }

    nonisolated struct Entry: Sendable {
        let url: URL
        let isDirectory: Bool
    }

    /// Directories with well-known build/VCS noise names are hidden, as are
    /// directories with nothing viewable anywhere beneath them — a folder
    /// holding nothing but a page's images (what a Notion export is largely made
    /// of) is an empty row in a document browser. A directory that is empty
    /// outright is the exception: that is a folder someone has just made to put
    /// pages in, and hiding it would leave nothing to select and add them to.
    /// Files are only shown if the app can display them. (Dotfiles are already
    /// excluded by `.skipsHiddenFiles` at the enumeration step.)
    nonisolated private static func shouldShow(_ url: URL, isDirectory: Bool) -> Bool {
        if isDirectory {
            return !noiseDirectories.contains(url.lastPathComponent)
                && (isEmptyDirectory(url) || containsViewableFile(url))
        }
        return isViewable(url)
    }

    /// Whether a directory has nothing in it but hidden files (a stray
    /// `.DS_Store` shouldn't make a new folder vanish).
    nonisolated private static func isEmptyDirectory(_ directory: URL) -> Bool {
        let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return entries?.isEmpty ?? false
    }

    /// Whether any file the app can display lives in this directory or below it.
    ///
    /// Every file at a level is checked before descending, so the common case —
    /// a folder with its own pages in it — costs a single directory read.
    /// Symlinks are skipped rather than followed: one pointing at an ancestor
    /// would otherwise recurse forever.
    nonisolated private static func containsViewableFile(_ directory: URL) -> Bool {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        var subdirectories: [URL] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                if !noiseDirectories.contains(entry.lastPathComponent) {
                    subdirectories.append(entry)
                }
            } else if isViewable(entry) {
                return true
            }
        }
        return subdirectories.contains(where: containsViewableFile)
    }

    /// The one place that decides what counts as a Markdown file — the tree
    /// filter, the folder browser's selection, and link-following all share it.
    /// Markdown is the editable kind; HTML is only ever displayed.
    nonisolated static func isMarkdown(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    nonisolated static func isHTML(_ url: URL) -> Bool {
        htmlExtensions.contains(url.pathExtension.lowercased())
    }

    /// Whether the app can show this file at all.
    nonisolated static func isViewable(_ url: URL) -> Bool {
        isMarkdown(url) || isHTML(url)
    }

    nonisolated private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]
    nonisolated private static let htmlExtensions: Set<String> = ["html", "htm"]

    nonisolated private static let noiseDirectories: Set<String> = [
        ".git", ".svn", ".hg",
        "node_modules", ".build", "build", "DerivedData",
        "Pods", ".swiftpm", ".venv", "venv", "__pycache__",
        ".idea", ".vscode", "dist", ".next", "target",
    ]
}

extension FileNode {
    /// One match of the sidebar filter. `children` is nil for a file, and for a
    /// folder kept only because its own name matched — that one stays an
    /// ordinary lazy node, contents and all.
    nonisolated struct FilterMatch: Sendable {
        let url: URL
        let isDirectory: Bool
        let children: [FilterMatch]?
    }

    /// The sidebar's filter: the part of the tree under `directory` whose names
    /// `matches` accepts, read from disk rather than from what has been loaded,
    /// since the match may be in a folder nobody has opened.
    ///
    /// A matching file is kept on its own. A folder with matches beneath it holds
    /// just those, whatever its own name — so a `Headless` folder filtered on
    /// "headless" opens onto its `headless.md` rather than hiding it. A folder
    /// whose name matches but whose contents don't is kept whole.
    ///
    /// Slow on a large tree, so it's made to run off the main thread, and gives
    /// up as soon as its task is cancelled (the filter text changed again).
    nonisolated static func filterMatches(
        in directory: URL,
        matching matches: (URL, _ isDirectory: Bool) -> Bool
    ) -> [FilterMatch] {
        var result: [FilterMatch] = []
        for entry in listing(of: directory) {
            if Task.isCancelled { return [] }
            if entry.isDirectory {
                let inner = filterMatches(in: entry.url, matching: matches)
                if !inner.isEmpty {
                    result.append(FilterMatch(url: entry.url, isDirectory: true, children: inner))
                } else if matches(entry.url, true) {
                    result.append(FilterMatch(url: entry.url, isDirectory: true, children: nil))
                }
            } else if matches(entry.url, false) {
                result.append(FilterMatch(url: entry.url, isDirectory: false, children: nil))
            }
        }
        return result
    }

    /// Turn filter matches into nodes for the sidebar. `expanded` collects the
    /// folders holding matches, since showing those is the point; a folder kept
    /// only for its name stays closed.
    static func nodes(for matches: [FilterMatch], expanded: inout Set<URL>) -> [FileNode] {
        matches.map { match in
            guard let children = match.children else {
                return FileNode(url: match.url, isDirectory: match.isDirectory)
            }
            expanded.insert(match.url)
            return FileNode(directory: match.url, children: nodes(for: children, expanded: &expanded))
        }
    }

    /// Convenience: build the top-level nodes for a dropped folder. The folder's
    /// *contents* appear at the top level (the folder itself is not shown as a
    /// single root row).
    static func topLevelNodes(of root: URL) -> [FileNode] {
        loadChildren(of: root)
    }
}
