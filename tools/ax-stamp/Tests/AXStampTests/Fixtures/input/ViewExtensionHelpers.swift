import SwiftUI

// Helpers that live in `extension View { ... }` are modifier adapters and
// must never be stamped — stamping their terminal expression creates ghost
// anchors pinned to the helper's file/line that surface on every caller.
extension View {
    func stale() -> some View {
        self.padding().inspectable()
    }

    func fresh() -> some View {
        self.background(Color.red)
    }
}

struct Host: View {
    var body: some View {
        Text("hi").stale().fresh()
    }
}
