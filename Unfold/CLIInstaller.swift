import AppKit

enum CLIInstaller {
    static func install() {
        guard let source = Bundle.main.url(forResource: "unfold", withExtension: nil) else {
            showAlert(
                title: "Installation Failed",
                message: "Could not find the command line tool in the app bundle."
            )
            return
        }

        let destination = "/usr/local/bin/unfold"
        let script = """
            do shell script "cp \(source.path) \(destination) && chmod +x \(destination)" \
            with administrator privileges
            """

        var error: NSDictionary?
        let appleScript = NSAppleScript(source: script)
        appleScript?.executeAndReturnError(&error)

        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            if !message.contains("User canceled") {
                showAlert(title: "Installation Failed", message: message)
            }
        } else {
            showAlert(
                title: "Installation Successful",
                message: "The \"unfold\" command has been installed to \(destination)."
            )
        }
    }

    private static func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
