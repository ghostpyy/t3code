import SwiftUI

struct Activity: View {
    var body: some View {
        statsGrid
    }

    private var statsGrid: some View {
        VStack {
            HStack {
                stat(value: "0m", label: "Reading time")
                stat(value: "0", label: "Passages")
            }
        }
    }

    private func stat(value: String, label: String) -> some View {
        VStack {
            Text(value)
            Text(label)
        }
    }
}
