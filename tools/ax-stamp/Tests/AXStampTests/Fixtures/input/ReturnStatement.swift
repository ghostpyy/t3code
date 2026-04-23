import SwiftUI

struct Explicit: View {
    let show: Bool
    var body: some View {
        let base = Text("hi")
        return base.opacity(show ? 1 : 0)
    }
}
