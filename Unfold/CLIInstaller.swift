import AppKit

enum CLIInstaller {
    static func install() {
        guard let source = Bundle.main.url(forResource: "unfold", withExtension: nil) else {
            let errorAlert = NSAlert()
            errorAlert.messageText = "Installation Failed"
            errorAlert.informativeText = "Could not find the command line tool in the app bundle."
            errorAlert.runModal()
            return
        }

        let command = "sudo cp '\(source.path)' /usr/local/bin/unfold && sudo chmod +x /usr/local/bin/unfold"

        let alert = NSAlert()
        alert.messageText = "Install Command Line Tool"
        alert.informativeText = "Run the following command in Terminal to install the \"unfold\" command:\n\n\(command)"
        alert.addButton(withTitle: "Copy to Clipboard")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
    }
}
