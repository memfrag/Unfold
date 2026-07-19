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

    var name: String { url.lastPathComponent }

    /// Lazily-loaded, filtered, sorted children. `nil` for files (a leaf row).
    var children: [FileNode]? {
        guard isDirectory else { return nil }
        if let loadedChildren { return loadedChildren }
        let loaded = Self.loadChildren(of: url)
        loadedChildren = loaded
        return loaded
    }

    /// Discard cached children so the next access re-reads from disk. Used after
    /// a file operation (new file, rename, trash) changes a directory's contents.
    func reload() {
        loadedChildren = nil
    }

    /// The first Markdown file to auto-open when the browser window appears.
    /// Prefers a file directly in this directory over one nested in a
    /// subdirectory, so e.g. a top-level `README.md` wins over `docs/intro.md`.
    var firstMarkdownFile: FileNode? {
        if !isDirectory { return Self.isMarkdown(url) ? self : nil }
        return Self.firstMarkdownFile(in: children ?? [])
    }

    /// Among sibling nodes, return the first Markdown file directly present;
    /// otherwise descend into subdirectories in order. (All non-directory nodes
    /// are already Markdown thanks to the load-time filter.)
    static func firstMarkdownFile(in nodes: [FileNode]) -> FileNode? {
        if let file = nodes.first(where: { !$0.isDirectory }) { return file }
        for dir in nodes where dir.isDirectory {
            if let found = dir.firstMarkdownFile { return found }
        }
        return nil
    }

    // MARK: - Loading & filtering

    private static func loadChildren(of directory: URL) -> [FileNode] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var nodes: [FileNode] = []
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard shouldShow(entry, isDirectory: isDir) else { continue }
            nodes.append(FileNode(url: entry, isDirectory: isDir))
        }

        // Directories first, then files; each group alphabetical, case-insensitive.
        return nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Directories with well-known build/VCS noise names are hidden. Files are
    /// only shown if they are Markdown. (Dotfiles are already excluded by
    /// `.skipsHiddenFiles` at the enumeration step.)
    private static func shouldShow(_ url: URL, isDirectory: Bool) -> Bool {
        if isDirectory {
            return !noiseDirectories.contains(url.lastPathComponent)
        }
        return isMarkdown(url)
    }

    private static func isMarkdown(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    private static let noiseDirectories: Set<String> = [
        ".git", ".svn", ".hg",
        "node_modules", ".build", "build", "DerivedData",
        "Pods", ".swiftpm", ".venv", "venv", "__pycache__",
        ".idea", ".vscode", "dist", ".next", "target",
    ]
}

extension FileNode {
    /// Convenience: build the top-level nodes for a dropped folder. The folder's
    /// *contents* appear at the top level (the folder itself is not shown as a
    /// single root row).
    static func topLevelNodes(of root: URL) -> [FileNode] {
        loadChildren(of: root)
    }
}
