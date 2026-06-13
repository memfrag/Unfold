import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ThemeSettingsView()
                .tabItem { Label("Theme", systemImage: "paintpalette") }
        }
        .frame(width: 360)
    }
}

struct ThemeSettingsView: View {
    @Bindable private var theme = EditorTheme.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Editor syntax highlighting colors")
                .font(.headline)
                .padding(.bottom, 12)

            ForEach(EditorTheme.Element.allCases) { element in
                HStack {
                    ColorPicker(element.label, selection: theme.binding(for: element), supportsOpacity: true)
                    Spacer()
                }
                .padding(.vertical, 3)
            }

            Divider()
                .padding(.vertical, 12)

            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    theme.resetToDefaults()
                }
                .disabled(!theme.hasCustomColors)
            }
        }
        .padding(20)
    }
}
