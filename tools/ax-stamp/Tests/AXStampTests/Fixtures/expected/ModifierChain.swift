import SwiftUI

struct Padded: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("A").inspectable()
            Text("B").inspectable()
        }
        .padding()
        .background(.regularMaterial).inspectable()
    }
}
