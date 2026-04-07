import SwiftUI
import AttributionsUI
import Sparkle

@main
struct UnfoldApp: App {
    @FocusedValue(\.navigationState) private var navigationState
    @Environment(\.openWindow) private var openWindow

    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        DocumentGroup(viewing: UnfoldDocument.self) { file in
            ContentView(document: file.document, fileURL: file.fileURL)
                .frame(minWidth: 300, minHeight: 300)
        }
        .defaultSize(width: 600, height: 700)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updaterController.updater.checkForUpdates()
                }
                .disabled(!updaterController.updater.canCheckForUpdates)

                Divider()

                Button("Attributions") {
                    openWindow(id: AttributionsWindow.windowID)
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

        AttributionsWindow(
            "Unfold uses the following third-party software:",
            ("marked", .mit(year: "2018+", holder: "MarkedJS, Christopher Jeffrey")),
            ("highlight.js", .bsd3Clause(year: "2006-2024", holder: "Ivan Sagalaev")),
            ("Sparkle", .mit(year: "2006-2017", holder: "Andy Matuschak et al."))
        )
    }
}
