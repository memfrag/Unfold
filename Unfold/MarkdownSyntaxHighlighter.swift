import AppKit

/// Lightweight, regex-based Markdown syntax highlighting for the source editor.
///
/// Applies foreground colors and bold/italic fonts to an `NSTextStorage`. Uses
/// dynamic system colors (`labelColor`, `secondaryLabelColor`, …) so the
/// highlighting adapts to light/dark automatically without re-running.
enum MarkdownSyntaxHighlighter {

    static func apply(to storage: NSTextStorage, baseFont: NSFont) {
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)

        storage.beginEditing()
        defer { storage.endEditing() }

        // Reset to the base style first.
        storage.setAttributes([.font: baseFont, .foregroundColor: NSColor.labelColor], range: full)

        let boldFont = font(baseFont, traits: .bold)
        let italicFont = font(baseFont, traits: .italic)

        let punctuation = NSColor.tertiaryLabelColor
        let codeColor = NSColor.systemPink
        let fenceColor = NSColor.systemTeal

        // Emphasis: bold **..** / __..__ then italic *..* / _.._
        enumerate(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, in: ns) { m in
            storage.addAttribute(.font, value: boldFont, range: m.range)
            tintMarkers(storage, m.range, length: 2, color: punctuation)
        }
        enumerate(#"(?<![\*_])([\*_])(?![\*_])(?=\S)(.+?)(?<=\S)\1(?![\*_])"#, in: ns) { m in
            storage.addAttribute(.font, value: italicFont, range: m.range)
            tintMarkers(storage, m.range, length: 1, color: punctuation)
        }

        // Inline code `..`
        enumerate(#"`[^`\n]+`"#, in: ns) { m in
            storage.addAttribute(.foregroundColor, value: codeColor, range: m.range)
        }

        // Links [text](url)
        enumerate(#"\[([^\]\n]+)\]\(([^)\n]+)\)"#, in: ns) { m in
            storage.addAttribute(.foregroundColor, value: punctuation, range: m.range)
            if m.numberOfRanges > 1 {
                storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: m.range(at: 1))
            }
            if m.numberOfRanges > 2 {
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: m.range(at: 2))
            }
        }

        // List markers (-, *, +, 1., 1))
        enumerate(#"(?m)^[ \t]*([-*+]|\d+[.)])[ \t]+"#, in: ns) { m in
            if m.numberOfRanges > 1 {
                storage.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: m.range(at: 1))
            }
        }

        // Blockquotes
        enumerate(#"(?m)^[ \t]*>.*$"#, in: ns) { m in
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: m.range)
        }

        // Headings (# .. ######) — whole line bold, the leading #'s dimmed.
        enumerate(#"(?m)^[ \t]{0,3}(#{1,6})[ \t]+.*$"#, in: ns) { m in
            storage.addAttribute(.font, value: boldFont, range: m.range)
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: m.range)
            if m.numberOfRanges > 1 {
                storage.addAttribute(.foregroundColor, value: punctuation, range: m.range(at: 1))
            }
        }

        // Fenced code blocks — applied last so they override any inline styling
        // that happens to fall inside the block.
        enumerate(#"(?m)^[ \t]*```[\s\S]*?^[ \t]*```[ \t]*$"#, in: ns) { m in
            storage.addAttribute(.font, value: baseFont, range: m.range)
            storage.addAttribute(.foregroundColor, value: fenceColor, range: m.range)
        }
    }

    private static func tintMarkers(_ storage: NSTextStorage, _ range: NSRange, length: Int, color: NSColor) {
        guard range.length >= length * 2 else { return }
        storage.addAttribute(.foregroundColor, value: color,
                             range: NSRange(location: range.location, length: length))
        storage.addAttribute(.foregroundColor, value: color,
                             range: NSRange(location: range.location + range.length - length, length: length))
    }

    private static func enumerate(_ pattern: String, in ns: NSString, _ body: (NSTextCheckingResult) -> Void) {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return }
        re.enumerateMatches(in: ns as String, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            if let match { body(match) }
        }
    }

    private static func font(_ base: NSFont, traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }
}
