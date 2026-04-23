import SwiftUI

struct Padded: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("A")
            Text("B")
        }
        .padding()
        .background(.regularMaterial).inspectable()
    }
}
