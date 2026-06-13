import SwiftUI
import AppKit

/// A monospaced source editor backed by `NSTextView`.
///
/// We use `NSTextView` rather than SwiftUI's `TextEditor` because, on macOS,
/// `TextEditor` applies automatic quote/dash/text substitution (curly quotes,
/// em-dashes) that silently corrupts Markdown and code, with no way to disable
/// it from SwiftUI. This wrapper turns all substitutions off, soft-wraps to the
/// pane width, follows the preview's appearance toggle, and relies on the text
/// view's own (properly coalesced) undo.
struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    let navigationState: NavigationState

    static let editorFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    static func highlight(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        MarkdownSyntaxHighlighter.apply(to: storage, baseFont: editorFont)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder

        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator

        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = Self.editorFont
        textView.textContainerInset = NSSize(width: 8, height: 12)

        // `scrollableTextView()` already soft-wraps to the view width with no
        // horizontal scroller, which is what we want.

        textView.string = text
        Self.highlight(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Keep the coordinator's binding/state references current.
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Adopt external changes to the binding (e.g. a document revert) without
        // disturbing the caret. During normal typing the strings already match,
        // so we skip this and avoid clearing the undo stack.
        if textView.string != text {
            let sel = textView.selectedRange()
            textView.string = text
            let loc = min(sel.location, (text as NSString).length)
            textView.setSelectedRange(NSRange(location: loc, length: 0))
            Self.highlight(textView)
        }

        textView.appearance = navigationState.appearanceMode.nsAppearance

        // Focus the editor once when entering edit mode.
        if navigationState.isEditing {
            if !context.coordinator.hasFocused {
                context.coordinator.hasFocused = true
                DispatchQueue.main.async {
                    textView.window?.makeFirstResponder(textView)
                }
            }
        } else {
            context.coordinator.hasFocused = false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextView
        var hasFocused = false

        init(_ parent: MarkdownTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            MarkdownTextView.highlight(tv)
            syncCaret(tv)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            syncCaret(tv)
        }

        /// Map the caret to a 0-based source line and drive the preview sync.
        private func syncCaret(_ tv: NSTextView) {
            let ns = tv.string as NSString
            let caret = min(tv.selectedRange().location, ns.length)
            var line = 0
            for i in 0..<caret where ns.character(at: i) == 0x0A { line += 1 }
            parent.navigationState.coordinator?.syncToLine(line)
        }
    }
}
