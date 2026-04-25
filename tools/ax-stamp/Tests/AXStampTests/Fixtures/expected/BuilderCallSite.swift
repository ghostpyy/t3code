import SwiftUI

struct Activity: View {
    var body: some View {
        statsGrid.inspectable()
    }

    private var statsGrid: some View {
        VStack {
            HStack {
                stat(value: "0m", label: "Reading time").inspectable()
                stat(value: "0", label: "Passages").inspectable()
            }.inspectable()
        }.inspectable()
    }

    private func stat(value: String, label: String) -> some View {
        VStack {
            Text(value).inspectable()
            Text(label).inspectable()
        }.inspectable()
    }
}
