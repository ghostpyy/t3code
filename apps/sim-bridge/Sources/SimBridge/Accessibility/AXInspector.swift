import Foundation
import CoreGraphics
import CPrivate
import CSupport

/// Xcode 26-era AX inspector. Wraps `AXPTranslator` via `T3AXBridge` —
/// the same SPI `Accessibility Inspector.app` uses. Returns an ancestor
/// chain (leaf → root) for the point the user clicked.
public final class AXInspector: @unchecked Sendable {
    public let device: SimDevice

    public init?(device: SimDevice) {
        self.device = device
        if !T3AXBridgeSetup(device) {
            FileHandle.standardError.write(Data(
                "[ax] AXPTranslator setup failed — no live hierarchy\n".utf8))
            return nil
        }
    }

    public func hitTest(x: Int, y: Int, displayId: UInt32 = 0) -> [AXElement] {
        guard let chain = T3AXBridgeHitTest(Double(x), Double(y), displayId) else {
            return []
        }
        return chain.map(Self.decode)
    }

    public func frontmost(displayId: UInt32 = 0) -> AXElement? {
        guard let dict = T3AXBridgeFrontmost(displayId) else { return nil }
        return Self.decode(dict: dict)
    }

    public var available: Bool { T3AXBridgeAvailable() }

    private static func decode(dict: [AnyHashable: Any]) -> AXElement {
        func str(_ k: String) -> String? { dict[k] as? String }
        func bool(_ k: String) -> Bool { (dict[k] as? NSNumber)?.boolValue ?? false }

        let frame: AXFrame
        if let arr = dict["frame"] as? [NSNumber], arr.count == 4 {
            frame = AXFrame(
                x: arr[0].doubleValue,
                y: arr[1].doubleValue,
                width: arr[2].doubleValue,
                height: arr[3].doubleValue
            )
        } else {
            frame = .zero
        }

        return AXElement(
            id: str("id") ?? UUID().uuidString,
            role: str("role") ?? "Element",
            label: str("label") ?? str("title"),
            value: str("value"),
            frame: frame,
            identifier: str("identifier"),
            enabled: bool("enabled"),
            selected: bool("selected"),
            children: nil
        )
    }
}
