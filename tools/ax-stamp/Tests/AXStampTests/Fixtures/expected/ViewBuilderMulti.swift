import SwiftUI

struct Row: View {
    @ViewBuilder var body: some View {
        Text("one").inspectable()
        Text("two").inspectable()
        Text("three").inspectable()
    }
}
