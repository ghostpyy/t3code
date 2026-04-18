# sim-bridge

macOS-only Swift daemon that bridges an iOS Simulator window to t3code's web UI over WebSocket.

## What it does

- Finds the active iOS Simulator window via `CGWindowListCopyWindowInfo`.
- Captures it at 24 fps with `ScreenCaptureKit`, encodes each frame to PNG, base64s, and pushes it to any subscribed pane on `ws://127.0.0.1:17323`.
- Synthesizes input (`tap`, `drag`, `type-text`, `press-key`) via `CGEvent` posted at the Simulator's window position.
- Walks the Simulator app's `AXUIElement` tree and matches `AXIdentifier` strings of the form `"file:line[|fn=...|kind=...|name=...]"`, returned as structured `SourceRef` data so a click in the pane can resolve to the SwiftUI view that drew the pixel.

## Build

```bash
cd apps/sim-bridge
swift build -c release
.build/release/sim-bridge --port 17323
```

First run will prompt for **Screen Recording** and **Accessibility** permissions in System Settings → Privacy & Security. Grant both.

## Wiring an iOS app

Annotate every interactive view with its source location so AX can return useful refs:

```swift
extension View {
    func sourceTag(_ name: String? = nil, kind: String = "view", file: String = #fileID, line: Int = #line) -> some View {
        let parts = ["\(file):\(line)", "kind=\(kind)", name.map { "name=\($0)" }].compactMap { $0 }
        return self.accessibilityIdentifier(parts.joined(separator: "|"))
    }
}
```

Then `MyButton().sourceTag("PrimaryCTA")` produces `Sources/MyApp/Views/Foo.swift:42|kind=view|name=PrimaryCTA`, which the pane displays as `view PrimaryCTA (Sources/MyApp/Views/Foo.swift:42)` and injects into the t3code composer as `@here ...`.

## Wire protocol

JSON over WebSocket. See `Sources/SimBridge/Protocol.swift` (Swift) and `packages/sim-pane/src/protocol.ts` (TypeScript) — they are the same shape.

Pane → bridge: `tap`, `drag`, `type-text`, `press-key`, `inspect-at`, `subscribe-frames`, `subscribe-ax`.
Bridge → pane: `frame`, `ax-snapshot`, `source-clicked`, `sim-info`, `inspect-result`, `error`.
