import AppKit
import SwiftUI

/// Routes folders opened via the Dock icon, Finder ("Open With"), or the `open`
/// command into folder-browser windows.
///
/// The single-document Markdown flow stays with `DocumentGroup`; only
/// directories are intercepted here. Folder windows are hosted in plain
/// `NSWindow`s via `NSHostingController` rather than a `WindowGroup(for:URL)`
/// scene — this avoids SwiftUI's launch-time window-restoration quirks (stray
/// blank windows) and gives us direct, deterministic control over when a window
/// appears and which folder it shows.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Retains open folder windows, keyed by folder URL, so a second drop of the
    /// same folder re-focuses the existing window instead of duplicating it.
    private var browserWindows: [URL: NSWindow] = [:]

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where isDirectory(url) {
            openFolderWindow(url.standardizedFileURL)
        }
    }

    private func openFolderWindow(_ url: URL) {
        if let existing = browserWindows[url] {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = url.lastPathComponent
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 700, height: 480)
        window.contentViewController = NSHostingController(rootView: FolderBrowserView(root: url))
        window.setFrameAutosaveName("FolderBrowser:\(url.path)")
        window.center()
        window.delegate = self

        browserWindows[url] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        browserWindows = browserWindows.filter { $0.value != window }
    }
}
