import SwiftUI

struct Settings: View {
    var body: some View {
        segmentedBar {
            Button("On") { }
            Button("Off") { }
        }
    }

    private func segmentedBar<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 3) {
            content()
        }
        .padding(3)
    }
}
