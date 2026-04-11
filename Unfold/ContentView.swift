import SwiftUI

struct ContentView: View {
    let document: UnfoldDocument
    let fileURL: URL?
    @State private var navigationState = NavigationState()
    @State private var showInspector = false

    var body: some View {
        MarkdownWebView(
            markdown: document.text,
            fileURL: fileURL,
            navigationState: navigationState
        )
        .inspector(isPresented: $showInspector) {
            TOCSidebar(navigationState: navigationState)
                .inspectorColumnWidth(min: 150, ideal: 220, max: 400)
        }
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
            .sharedBackgroundVisibility(.hidden)

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
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .primaryAction) {
                Button {
                    showInspector.toggle()
                } label: {
                    Image(systemName: "list.bullet.indent")
                }
                .help(showInspector ? "Hide Table of Contents" : "Show Table of Contents")
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }
}

struct TOCSidebar: View {
    let navigationState: NavigationState

    var body: some View {
        List {
            ForEach(navigationState.headings) { item in
                TOCItemView(item: item, navigationState: navigationState)
            }
        }
        .listStyle(.sidebar)
    }
}

struct TOCItemView: View {
    @State var item: HeadingItem
    let navigationState: NavigationState

    var body: some View {
        if item.children.isEmpty {
            Button {
                navigationState.coordinator?.scrollToHeading(item.id)
            } label: {
                Text(item.text)
                    .font(fontForDepth(item.depth))
                    .foregroundStyle(
                        navigationState.activeHeadingSlug == item.id
                            ? Color.accentColor
                            : Color.primary
                    )
                    .fontWeight(
                        navigationState.activeHeadingSlug == item.id
                            ? .semibold
                            : .regular
                    )
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            DisclosureGroup(isExpanded: $item.isExpanded) {
                ForEach(item.children) { child in
                    TOCItemView(item: child, navigationState: navigationState)
                }
            } label: {
                Button {
                    navigationState.coordinator?.scrollToHeading(item.id)
                } label: {
                    Text(item.text)
                        .font(fontForDepth(item.depth))
                        .foregroundStyle(
                            navigationState.activeHeadingSlug == item.id
                                ? Color.accentColor
                                : Color.primary
                        )
                        .fontWeight(
                            navigationState.activeHeadingSlug == item.id
                                ? .semibold
                                : .regular
                        )
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func fontForDepth(_ depth: Int) -> Font {
        switch depth {
        case 1: .body
        case 2: .callout
        default: .caption
        }
    }
}

extension FocusedValues {
    @Entry var navigationState: NavigationState? = nil
}
