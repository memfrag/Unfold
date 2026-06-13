import SwiftUI
import AppKit

extension Notification.Name {
    /// Posted when any editor syntax-highlighting color changes.
    static let editorThemeChanged = Notification.Name("editorThemeChanged")
}

/// User-configurable colors for the source editor's Markdown syntax
/// highlighting. Each element defaults to a dynamic system color (so it adapts
/// to light/dark); picking a custom color stores an override in `UserDefaults`.
@Observable
final class EditorTheme {
    static let shared = EditorTheme()

    enum Element: String, CaseIterable, Identifiable {
        case heading, bold, italic, inlineCode, codeBlock
        case link, linkURL, listMarker, blockquote, markers

        var id: String { rawValue }

        var label: String {
            switch self {
            case .heading:    "Heading"
            case .bold:       "Bold"
            case .italic:     "Italic"
            case .inlineCode: "Inline Code"
            case .codeBlock:  "Code Block"
            case .link:       "Link"
            case .linkURL:    "Link URL"
            case .listMarker: "List Marker"
            case .blockquote: "Blockquote"
            case .markers:    "Markers & Punctuation"
            }
        }

        /// The adaptive default used when the user hasn't picked a custom color.
        var defaultColor: NSColor {
            switch self {
            case .heading:    .systemPurple
            case .bold:       .labelColor
            case .italic:     .labelColor
            case .inlineCode: .systemPink
            case .codeBlock:  .systemTeal
            case .link:       .linkColor
            case .linkURL:    .secondaryLabelColor
            case .listMarker: .systemOrange
            case .blockquote: .secondaryLabelColor
            case .markers:    .tertiaryLabelColor
            }
        }
    }

    private var overrides: [Element: Color] = [:]

    private init() {
        for element in Element.allCases {
            if let hex = UserDefaults.standard.string(forKey: Self.key(element)),
               let color = Color(hexRGBA: hex) {
                overrides[element] = color
            }
        }
    }

    /// The `NSColor` to use when highlighting — the override if set, else the
    /// adaptive default.
    func nsColor(for element: Element) -> NSColor {
        if let color = overrides[element] { return NSColor(color) }
        return element.defaultColor
    }

    /// Whether the element currently has a custom (non-default) color.
    func isCustomized(_ element: Element) -> Bool { overrides[element] != nil }

    var hasCustomColors: Bool { !overrides.isEmpty }

    /// A SwiftUI binding for a color picker. Reads the override (or the resolved
    /// default), writes an override.
    func binding(for element: Element) -> Binding<Color> {
        Binding(
            get: { self.overrides[element] ?? Color(nsColor: element.defaultColor) },
            set: { self.setColor($0, for: element) }
        )
    }

    func setColor(_ color: Color, for element: Element) {
        overrides[element] = color
        UserDefaults.standard.set(NSColor(color).hexRGBA, forKey: Self.key(element))
        notifyChanged()
    }

    func resetToDefaults() {
        for element in Element.allCases {
            UserDefaults.standard.removeObject(forKey: Self.key(element))
        }
        overrides.removeAll()
        notifyChanged()
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .editorThemeChanged, object: nil)
    }

    private static func key(_ element: Element) -> String { "editorTheme.\(element.rawValue)" }
}

// MARK: - Color <-> hex (RRGGBBAA)

extension Color {
    init?(hexRGBA hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 8, let value = UInt32(s, radix: 16) else { return nil }
        let r = Double((value >> 24) & 0xff) / 255
        let g = Double((value >> 16) & 0xff) / 255
        let b = Double((value >> 8) & 0xff) / 255
        let a = Double(value & 0xff) / 255
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

extension NSColor {
    var hexRGBA: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = UInt32((c.redComponent * 255).rounded())
        let g = UInt32((c.greenComponent * 255).rounded())
        let b = UInt32((c.blueComponent * 255).rounded())
        let a = UInt32((c.alphaComponent * 255).rounded())
        return String(format: "%02X%02X%02X%02X", r, g, b, a)
    }
}
