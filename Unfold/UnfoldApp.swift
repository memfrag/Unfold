import SwiftUI
import Sparkle

@main
struct UnfoldApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @FocusedValue(\.navigationState) private var navigationState

    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    /// "Show/Hide Editor" is a toggle only for the built-in editor; with an
    /// external one configured the command launches it instead.
    ///
    /// Known wrinkle: changing the preference does not by itself re-evaluate this
    /// menu title (holding `ExternalEditor.shared` in `@State` was tried and made
    /// no difference), so the item can read "Show Editor" until the commands are
    /// rebuilt — which the `@FocusedValue` below does on the next focus change.
    /// Only the label lags; `edit()` reads the preference when invoked, so the
    /// behaviour is always right. The toolbar buttons, being views, update
    /// immediately.
    private var editCommandTitle: String {
        if ExternalEditor.shared.isEnabled {
            return "Edit in \(ExternalEditor.shared.applicationName ?? "External Editor")"
        }
        return navigationState?.isEditing == true ? "Hide Editor" : "Show Editor"
    }

    var body: some Scene {
        DocumentGroup(newDocument: UnfoldDocument()) { file in
            ContentView(document: file.$document, fileURL: file.fileURL)
                .frame(minWidth: 300, minHeight: 300)
        }
        .defaultSize(width: 600, height: 700)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Folder...") {
                    appDelegate.showOpenFolderPanel()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }

            CommandGroup(after: .toolbar) {
                Button(editCommandTitle) {
                    navigationState?.edit()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(navigationState == nil || navigationState?.canEdit == false)
            }

            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updaterController.updater.checkForUpdates()
                }
                .disabled(!updaterController.updater.canCheckForUpdates)

                Divider()

                Button("Install Command Line Tool...") {
                    CLIInstaller.install()
                }
            }
            CommandGroup(after: .saveItem) {
                Button("Export PDF...") {
                    navigationState?.coordinator?.exportPDF()
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(navigationState == nil)
            }
            CommandGroup(replacing: .printItem) {
                Button("Print...") {
                    navigationState?.coordinator?.printDocument()
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(navigationState == nil)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
