import SwiftUI
import AppKit

/// An on-disk Markdown file opened in the folder browser.
///
/// Unlike the single-document window (which uses `DocumentGroup`/`FileDocument`
/// with its own autosave), the folder browser manages loose files directly:
/// this model loads the text from disk and writes edits back with a short
/// debounce. If a write fails the edits are kept in memory and an alert is
/// surfaced so nothing is silently lost.
@Observable
final class LooseFile {
    let url: URL

    /// The editable text. Mutating it schedules a debounced save to disk.
    /// `loadedFromDisk` guards the initial load so reading the file doesn't
    /// immediately trigger a redundant write-back.
    var text: String {
        didSet {
            guard loadedFromDisk, text != oldValue else { return }
            scheduleSave()
        }
    }

    private var loadedFromDisk = false
    private var saveWorkItem: DispatchWorkItem?
    private let saveDebounce: TimeInterval = 0.75

    init(url: URL) {
        self.url = url
        self.text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        loadedFromDisk = true
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.writeToDisk() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDebounce, execute: item)
    }

    /// Write any pending edits immediately. Called before switching away from a
    /// file so no in-flight debounce is lost.
    func flush() {
        guard saveWorkItem != nil else { return }
        saveWorkItem?.cancel()
        saveWorkItem = nil
        writeToDisk()
    }

    private func writeToDisk() {
        saveWorkItem = nil
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t save “\(url.lastPathComponent)”"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
            // Edits remain in `text`; a later change will retry the save.
        }
    }
}
