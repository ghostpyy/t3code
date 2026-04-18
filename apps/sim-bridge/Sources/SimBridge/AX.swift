import ApplicationServices
import CoreGraphics
import Foundation

enum AXBridge {
    static func snapshot(pid: pid_t, window: SimulatorWindow, simInfo: BridgeProtocol.SimInfo?) -> [BridgeProtocol.AXNode] {
        let app = AXUIElementCreateApplication(pid)
        var windows: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
              let windowList = windows as? [AXUIElement]
        else { return [] }

        var nodes: [BridgeProtocol.AXNode] = []
        for w in windowList {
            walk(element: w, into: &nodes, window: window, simInfo: simInfo)
        }
        return nodes
    }

    static func inspect(at simX: Int, simY: Int, pid: pid_t, window: SimulatorWindow, simInfo: BridgeProtocol.SimInfo?) -> BridgeProtocol.SourceRef? {
        let screenPoint = InputSynth.simToScreen(simX: simX, simY: simY, window: window, simInfo: simInfo)
        let app = AXUIElementCreateApplication(pid)
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(app, Float(screenPoint.x), Float(screenPoint.y), &element)
        guard result == .success, let el = element else { return nil }

        var bestSourceRef: BridgeProtocol.SourceRef?
        var bestAxRef: BridgeProtocol.SourceRef?
        var current: AXUIElement? = el
        var depth = 0
        while let node = current, depth < 12 {
            let ref = enrichedRef(from: node)
            if ref.file.isEmpty == false, bestSourceRef == nil {
                bestSourceRef = ref
            }
            if bestAxRef == nil, ref.role != nil || ref.title != nil || ref.identifier != nil {
                bestAxRef = ref
            }
            if bestSourceRef != nil { break }
            var parent: AnyObject?
            if AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent) == .success,
               let p = parent {
                current = (p as! AXUIElement)
            } else {
                break
            }
            depth += 1
        }
        return bestSourceRef ?? bestAxRef
    }

    private static func walk(element: AXUIElement, into nodes: inout [BridgeProtocol.AXNode], window: SimulatorWindow, simInfo: BridgeProtocol.SimInfo?) {
        if nodes.count > 1500 { return }
        let ref = enrichedRef(from: element)
        let hasContent = ref.file.isEmpty == false || ref.role != nil || ref.title != nil || ref.identifier != nil
        if hasContent, let frame = simFrame(of: element, window: window, simInfo: simInfo) {
            nodes.append(BridgeProtocol.AXNode(
                file: ref.file,
                line: ref.line,
                function: ref.function,
                kind: ref.kind,
                name: ref.name,
                role: ref.role,
                title: ref.title,
                value: ref.value,
                help: ref.help,
                identifier: ref.identifier,
                frame: frame
            ))
        }
        var children: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
           let list = children as? [AXUIElement] {
            for child in list {
                walk(element: child, into: &nodes, window: window, simInfo: simInfo)
            }
        }
    }

    private static func enrichedRef(from element: AXUIElement) -> BridgeProtocol.SourceRef {
        let raw = stringAttribute(element, kAXIdentifierAttribute)
        var ref = (raw.flatMap(parseIdentifier) ?? BridgeProtocol.SourceRef(file: "", line: 0))
        if let raw, !raw.isEmpty { ref.identifier = raw }
        ref.role = stringAttribute(element, kAXRoleAttribute)
        ref.title = nonEmpty(stringAttribute(element, kAXTitleAttribute))
            ?? nonEmpty(stringAttribute(element, kAXDescriptionAttribute))
        ref.value = nonEmpty(stringAttribute(element, kAXValueAttribute))
        ref.help = nonEmpty(stringAttribute(element, kAXHelpAttribute))
        return ref
    }

    private static func stringAttribute(_ element: AXUIElement, _ attr: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    static func parseIdentifier(_ raw: String) -> BridgeProtocol.SourceRef? {
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard let head = parts.first else { return nil }
        let fileLine = head.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard fileLine.count >= 2, let line = Int(fileLine[1]) else { return nil }
        let file = fileLine[0]
        var function: String?
        var kind: String?
        var name: String?
        for token in parts.dropFirst() {
            let kv = token.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "fn": function = kv[1]
            case "kind": kind = kv[1]
            case "name": name = kv[1]
            default: break
            }
        }
        return BridgeProtocol.SourceRef(file: file, line: line, function: function, kind: kind, name: name)
    }

    private static func simFrame(of element: AXUIElement, window: SimulatorWindow, simInfo: BridgeProtocol.SimInfo?) -> BridgeProtocol.Frame? {
        var positionRef: AnyObject?
        var sizeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)

        let bounds = window.bounds
        let localX = origin.x - bounds.origin.x
        let localY = origin.y - bounds.origin.y
        let scaleX: Double
        let scaleY: Double
        if let info = simInfo, info.screenW > 0, info.screenH > 0 {
            scaleX = Double(info.screenW) / Double(bounds.width)
            scaleY = Double(info.screenH) / Double(bounds.height)
        } else {
            scaleX = 1.0
            scaleY = 1.0
        }
        return BridgeProtocol.Frame(
            x: Int(Double(localX) * scaleX),
            y: Int(Double(localY) * scaleY),
            w: Int(Double(size.width) * scaleX),
            h: Int(Double(size.height) * scaleY)
        )
    }

    static func ensureTrusted() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }
}
