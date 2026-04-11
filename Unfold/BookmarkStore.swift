import Foundation

enum BookmarkStore {
    private static let key = "directoryBookmarks"

    static func saveBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            var bookmarks = load()
            bookmarks[url.path] = data
            UserDefaults.standard.set(bookmarks, forKey: key)
        } catch {
            // Silently fail — next time we'll just show the panel again
        }
    }

    static func resolveBookmark(for path: String) -> URL? {
        var bookmarks = load()
        guard let data = bookmarks[path] else { return nil }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                // Re-save the bookmark with fresh data
                bookmarks.removeValue(forKey: path)
                UserDefaults.standard.set(bookmarks, forKey: key)
                saveBookmark(for: url)
            }

            guard url.startAccessingSecurityScopedResource() else {
                return nil
            }

            return url
        } catch {
            // Bookmark is invalid — remove it
            bookmarks.removeValue(forKey: path)
            UserDefaults.standard.set(bookmarks, forKey: key)
            return nil
        }
    }

    private static func load() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
    }
}
