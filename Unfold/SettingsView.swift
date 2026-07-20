import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            EditingSettingsView()
                .tabItem { Label("Editing", systemImage: "square.and.pencil") }

            ThemeSettingsView()
                .tabItem { Label("Theme", systemImage: "paintpalette") }
        }
        .frame(width: 360)
    }
}

struct EditingSettingsView: View {
    @Bindable private var editor = ExternalEditor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit with")
                .font(.headline)
                .padding(.bottom, 12)

            Picker("", selection: $editor.mode) {
                ForEach(ExternalEditor.Mode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            HStack {
                Text(editor.applicationName ?? "No application chosen")
                    .foregroundStyle(editor.applicationName == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button("Choose...") {
                    editor.chooseApplication()
                }
            }
            .padding(.leading, 20)
            .padding(.top, 4)
            .disabled(editor.mode != .external)

            Text("The preview keeps updating as the external editor saves. "
                 + "Unfold writes out any unsaved changes before handing the file over.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
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
