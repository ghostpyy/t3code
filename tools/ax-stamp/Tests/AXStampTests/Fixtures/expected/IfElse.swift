import SwiftUI

struct Gate: View {
    var flag: Bool
    var body: some View {
        if flag {
            Text("on").inspectable()
        } else {
            Text("off").inspectable()
        }
    }
}
