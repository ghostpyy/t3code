import SwiftUI

// Pre-existing `.inspectable()` calls inside a ViewModifier.body must be
// stripped on the next rewrite — self-healing across builds.
struct Panel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .background(Color.gray)
            .inspectable()
    }
}

struct Host: View {
    var body: some View {
        Text("x").modifier(Panel())
    }
}
