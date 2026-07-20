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
                Button(navigationState?.isEditing == true ? "Hide Editor" : "Show Editor") {
                    navigationState?.isEditing.toggle()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(navigationState == nil)
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
