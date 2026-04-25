import SwiftUI

struct Splash: View {
    var body: some View {
        Canvas { ctx, size in
            let r = ring(50, 153)
            ctx.fill(r, with: .color(.green))
            ctx.fill(ring(153, 207), with: .color(.yellow))
        }
        .frame(width: 200, height: 200)
    }

    private func ring(_ a: Double, _ b: Double) -> Path { Path() }
}
