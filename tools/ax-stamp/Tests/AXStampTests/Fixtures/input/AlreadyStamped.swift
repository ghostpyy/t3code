import SwiftUI

struct HasInspect: View {
    var body: some View {
        Text("already").inspectable()
    }
}

struct HasAccessibility: View {
    var body: some View {
        Text("already").accessibilityIdentifier("custom")
    }
}

struct HasID: View {
    var body: some View {
        Text("pinned").id("x")
    }
}
