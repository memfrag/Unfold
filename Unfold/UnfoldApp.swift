//
//  
//

import SwiftUI

@main
struct UnfoldApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: UnfoldDocument()) { file in
            ContentView(document: file.$document)
        }
    }
}
