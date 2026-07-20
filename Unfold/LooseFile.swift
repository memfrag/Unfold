import SwiftUI
import AppKit

/// An on-disk Markdown file opened in the folder browser.
///
/// Unlike the single-document window (which uses `DocumentGroup`/`FileDocument`
/// with its own autosave), the folder browser manages loose files directly:
/// this model loads the text from disk and writes edits back with a short
/// debounce. If a write fails the edits are kept in memory and an alert is
/// surfaced so nothing is silently lost.
///
/// A `FileWatcher` keeps the in-memory text in step with external edits (another
/// editor, a `git checkout`, a generator script). Adoption never clobbers local
/// work: it's skipped while one of our own saves is still pending.
@Observable
final class LooseFile {
    let url: URL

    /// The editable text. Mutating it schedules a debounced save to disk.
    /// `loadedFromDisk` guards the initial load so reading the file doesn't
    /// immediately trigger a redundant write-back, and `isAdoptingFromDisk`
    /// does the same for text we just read back off disk.
    var text: String {
        didSet {
            guard loadedFromDisk, !isAdoptingFromDisk, text != oldValue else { return }
            scheduleSave()
        }
    }

    /// Called after external changes are adopted, with the new text, so the
    /// preview can re-render immediately instead of waiting out its debounce.
    var onExternalChange: ((String) -> Void)?

    private var loadedFromDisk = false
    private var isAdoptingFromDisk = false
    private var saveWorkItem: DispatchWorkItem?
    private var watcher: FileWatcher?
    private let saveDebounce: TimeInterval = 0.75

    init(url: URL) {
        self.url = url
        self.text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        loadedFromDisk = true
        watcher = FileWatcher(url: url) { [weak self] in
            self?.adoptExternalChanges()
        }
    }

    // MARK: - Reading

    /// Adopt an external change seen by the watcher.
    ///
    /// A pending save means we have edits of our own that haven't landed yet;
    /// adopting would throw them away, and the save is about to win regardless.
    /// Our own writes also wake the watcher, but they leave disk and `text`
    /// identical, so they fall out here as a no-op.
    private func adoptExternalChanges() {
        guard saveWorkItem == nil,
              let disk = try? String(contentsOf: url, encoding: .utf8),
              disk != text else { return }
        setTextWithoutSaving(disk)
        onExternalChange?(disk)
    }

    /// Re-read the file for an explicit Reload. Any pending edit of ours is
    /// flushed first, so a manual reload can never lose local work.
    /// Returns the text now in memory.
    @discardableResult
    func reloadFromDisk() -> String {
        flush()
        guard let disk = try? String(contentsOf: url, encoding: .utf8),
              disk != text else { return text }
        setTextWithoutSaving(disk)
        return text
    }

    private func setTextWithoutSaving(_ newText: String) {
        isAdoptingFromDisk = true
        text = newText
        isAdoptingFromDisk = false
    }

    // MARK: - Writing

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
