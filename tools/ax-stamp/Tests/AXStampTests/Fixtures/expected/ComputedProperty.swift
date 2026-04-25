import SwiftUI

struct Panel: View {
    var body: some View {
        content.inspectable()
    }

    private var content: some View {
        HStack {
            Text("Title").inspectable()
            Spacer().inspectable()
        }.inspectable()
    }
}
