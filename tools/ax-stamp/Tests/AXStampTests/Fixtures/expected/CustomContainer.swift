import SwiftUI

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack {
            content.inspectable()
        }.inspectable()
    }
}

struct Page: View {
    var body: some View {
        Card {
            Text("Title").inspectable()
            Text("Subtitle").inspectable()
        }.inspectable()
    }
}
