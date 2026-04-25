import SwiftUI

// `ButtonStyle.makeBody(configuration:)` is a protocol-required factory:
// every styled call site routes through the same closure, so any
// `.inspectable()` here would emit the style's source line as the stamp ID
// across the whole app. Strip stale stamps; do not add new ones.
struct SpringPressStyle: ButtonStyle {
    var scale: CGFloat = 0.95
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .animation(.spring, value: configuration.isPressed)
    }
}

struct Host: View {
    var body: some View {
        Button("Tap") {}.buttonStyle(SpringPressStyle()).inspectable()
    }
}
