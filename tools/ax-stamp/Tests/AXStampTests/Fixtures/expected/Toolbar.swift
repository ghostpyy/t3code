import SwiftUI

struct Editor: View {
    var body: some View {
        NavigationStack {
            Text("body")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Done") { }.inspectable()
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { }.inspectable()
                    }
                }.inspectable()
        }.inspectable()
    }
}
