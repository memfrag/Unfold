import SwiftUI

struct ContentView: View {
    let document: UnfoldDocument
    let fileURL: URL?
    @State private var navigationState = NavigationState()

    var body: some View {
        MarkdownWebView(
            markdown: document.text,
            fileURL: fileURL,
            navigationState: navigationState
        )
        .focusedSceneValue(\.navigationState, navigationState)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    navigationState.coordinator?.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!navigationState.canGoBack)
                .keyboardShortcut("[", modifiers: .command)

                Button {
                    navigationState.coordinator?.goForward()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!navigationState.canGoForward)
                .keyboardShortcut("]", modifiers: .command)
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    navigationState.coordinator?.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    let modes = AppearanceMode.allCases
                    let currentIndex = modes.firstIndex(of: navigationState.appearanceMode) ?? 0
                    let nextIndex = (currentIndex + 1) % modes.count
                    navigationState.appearanceMode = modes[nextIndex]
                    navigationState.coordinator?.setAppearance(modes[nextIndex])
                } label: {
                    Image(systemName: navigationState.appearanceMode.icon)
                }
                .help("Appearance: \(navigationState.appearanceMode.label)")
            }
        }
    }
}

extension FocusedValues {
    @Entry var navigationState: NavigationState? = nil
}
