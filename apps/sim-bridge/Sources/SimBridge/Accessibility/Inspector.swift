import Foundation
import CoreGraphics
import CPrivate

public struct AXFrame: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    /// Corner radius of the backing view (display points). Zero means square
    /// corners; the native outline picker uses this to draw its highlight
    /// with the same rounded shape as the element instead of a blunt
    /// rectangle sitting on top of a pill-shaped button.
    public let cornerRadius: Double

    public init(x: Double, y: Double, width: Double, height: Double, cornerRadius: Double = 0) {
        self.x = x; self.y = y; self.width = width; self.height = height
        self.cornerRadius = cornerRadius
    }

    public static let zero = AXFrame(x: 0, y: 0, width: 0, height: 0)
}

public struct AXSourceHint: Codable, Equatable, Sendable {
    public let absolutePath: String
    public let line: Int
    public let reason: String
    public let confidence: Double
    /// Raw source neighborhood centered on `line`. Newlines preserved so the
    /// pane can render a fenced `swift` block verbatim; nil when we could not
    /// read the file (unresolved absolute path, or the resolve was purely
    /// heuristic and points at a guessed relative path).
    public let snippet: String?
    /// 1-indexed file line that corresponds to the first line of `snippet`.
    /// Lets the renderer number each row correctly even when the hit isn't at
    /// the geometric midpoint (top/bottom of file truncation).
    public let snippetStartLine: Int?

    public init(
        absolutePath: String,
        line: Int,
        reason: String,
        confidence: Double,
        snippet: String? = nil,
        snippetStartLine: Int? = nil
    ) {
        self.absolutePath = absolutePath
        self.line = line
        self.reason = reason
        self.confidence = confidence
        self.snippet = snippet
        self.snippetStartLine = snippetStartLine
    }
}

public struct AXElement: Codable, Sendable {
    public let id: String
    public let role: String
    public let label: String?
    public let value: String?
    public let frame: AXFrame
    public let identifier: String?
    public let enabled: Bool
    public let selected: Bool
    public let children: [AXElement]?
    public let appContext: SimAppInfo?
    public let sourceHints: [AXSourceHint]?

    public init(
        id: String,
        role: String,
        label: String?,
        value: String?,
        frame: AXFrame,
        identifier: String?,
        enabled: Bool,
        selected: Bool,
        children: [AXElement]?,
        appContext: SimAppInfo? = nil,
        sourceHints: [AXSourceHint]? = nil
    ) {
        self.id = id
        self.role = role
        self.label = label
        self.value = value
        self.frame = frame
        self.identifier = identifier
        self.enabled = enabled
        self.selected = selected
        self.children = children
        self.appContext = appContext
        self.sourceHints = sourceHints
    }
}

public final class Inspector: @unchecked Sendable {
    private let bridge: Bridge
    private var enabled = false

    public init(bridge: Bridge) { self.bridge = bridge }

    public func enable() {
        if enabled { return }
        bridge.enableAccessibility()
        enabled = true
    }

    public func hitTest(x: Int, y: Int, displayId: Int = 0) -> [AXElement] {
        let proxy = bridge.proxy
        let selHit = NSSelectorFromString("accessibilityElementForPoint:andY:displayId:")
        let selTree = NSSelectorFromString("accessibilityElementsWithDisplayId:")

        if let method = class_getInstanceMethod(type(of: proxy), selHit) {
            typealias HitIMP = @convention(c) (AnyObject, Selector, Double, Double, Int) -> NSDictionary?
            let imp = method_getImplementation(method)
            let fn = unsafeBitCast(imp, to: HitIMP.self)
            if let dict = fn(proxy, selHit, Double(x), Double(y), displayId) {
                return [Self.decode(dict: dict)]
            }
        }
        if let method = class_getInstanceMethod(type(of: proxy), selTree) {
            typealias TreeIMP = @convention(c) (AnyObject, Selector, Int) -> NSDictionary?
            let imp = method_getImplementation(method)
            let fn = unsafeBitCast(imp, to: TreeIMP.self)
            if let root = fn(proxy, selTree, displayId) {
                return [Self.decode(dict: root)]
            }
        }
        return []
    }

    public func tree(displayId: Int = 0) -> AXElement? {
        let proxy = bridge.proxy
        let sel = NSSelectorFromString("accessibilityElementsWithDisplayId:")
        guard let method = class_getInstanceMethod(type(of: proxy), sel) else { return nil }
        typealias TreeIMP = @convention(c) (AnyObject, Selector, Int) -> NSDictionary?
        let imp = method_getImplementation(method)
        let fn = unsafeBitCast(imp, to: TreeIMP.self)
        return fn(proxy, sel, displayId).map(Self.decode)
    }

    private static func decode(dict: NSDictionary) -> AXElement {
        func str(_ key: String) -> String? { dict[key] as? String }
        func bool(_ key: String) -> Bool { (dict[key] as? NSNumber)?.boolValue ?? false }
        func frame(_ key: String) -> AXFrame {
            if let arr = dict[key] as? [NSNumber], arr.count == 4 {
                return AXFrame(x: arr[0].doubleValue, y: arr[1].doubleValue,
                               width: arr[2].doubleValue, height: arr[3].doubleValue)
            }
            if let d = dict[key] as? NSDictionary,
               let origin = d["origin"] as? NSDictionary,
               let size = d["size"] as? NSDictionary {
                let x = (origin["x"] as? NSNumber)?.doubleValue ?? 0
                let y = (origin["y"] as? NSNumber)?.doubleValue ?? 0
                let w = (size["width"] as? NSNumber)?.doubleValue ?? 0
                let h = (size["height"] as? NSNumber)?.doubleValue ?? 0
                let radius = (d["cornerRadius"] as? NSNumber)?.doubleValue ?? 0
                return AXFrame(x: x, y: y, width: w, height: h, cornerRadius: radius)
            }
            return .zero
        }
        let identifier = str("AXIdentifier") ?? str("identifier")
        let kids = (dict["children"] as? [NSDictionary])?.map(decode)
        return AXElement(
            id: str("uniqueId") ?? UUID().uuidString,
            role: str("AXRole") ?? str("role") ?? "unknown",
            label: str("AXLabel") ?? str("label"),
            value: str("AXValue") ?? str("value"),
            frame: frame("frame"),
            identifier: identifier,
            enabled: bool("AXEnabled"),
            selected: bool("AXSelected"),
            children: kids
        )
    }
}
