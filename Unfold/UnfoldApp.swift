import SwiftUI
import AttributionsUI

@main
struct UnfoldApp: App {
    @FocusedValue(\.navigationState) private var navigationState
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        DocumentGroup(viewing: UnfoldDocument.self) { file in
            ContentView(document: file.document, fileURL: file.fileURL)
        }
        .commands {
            CommandGroup(after: .appInfo) {
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
            ("highlight.js", .bsd3Clause(year: "2006-2024", holder: "Ivan Sagalaev"))
        )
    }
}
