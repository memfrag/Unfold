import Foundation

/// Notion's Markdown export appends a 32-character page ID to every filename —
/// "Onboarding 66b0a50c907241afb71ead153aeeadd8.md" — which makes a sidebar of
/// such a folder near unreadable. A folder browser detects an export when it
/// opens and shows the names without the ID (and without the extension).
///
/// Only the *display* is affected. The files keep their real names, which the
/// links between pages depend on, so Reveal in Finder, an external editor, and
/// the link resolution in `Coordinator.openLocalLink` all go on working with
/// what is actually on disk. `Rename…` is the one place both meet: it offers the
/// short name and puts the ID back before saving.
enum NotionExport {
    /// Whether a folder looks like a Notion export, judged by sampling the
    /// Markdown files under it.
    ///
    /// A ratio rather than "all of them", because an export usually picks up a
    /// stray README or note along the way; a sample rather than a full walk,
    /// because this runs on the main thread as the window opens.
    static func looksLikeExport(_ root: URL) -> Bool {
        var directories = [root]
        var sampled = 0
        var matched = 0

        while sampled < sampleSize, let directory = directories.popLast() {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { continue }
                if values?.isDirectory == true {
                    directories.append(entry)
                } else if FileNode.isMarkdown(entry) {
                    sampled += 1
                    if pageIDRange(in: entry.deletingPathExtension().lastPathComponent) != nil {
                        matched += 1
                    }
                    if sampled >= sampleSize { break }
                }
            }
        }

        guard sampled > 0 else { return false }
        return Double(matched) / Double(sampled) >= matchRatio
    }

    /// The name to show for a file or folder: no page ID, and no extension on
    /// files. `isDirectory` is passed in rather than inferred so a folder that
    /// happens to be named like "v1.0" doesn't lose its ".0".
    static func displayName(for url: URL, isDirectory: Bool) -> String {
        let base = isDirectory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        guard let id = pageIDRange(in: base) else { return base }
        return String(base[base.startIndex..<id.lowerBound])
    }

    /// Put a name the reader typed back into Notion's filename shape. The page
    /// ID and the extension were hidden from them, so a rename must carry both
    /// over — dropping the ID would break every link pointing at the page.
    static func filename(for url: URL, isDirectory: Bool, renamedTo newName: String) -> String {
        let base = isDirectory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        let id = pageIDRange(in: base).map { String(base[$0]) } ?? ""
        let ext = isDirectory ? "" : url.pathExtension
        return newName + id + (ext.isEmpty ? "" : "." + ext)
    }

    /// The trailing space-plus-ID, if this name carries one.
    private static func pageIDRange(in name: String) -> Range<String.Index>? {
        // Something has to remain once the " " + ID is taken off.
        guard name.count > idLength + 1 else { return nil }
        let idStart = name.index(name.endIndex, offsetBy: -idLength)
        guard name[idStart...].allSatisfy(\.isHexDigit) else { return nil }
        let separator = name.index(before: idStart)
        guard name[separator] == " " else { return nil }
        return separator..<name.endIndex
    }

    private static let idLength = 32
    private static let sampleSize = 40
    private static let matchRatio = 0.6
}
