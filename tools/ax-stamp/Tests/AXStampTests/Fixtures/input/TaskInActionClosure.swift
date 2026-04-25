import SwiftUI

struct LoaderView: View {
    @State private var showSheet = false
    @State private var loaded = false

    var body: some View {
        Text("ready")
            .onAppear {
                if shouldOpen {
                    Task { @MainActor in
                        showSheet = true
                    }
                }
            }
            .onChange(of: loaded) { _, value in
                Task { await refresh(value) }
            }
            .task {
                await load()
                Task.detached { await audit() }
            }
    }

    private var shouldOpen: Bool { true }
    private func refresh(_ flag: Bool) async { }
    private func load() async { }
    private func audit() async { }
}
