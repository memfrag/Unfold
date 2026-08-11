import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Routes folders and zip archives opened via the Dock icon, Finder ("Open
/// With"), or the `open` command into folder-browser windows.
///
/// The single-document Markdown flow stays with `DocumentGroup`; only
/// directories and archives are intercepted here. Folder windows are hosted in
/// plain `NSWindow`s via `NSHostingController` rather than a
/// `WindowGroup(for:URL)` scene — this avoids SwiftUI's launch-time
/// window-restoration quirks (stray blank windows) and gives us direct,
/// deterministic control over when a window appears and which folder it shows.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Retains open folder windows, keyed by what the reader opened — the folder
    /// or the archive, never the unpacked copy — so a second drop of the same
    /// thing re-focuses its window instead of duplicating it.
    private var browserWindows: [URL: NSWindow] = [:]

    /// Archives being unpacked, so a second drop while the first is still
    /// running doesn't start over and open a second window for it.
    private var unpacking: Set<URL> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.global(qos: .utility).async { ZipFolder.pruneCache() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            open(url.standardizedFileURL)
        }
    }

    /// Send a dropped/opened item to the window that suits it.
    private func open(_ url: URL) {
        if isDirectory(url) {
            openFolderWindow(url)
        } else if isArchive(url) {
            openArchiveWindow(url)
        }
    }

    /// Backs the File ▸ Open Folder… command.
    ///
    /// This is a command of its own rather than folded into File ▸ Open because
    /// `Open…` belongs to `DocumentGroup`: its panel offers only
    /// `UnfoldDocument.readableContentTypes`, and SwiftUI publishes no command
    /// placement for it (`.newItem` covers `New` alone — verified by dumping the
    /// live File menu). Widening that panel would mean retargeting SwiftUI's own
    /// `NSMenuItem`, which the menu rebuild driven by `isEditing` could undo.
    ///
    /// Adding `public.folder` to `readableContentTypes` is not an option either:
    /// the chosen directory would be handed to `UnfoldDocument.init(configuration:)`,
    /// where `regularFileContents` is nil for a directory, so the open fails.
    func showOpenFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        panel.message = "Choose a folder or zip archive to browse."

        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            open(url.standardizedFileURL)
        }
    }

    func openFolderWindow(_ url: URL) {
        showBrowser(root: url, openedFrom: url, titleSource: url, isReadOnly: false)
    }

    /// Browse a zip archive by unpacking it and showing the result.
    ///
    /// Unpacking reads and rewrites every entry, so it happens off the main
    /// thread — a large archive would otherwise freeze the app for as long as it
    /// took, before any window had appeared to explain why.
    func openArchiveWindow(_ zipURL: URL) {
        if let existing = browserWindows[zipURL] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        guard !unpacking.contains(zipURL) else { return }
        unpacking.insert(zipURL)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try ZipFolder.unpack(zipURL) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.unpacking.remove(zipURL)
                switch result {
                case .success(let unpacked):
                    // The window is keyed by the archive — that is what the
                    // reader opened — but named by `ZipFolder`, which knows
                    // whether the archive's own name is worth showing.
                    self.showBrowser(
                        root: unpacked.root,
                        openedFrom: zipURL,
                        titleSource: unpacked.titleSource,
                        isReadOnly: true
                    )
                case .failure(let error):
                    self.presentUnpackFailure(zipURL, error)
                }
            }
        }
    }

    /// Put a folder-browser window on screen for `root`, remembered under the
    /// URL the reader actually opened (`openedFrom`).
    private func showBrowser(root: URL, openedFrom: URL, titleSource: URL, isReadOnly: Bool) {
        if let existing = browserWindows[openedFrom] {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        // Decided here, once per window: the title needs the answer too, and the
        // check reads directories, which shouldn't happen on every view update.
        let hidesNotionIDs = NotionExport.looksLikeExport(root)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = hidesNotionIDs
            ? NotionExport.displayName(for: titleSource, isDirectory: true)
            : titleSource.lastPathComponent
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 700, height: 480)
        window.contentViewController = NSHostingController(
            rootView: FolderBrowserView(
                root: root,
                hidesNotionIDs: hidesNotionIDs,
                isReadOnly: isReadOnly
            )
        )
        window.setFrameAutosaveName("FolderBrowser:\(openedFrom.path)")
        window.center()
        window.delegate = self

        browserWindows[openedFrom] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentUnpackFailure(_ zipURL: URL, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t open “\(zipURL.lastPathComponent)”"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func isArchive(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .zip) == true
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        browserWindows = browserWindows.filter { $0.value != window }
    }
}
