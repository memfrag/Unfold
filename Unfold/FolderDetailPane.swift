import SwiftUI
import AppKit

/// The detail side of the folder browser: the Markdown viewer on top and, when
/// editing, the source editor below it.
///
/// Crucially this is a plain `VStack` with a hand-rolled draggable divider — NOT
/// a `VSplitView`. An `NSSplitView`-backed container nested inside the region
/// that the window's `.inspector()` insets produces unsatisfiable Auto Layout
/// constraints on macOS (the sidebar clips/collapses, the detail gets a phantom
/// fixed width). The `VStack` + divider is immune by construction. See
/// `Splitview-Inspector-Fix.md` for the full post-mortem.
struct FolderDetailPane: View {
    @Bindable var file: LooseFile
    let navigationState: NavigationState

    /// Editor height while editing. Clamped against the live pane height so the
    /// viewer always keeps a minimum — the one guarantee `VSplitView` gave for free.
    @State private var editorHeight: CGFloat = 260

    private let minViewerHeight: CGFloat = 160
    private let minEditorHeight: CGFloat = 120

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                MarkdownWebView(
                    markdown: file.text,
                    fileURL: file.url,
                    navigationState: navigationState
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(file.url)

                if navigationState.isEditing {
                    DragDivider(
                        editorHeight: $editorHeight,
                        minHeight: minEditorHeight,
                        maxHeight: max(minEditorHeight, proxy.size.height - minViewerHeight)
                    )

                    MarkdownTextView(
                        text: $file.text,
                        navigationState: navigationState
                    )
                    .frame(
                        height: clampedEditorHeight(paneHeight: proxy.size.height)
                    )
                    .id(file.url)
                }
            }
        }
    }

    /// Keep the editor within [min, paneHeight - minViewer] as the window resizes.
    private func clampedEditorHeight(paneHeight: CGFloat) -> CGFloat {
        let upperBound = max(minEditorHeight, paneHeight - minViewerHeight)
        return min(max(editorHeight, minEditorHeight), upperBound)
    }
}

/// A thin horizontal grabber that resizes the editor pane. Expands its hit area
/// beyond the visible hairline, shows the resize cursor on hover, and drags
/// anchored to the editor height at gesture start.
private struct DragDivider: View {
    @Binding var editorHeight: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat

    @State private var dragStartHeight: CGFloat?

    var body: some View {
        Divider()
            .overlay(Color.clear.frame(height: 8).contentShape(Rectangle()))
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let start = dragStartHeight ?? editorHeight
                        if dragStartHeight == nil { dragStartHeight = start }
                        // Divider sits above the editor: dragging up (negative
                        // translation) makes the editor taller.
                        let proposed = start - value.translation.height
                        editorHeight = min(max(proposed, minHeight), maxHeight)
                    }
                    .onEnded { _ in dragStartHeight = nil }
            )
    }
}
