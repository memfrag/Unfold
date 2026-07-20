import SwiftUI

struct ContentView: View {
    @Binding var document: UnfoldDocument
    let fileURL: URL?
    @State private var navigationState = NavigationState()
    @State private var showInspector = false
    @State private var watcher: FileWatcher?

    /// The file's contents as of the last time we read them. Anything in
    /// `document.text` that diverges from this is unsaved local work — the
    /// document's autosave timing isn't observable, so that's the only signal
    /// we have that an external change would clobber something.
    @State private var lastKnownDiskText: String?

    var body: some View {
        HSplitView {
            if navigationState.isEditing {
                MarkdownTextView(
                    text: $document.text,
                    navigationState: navigationState
                )
                .frame(minWidth: 250, idealWidth: 600, maxWidth: .infinity)
            }

            MarkdownWebView(
                markdown: document.text,
                fileURL: fileURL,
                navigationState: navigationState
            )
            .frame(minWidth: 320, idealWidth: 600, maxWidth: .infinity)
            .id("preview")
        }
        .inspector(isPresented: $showInspector) {
            TOCSidebar(navigationState: navigationState)
                .inspectorColumnWidth(min: 150, ideal: 220, max: 400)
        }
        .focusedSceneValue(\.navigationState, navigationState)
        .onChange(of: navigationState.isEditing) { _, editing in
            navigationState.coordinator?.adjustWindow(forEditing: editing)
        }
        .onAppear(perform: startWatching)
        .onChange(of: fileURL) { _, _ in startWatching() }
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
                    navigationState.isEditing.toggle()
                } label: {
                    Image(systemName: navigationState.isEditing ? "pencil.circle.fill" : "pencil")
                }
                .help(navigationState.isEditing ? "Done Editing" : "Edit")
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .primaryAction) {
                Button {
                    navigationState.reload()
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

    // MARK: - Staying in step with the file on disk

    private func startWatching() {
        navigationState.reloadFromDisk = { reloadFromDisk() }
        guard let fileURL else {
            watcher = nil
            return
        }
        lastKnownDiskText = document.text
        watcher = FileWatcher(url: fileURL) { adoptExternalChanges() }
    }

    /// Adopt an external edit, unless the document has unsaved changes of its
    /// own — those win, and the autosave that follows puts disk back in step.
    private func adoptExternalChanges() {
        guard let fileURL,
              let disk = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        defer { lastKnownDiskText = disk }
        guard disk != document.text, document.text == lastKnownDiskText else { return }
        document.text = disk
        navigationState.coordinator?.render(markdown: disk)
    }

    /// Re-read the file for an explicit Reload, returning the text to render.
    ///
    /// Unlike the folder browser's `LooseFile`, there's no way to force the
    /// document's autosave from here, so a dirty document keeps its own text
    /// rather than risk discarding unsaved work — Reload then just re-renders.
    private func reloadFromDisk() -> String {
        guard let fileURL,
              let disk = try? String(contentsOf: fileURL, encoding: .utf8),
              document.text == lastKnownDiskText else { return document.text }
        lastKnownDiskText = disk
        if disk != document.text {
            document.text = disk
        }
        return disk
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
