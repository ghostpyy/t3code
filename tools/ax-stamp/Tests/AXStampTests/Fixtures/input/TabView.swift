import SwiftUI

struct Root: View {
    enum AppTab: Hashable { case library, settings }
    @State private var selection: AppTab = .library

    var body: some View {
        TabView(selection: $selection) {
            Tab("Library", systemImage: "book.closed.fill", value: .library) {
                Text("library content")
            }
            Tab("Settings", systemImage: "gearshape", value: .settings) {
                Text("settings content")
            }
        }
    }
}
