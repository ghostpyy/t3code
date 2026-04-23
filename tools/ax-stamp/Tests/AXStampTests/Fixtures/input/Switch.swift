import SwiftUI

enum State { case a, b }

struct Router: View {
    let state: State
    var body: some View {
        switch state {
        case .a:
            Text("a")
        case .b:
            Text("b").bold()
        }
    }
}
