import SwiftUI

struct ButtonExample: View {
    @State private var pressed = false

    var body: some View {
        Button {
            pressed.toggle()
        } label: {
            Image(systemName: "doc.on.doc").inspectable()
        }.inspectable()
    }
}

struct ButtonWithTitle: View {
    @State private var counter = 0

    var body: some View {
        Button("Tap") {
            counter += 1
        }.inspectable()
    }
}

struct ButtonExplicitAction: View {
    @State private var fired = false

    var body: some View {
        Button(action: { fired.toggle() }) {
            Image(systemName: "star").inspectable()
        }.inspectable()
    }
}
