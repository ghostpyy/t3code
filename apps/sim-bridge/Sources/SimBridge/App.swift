import Foundation
import AppKit

@main
struct SimBridgeApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: Coordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let coord = try Coordinator(port: resolvedPort())
            self.coordinator = coord
            coord.run()
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            NSApp.terminate(nil)
        }
    }

    private func resolvedPort() -> UInt16 {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--port"),
              idx + 1 < args.count,
              let parsed = UInt16(args[idx + 1]) else {
            return 17323
        }
        return parsed
    }
}
