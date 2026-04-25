import SwiftUI

struct Surface: View {
    @State private var count = 0

    var body: some View {
        Text("Tap")
            .onAppear { count += 1 }
            .onTapGesture { count += 1 }
            .task { await load() }
            .onChange(of: count) { _, _ in }
            .refreshable { await refresh() }
    }

    private func load() async { }
    private func refresh() async { }
}
