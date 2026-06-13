import SwiftUI
import UniformTypeIdentifiers

nonisolated struct UnfoldDocument: FileDocument {
    var text: String

    init(text: String = "") {
        self.text = text
    }

    static var readableContentTypes: [UTType] {
        [UTType("net.daringfireball.markdown")!]
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let string = String(data: data, encoding: .utf8)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = string
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // Write the text verbatim as UTF-8 (no BOM, no newline normalization).
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
