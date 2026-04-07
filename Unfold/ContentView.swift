//
//  
//

import SwiftUI

struct ContentView: View {
    @Binding var document: UnfoldDocument

    var body: some View {
        TextEditor(text: $document.text)
    }
}

#Preview {
    ContentView(document: .constant(UnfoldDocument()))
}
