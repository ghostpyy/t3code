import SwiftUI

struct Panel: View {
    var body: some View {
        row(title: "Settings").inspectable()
    }

    private func row(title: String) -> some View {
        HStack {
            Text(title).inspectable()
            Spacer().inspectable()
        }.inspectable()
    }
}

extension View {
    func inspectable() -> some View {
        accessibilityIdentifier("x")
    }
}
