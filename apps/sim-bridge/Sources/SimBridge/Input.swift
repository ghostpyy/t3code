import AppKit
import CoreGraphics
import Foundation

enum InputSynth {
    static func simToScreen(simX: Int, simY: Int, window: SimulatorWindow, simInfo: BridgeProtocol.SimInfo?) -> CGPoint {
        let bounds = window.bounds
        let scaleX: Double
        let scaleY: Double
        if let info = simInfo, info.screenW > 0, info.screenH > 0 {
            scaleX = Double(bounds.width) / Double(info.screenW)
            scaleY = Double(bounds.height) / Double(info.screenH)
        } else {
            scaleX = 1.0
            scaleY = 1.0
        }
        let x = bounds.origin.x + CGFloat(Double(simX) * scaleX)
        let y = bounds.origin.y + CGFloat(Double(simY) * scaleY)
        return CGPoint(x: x, y: y)
    }

    static func tap(at point: CGPoint) {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        else { return }
        down.post(tap: .cghidEventTap)
        usleep(20_000)
        up.post(tap: .cghidEventTap)
    }

    static func drag(from: CGPoint, to: CGPoint, durationMs: Int) {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left) else { return }
        down.post(tap: .cghidEventTap)

        let steps = max(8, min(60, durationMs / 16))
        let totalUSec = UInt32(max(durationMs, 16)) * 1000
        let stepUSec = totalUSec / UInt32(steps)

        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let x = from.x + (to.x - from.x) * CGFloat(t)
            let y = from.y + (to.y - from.y) * CGFloat(t)
            let point = CGPoint(x: x, y: y)
            if let move = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) {
                move.post(tap: .cghidEventTap)
            }
            usleep(stepUSec)
        }

        if let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left) {
            up.post(tap: .cghidEventTap)
        }
    }

    static func typeText(_ text: String) {
        for scalar in text.unicodeScalars {
            postUnicode(UInt16(scalar.value & 0xFFFF))
        }
    }

    private static func postUnicode(_ codeUnit: UInt16) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else { return }
        var unit = codeUnit
        down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
        up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    static func pressKey(_ key: String) {
        guard let code = keyCode(for: key) else { return }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func keyCode(for key: String) -> CGKeyCode? {
        switch key.lowercased() {
        case "return", "enter": return 36
        case "tab": return 48
        case "space": return 49
        case "delete", "backspace": return 51
        case "escape", "esc": return 53
        case "left": return 123
        case "right": return 124
        case "down": return 125
        case "up": return 126
        case "home": return 115
        case "end": return 119
        default: return nil
        }
    }
}
