import SwiftUI

struct Panel: View {
    var body: some View {
        content
    }

    private var content: some View {
        HStack {
            Text("Title")
            Spacer()
        }
    }
}
