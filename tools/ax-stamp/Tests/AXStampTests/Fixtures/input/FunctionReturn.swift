import SwiftUI

struct Panel: View {
    var body: some View {
        row(title: "Settings")
    }

    private func row(title: String) -> some View {
        HStack {
            Text(title)
            Spacer()
        }
    }
}

extension View {
    func inspectable() -> some View {
        accessibilityIdentifier("x")
    }
}
