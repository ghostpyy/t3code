import SwiftUI

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack {
            content
        }
    }
}

struct Page: View {
    var body: some View {
        Card {
            Text("Title")
            Text("Subtitle")
        }
    }
}
