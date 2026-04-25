import SwiftUI

struct Underliner: ViewModifier {
    func body(content: Content) -> some View {
        content
            .overlay(Rectangle().frame(height: 1), alignment: .bottom)
    }
}

struct Host: View {
    var body: some View {
        Text("x").modifier(Underliner())
    }
}
