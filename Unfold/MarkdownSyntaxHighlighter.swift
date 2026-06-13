import AppKit

/// Lightweight, regex-based Markdown syntax highlighting for the source editor.
///
/// Applies foreground colors and bold/italic fonts to an `NSTextStorage`. Uses
/// dynamic system colors (`labelColor`, `secondaryLabelColor`, …) so the
/// highlighting adapts to light/dark automatically without re-running.
///
/// Highlighting can be scoped to a sub-range so edits only re-style the affected
/// region rather than the whole document — see `rangeToRehighlight(forEdited:in:)`.
enum MarkdownSyntaxHighlighter {

    /// Highlight the whole text storage.
    static func apply(to storage: NSTextStorage, baseFont: NSFont) {
        let length = (storage.string as NSString).length
        apply(to: storage, baseFont: baseFont, in: NSRange(location: 0, length: length))
    }

    /// Highlight only `range` (which must be snapped to line boundaries — use
    /// `rangeToRehighlight(forEdited:in:)`). Applies attributes directly, so it
    /// is safe to call from `NSTextStorageDelegate.textStorage(_:didProcessEditing:…)`.
    static func apply(to storage: NSTextStorage, baseFont: NSFont, in range: NSRange) {
        guard range.length > 0 else { return }
        let ns = storage.string as NSString

        // Reset the range to the base style first.
        storage.setAttributes([.font: baseFont, .foregroundColor: NSColor.labelColor], range: range)

        let boldFont = font(baseFont, traits: .bold)
        let italicFont = font(baseFont, traits: .italic)

        let punctuation = NSColor.tertiaryLabelColor
        let codeColor = NSColor.systemPink
        let fenceColor = NSColor.systemTeal

        // Emphasis: bold **..** / __..__ then italic *..* / _.._
        enumerate(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, in: ns, range: range) { m in
            storage.addAttribute(.font, value: boldFont, range: m.range)
            tintMarkers(storage, m.range, length: 2, color: punctuation)
        }
        enumerate(#"(?<![\*_])([\*_])(?![\*_])(?=\S)(.+?)(?<=\S)\1(?![\*_])"#, in: ns, range: range) { m in
            storage.addAttribute(.font, value: italicFont, range: m.range)
            tintMarkers(storage, m.range, length: 1, color: punctuation)
        }

        // Inline code `..`
        enumerate(#"`[^`\n]+`"#, in: ns, range: range) { m in
            storage.addAttribute(.foregroundColor, value: codeColor, range: m.range)
        }

        // Links [text](url)
        enumerate(#"\[([^\]\n]+)\]\(([^)\n]+)\)"#, in: ns, range: range) { m in
            storage.addAttribute(.foregroundColor, value: punctuation, range: m.range)
            if m.numberOfRanges > 1 {
                storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: m.range(at: 1))
            }
            if m.numberOfRanges > 2 {
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: m.range(at: 2))
            }
        }

        // List markers (-, *, +, 1., 1))
        enumerate(#"(?m)^[ \t]*([-*+]|\d+[.)])[ \t]+"#, in: ns, range: range) { m in
            if m.numberOfRanges > 1 {
                storage.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: m.range(at: 1))
            }
        }

        // Blockquotes
        enumerate(#"(?m)^[ \t]*>.*$"#, in: ns, range: range) { m in
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: m.range)
        }

        // Headings (# .. ######) — whole line bold and yellow, including the #'s.
        enumerate(#"(?m)^[ \t]{0,3}(#{1,6})[ \t]+.*$"#, in: ns, range: range) { m in
            storage.addAttribute(.font, value: boldFont, range: m.range)
            storage.addAttribute(.foregroundColor, value: NSColor.systemYellow, range: m.range)
        }

        // Fenced code blocks — applied last so they override any inline styling
        // that happens to fall inside the block.
        enumerate(#"(?m)^[ \t]*```[\s\S]*?^[ \t]*```[ \t]*$"#, in: ns, range: range) { m in
            storage.addAttribute(.font, value: baseFont, range: m.range)
            storage.addAttribute(.foregroundColor, value: fenceColor, range: m.range)
        }
    }

    /// The range that must be re-highlighted after an edit: the enclosing
    /// paragraph(s), unioned with any fenced code block the edit touches (so a
    /// block whose fences sit outside the edited paragraph is still re-styled
    /// correctly). Snapped to line boundaries so `^`/`$` anchors behave.
    static func rangeToRehighlight(forEdited editedRange: NSRange, in ns: NSString) -> NSRange {
        let length = ns.length
        let clampedLocation = min(editedRange.location, length)
        let clamped = NSRange(
            location: clampedLocation,
            length: min(editedRange.length, length - clampedLocation)
        )
        var range = ns.paragraphRange(for: clamped)

        if let re = try? NSRegularExpression(pattern: #"(?m)^[ \t]*```[\s\S]*?^[ \t]*```[ \t]*$"#) {
            re.enumerateMatches(in: ns as String, range: NSRange(location: 0, length: length)) { match, _, _ in
                guard let match else { return }
                if NSIntersectionRange(match.range, range).length > 0 {
                    range = NSUnionRange(range, match.range)
                }
            }
        }
        return range
    }

    private static func tintMarkers(_ storage: NSTextStorage, _ range: NSRange, length: Int, color: NSColor) {
        guard range.length >= length * 2 else { return }
        storage.addAttribute(.foregroundColor, value: color,
                             range: NSRange(location: range.location, length: length))
        storage.addAttribute(.foregroundColor, value: color,
                             range: NSRange(location: range.location + range.length - length, length: length))
    }

    private static func enumerate(_ pattern: String, in ns: NSString, range: NSRange, _ body: (NSTextCheckingResult) -> Void) {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return }
        re.enumerateMatches(in: ns as String, range: range) { match, _, _ in
            if let match { body(match) }
        }
    }

    private static func font(_ base: NSFont, traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }
}
