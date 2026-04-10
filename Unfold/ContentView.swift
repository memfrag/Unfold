import SwiftUI

struct ContentView: View {
    let document: UnfoldDocument
    let fileURL: URL?
    @State private var navigationState = NavigationState()
    @State private var showSidebar = false

    var body: some View {
        HSplitView {
            if showSidebar {
                TOCSidebar(navigationState: navigationState)
                    .frame(width: 220)
            }

            MarkdownWebView(
                markdown: document.text,
                fileURL: fileURL,
                navigationState: navigationState
            )
        }
        .focusedSceneValue(\.navigationState, navigationState)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation {
                        showSidebar.toggle()
                    }
                } label: {
                    Image(systemName: "list.bullet.indent")
                }
                .help(showSidebar ? "Hide Table of Contents" : "Show Table of Contents")
            }

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
