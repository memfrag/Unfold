import Foundation
import CryptoKit
import Zipcode

/// Opens a `.zip` the way the folder browser opens a directory: by unpacking it
/// into the cache and browsing that.
///
/// Serving entries straight out of the archive was the alternative, and it would
/// have meant building a virtual filesystem — `FileNode`, `LooseFile`,
/// `FileWatcher`, the `unfold-resource://` scheme handler and link resolution
/// are all URL-and-disk based, so every one of them would need an abstraction
/// behind it. Unpacking buys all of that unchanged. The costs are a copy on disk
/// (cached, and reused while the archive is untouched) and a window that is
/// read-only, since an edit to the copy would never reach the archive.
enum ZipFolder {

    /// What came out of an archive.
    struct Unpacked {
        /// The directory to browse.
        let root: URL

        /// What to name the window. The wrapper folder when the archive had one,
        /// because Notion names its zip after two internal IDs
        /// ("3e5047f1-…_ExportBlock-d68f17bc-….zip") — a title that tells the
        /// reader nothing. Otherwise the archive's own name.
        let titleSource: URL
    }

    /// Unpack `zipURL` if needed and return the directory to browse.
    ///
    /// Reads and writes every entry, so call it off the main thread.
    static func unpack(_ zipURL: URL) throws -> Unpacked {
        let destination = try cacheDirectory(for: zipURL)
        if isUnpacked(destination, from: zipURL) {
            return result(destination, from: zipURL)
        }

        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try extract(zipURL, into: destination)
        try unpackNestedParts(in: destination)

        // Written last, so an unpack that died halfway is not mistaken for a
        // finished one and is simply redone.
        try? Data(stamp(of: zipURL).utf8).write(to: destination.appendingPathComponent(stampName))
        return result(destination, from: zipURL)
    }

    private static func result(_ destination: URL, from zipURL: URL) -> Unpacked {
        let root = browsableRoot(of: destination)
        return Unpacked(
            root: root,
            titleSource: root == destination ? zipURL.deletingPathExtension() : root
        )
    }

    private static func extract(_ zipURL: URL, into destination: URL) throws {
        let fm = FileManager.default
        let archive = ZipArchive(path: zipURL.path)
        try archive.read { reader in
            for entry in try reader.entries() {
                guard let path = safeRelativePath(entry.name) else { continue }
                let target = destination.appendingPathComponent(path)
                if entry.isDirectory {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                } else {
                    // Entries are not guaranteed to be preceded by their
                    // directory, so make the parent either way.
                    try fm.createDirectory(
                        at: target.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    // Streams to disk rather than through memory: a Notion
                    // export's images are the bulk of an archive.
                    try reader.readEntry(at: entry.index, to: target.path)
                }
            }
        }
    }

    /// Unpack an archive of nothing but archives, in place.
    ///
    /// Notion hands you an outer zip holding only the real one —
    /// "ExportBlock-….zip" containing "ExportBlock-…-Part-1.zip", and Part-2 and
    /// so on when the export is large. Unpacked as-is, that browses as a folder
    /// with no pages in it at all. The parts are merged into one tree, which is
    /// how they are meant to be read.
    ///
    /// The "nothing but" is the point: a documentation folder that happens to
    /// ship a zip alongside its pages is left exactly as it is.
    private static func unpackNestedParts(in directory: URL, depth: Int = 0) throws {
        guard depth < maxNesting else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        let archives = entries.filter { $0.pathExtension.lowercased() == "zip" }
        guard !archives.isEmpty, archives.count == entries.count else { return }

        for archive in archives {
            try extract(archive, into: directory)
            try? fm.removeItem(at: archive)
        }
        try unpackNestedParts(in: directory, depth: depth + 1)
    }

    /// Discard unpacked copies that haven't been opened in a while, so the cache
    /// doesn't grow without bound. An archive opened again after that is just
    /// unpacked afresh.
    static func pruneCache(olderThan age: TimeInterval = 30 * 24 * 60 * 60) {
        let fm = FileManager.default
        guard let root = try? cacheRoot(),
              let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return }

        for entry in entries {
            let stamp = entry.appendingPathComponent(stampName)
            let unpacked = (try? stamp.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            // No stamp means an unpack that never finished — also rubbish.
            guard let unpacked else {
                try? fm.removeItem(at: entry)
                continue
            }
            if Date().timeIntervalSince(unpacked) > age {
                try? fm.removeItem(at: entry)
            }
        }
    }

    // MARK: - Cache

    private static func isUnpacked(_ destination: URL, from zipURL: URL) -> Bool {
        let stampURL = destination.appendingPathComponent(stampName)
        guard let recorded = try? String(contentsOf: stampURL, encoding: .utf8) else { return false }
        return recorded == stamp(of: zipURL)
    }

    /// Identifies the archive as it was when unpacked. Size as well as date,
    /// because a rebuilt export can land with the same timestamp.
    private static func stamp(of zipURL: URL) -> String {
        let values = try? zipURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        return "\(modified)-\(values?.fileSize ?? 0)"
    }

    private static func cacheRoot() throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let bundleID = Bundle.main.bundleIdentifier ?? "io.apparata.Unfold"
        return caches.appendingPathComponent(bundleID).appendingPathComponent("Archives")
    }

    /// One directory per archive, named after it for legibility in Finder and
    /// disambiguated by a digest of its full path — two exports of the same page
    /// from different folders must not land on top of each other. The digest is
    /// of the path rather than the contents so it can be computed without
    /// reading the archive, and it is stable across launches, which
    /// `hashValue` (per-process seeded) would not be.
    private static func cacheDirectory(for zipURL: URL) throws -> URL {
        let digest = SHA256.hash(data: Data(zipURL.path.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        let name = zipURL.deletingPathExtension().lastPathComponent
        let root = try cacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("\(name)-\(digest)")
    }

    /// An archive usually wraps everything in a single folder; browsing that
    /// folder rather than the wrapper skips a level that says nothing.
    private static func browsableRoot(of directory: URL) -> URL {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ), entries.count == 1, let only = entries.first,
        (try? only.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        else { return directory }
        return only
    }

    /// Where an entry may be written, or nil if it may not be.
    ///
    /// Entry names come out of the archive, so they are input, not fact: an
    /// entry called `../../.zshrc` would otherwise be written clean outside the
    /// cache. Also drops the metadata macOS packs into archives it creates.
    private static func safeRelativePath(_ name: String) -> String? {
        guard !name.hasPrefix("/") else { return nil }
        let components = name.split(separator: "/").map(String.init)
        guard !components.isEmpty,
              !components.contains(".."),
              components.first != "__MACOSX",
              !components.contains(where: { $0.hasPrefix("._") }),
              components.last != ".DS_Store" else { return nil }
        return components.joined(separator: "/")
    }

    private static let stampName = ".unfold-unpacked"
    private static let maxNesting = 3
}
