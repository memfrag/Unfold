import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Whether Edit opens Unfold's own source editor or hands the file to another
/// application, and which one.
///
/// Editing externally needs no syncing machinery of its own: `FileWatcher` and
/// the adoption logic in `ContentView` / `LooseFile` already pick up writes from
/// other programs and re-render the preview. All that is needed here is to get
/// the file on disk and launched.
///
/// Stored in `UserDefaults` as a plain path — the app is not sandboxed (see
/// `Unfold.entitlements`), so there is no need for a security-scoped bookmark.
@Observable
final class ExternalEditor {
    static let shared = ExternalEditor()

    enum Mode: String, CaseIterable, Identifiable {
        case builtIn, external

        var id: String { rawValue }

        var label: String {
            switch self {
            case .builtIn:  "Built-in editor"
            case .external: "External application"
            }
        }
    }

    private enum Key {
        static let mode = "editorMode"
        static let applicationPath = "externalEditorApplicationPath"
    }

    var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Key.mode) }
    }

    /// nil until an application has been chosen.
    var applicationURL: URL? {
        didSet { UserDefaults.standard.set(applicationURL?.path, forKey: Key.applicationPath) }
    }

    private init() {
        let defaults = UserDefaults.standard
        mode = defaults.string(forKey: Key.mode).flatMap(Mode.init(rawValue:)) ?? .builtIn
        applicationURL = defaults.string(forKey: Key.applicationPath).map { URL(fileURLWithPath: $0) }
    }

    /// External editing is on only once an application has actually been picked;
    /// the mode alone would otherwise leave Edit doing nothing at all.
    var isEnabled: Bool {
        mode == .external && applicationURL != nil
    }

    /// The app's own display name. `FileManager.displayName(atPath:)` is not used
    /// here — it keeps the ".app" extension when the user has "show all filename
    /// extensions" on, which would read as "Edit in TextEdit.app".
    var applicationName: String? {
        guard let applicationURL else { return nil }
        let info = Bundle(url: applicationURL)?.infoDictionary
        return info?["CFBundleDisplayName"] as? String
            ?? info?["CFBundleName"] as? String
            ?? applicationURL.deletingPathExtension().lastPathComponent
    }

    func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        panel.message = "Choose the application to edit Markdown files in."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        applicationURL = url
    }

    /// Hand the file to the configured application. The caller is responsible for
    /// flushing unsaved edits first — the editor reads from disk.
    func open(_ fileURL: URL) {
        guard let applicationURL else { return }
        NSWorkspace.shared.open(
            [fileURL],
            withApplicationAt: applicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}
