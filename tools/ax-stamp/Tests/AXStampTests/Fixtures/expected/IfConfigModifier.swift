import SwiftUI

struct Panel: View {
    var body: some View {
        Text("Debug")
            #if DEBUG
            .border(.red)
            #endif
    }
}
