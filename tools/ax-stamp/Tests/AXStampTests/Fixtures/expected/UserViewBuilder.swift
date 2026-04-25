import SwiftUI

struct Settings: View {
    var body: some View {
        segmentedBar {
            Button("On") { }.inspectable()
            Button("Off") { }.inspectable()
        }.inspectable()
    }

    private func segmentedBar<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 3) {
            content().inspectable()
        }
        .padding(3).inspectable()
    }
}
