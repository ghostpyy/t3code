import SwiftUI

private struct SelectionRow<T: Hashable>: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Text(title).inspectable()
        }.inspectable()
    }
}

struct PickerScreen: View {
    @State private var selection: Int = 0

    var body: some View {
        VStack {
            SelectionRow<Int>(
                title: "Option A",
                isSelected: selection == 0
            ) {
                withAnimation {
                    selection = 0
                }
            }.inspectable()
            SelectionRow<Int>(
                title: "Option B",
                isSelected: selection == 1
            ) {
                selection = 1
            }.inspectable()
        }.inspectable()
    }
}
