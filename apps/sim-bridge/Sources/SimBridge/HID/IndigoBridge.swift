import Foundation
import AppKit
import CSupport

public enum HardwareButton: String, Codable, Sendable {
    case home, lock, siri, side, applePay, keyboard
}

public struct IndigoMessageHandle {
    public let rawBuffer: UnsafeMutableRawPointer
    public let byteLength: Int
}

/// Loads SimulatorKit at runtime, resolves the Indigo C helpers, and exposes
/// Swift-friendly message constructors.
public final class IndigoBridge {
    public static let shared = IndigoBridge()

    private var handle: UnsafeMutableRawPointer?
    private var _mouse: UnsafeMutableRawPointer?
    private var _button: UnsafeMutableRawPointer?
    private var _keyboardNSEvent: UnsafeMutableRawPointer?
    private var _keyboardArbitrary: UnsafeMutableRawPointer?

    public enum IndigoError: Error, LocalizedError {
        case loadFailed
        case symbolMissing(String)
        public var errorDescription: String? {
            switch self {
            case .loadFailed: return "Failed to dlopen SimulatorKit."
            case .symbolMissing(let s): return "Missing Indigo symbol: \(s)"
            }
        }
    }

    private init() {}

    public func load() throws {
        if handle != nil { return }
        let path = try Self.simulatorKitPath()
        guard let h = dlopen(path, RTLD_NOW | RTLD_GLOBAL) else {
            throw IndigoError.loadFailed
        }
        handle = h
        _mouse = dlsym(h, "IndigoHIDMessageForMouseNSEvent")
        _button = dlsym(h, "IndigoHIDMessageForButton")
        _keyboardNSEvent = dlsym(h, "IndigoHIDMessageForKeyboardNSEvent")
        _keyboardArbitrary = dlsym(h, "IndigoHIDMessageForKeyboardArbitrary")
        try require(_mouse, "IndigoHIDMessageForMouseNSEvent")
        try require(_button, "IndigoHIDMessageForButton")
    }

    private func require(_ ptr: UnsafeMutableRawPointer?, _ name: String) throws {
        if ptr == nil { throw IndigoError.symbolMissing(name) }
    }

    // MARK: Ratios & constants

    public static func normalizeRatio(x: Double, y: Double, pixelWidth: Int, pixelHeight: Int) -> (Double, Double) {
        let rx = max(0, min(1, x / Double(pixelWidth)))
        let ry = max(0, min(1, y / Double(pixelHeight)))
        return (rx, ry)
    }

    public static func buttonSource(for button: HardwareButton) -> UInt32 {
        switch button {
        case .home: return 0x0
        case .lock: return 0x1
        case .applePay: return 0x1f4
        case .side: return 0xbb8
        case .siri: return 0x400002
        case .keyboard: return 0x2710
        }
    }

    // MARK: Message builders

    public enum ButtonOp: Int32 { case down = 1; case up = 2 }
    public enum TouchOp: Int32 { case down = 1; case up = 2 }

    /// Returns a 320-byte (`0x140`) Indigo *touch* message, correctly shaped
    /// for the guest-side digitizer dispatcher. See
    /// `T3BuildIndigoTouchMessage` for the detailed wire-format rationale
    /// — calling `IndigoHIDMessageForMouseNSEvent` on its own yields a
    /// 192-byte mouse message that the simulator ignores, which is why
    /// earlier builds captured every click at the host layer but the
    /// guest OS never reacted.
    public func makeTapMessage(x: Double, y: Double, pixelWidth: Int, pixelHeight: Int, op: TouchOp) throws -> UnsafeMutableRawPointer {
        try load()
        let (rx, ry) = Self.normalizeRatio(x: x, y: y, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        guard let mouseSym = _mouse else {
            throw IndigoError.symbolMissing("IndigoHIDMessageForMouseNSEvent")
        }
        var size: Int = 0
        guard let buffer = T3BuildIndigoTouchMessage(mouseSym, rx, ry, op.rawValue, &size) else {
            throw IndigoError.symbolMissing("T3BuildIndigoTouchMessage")
        }
        return buffer
    }

    public func makeButtonMessage(button: HardwareButton, op: ButtonOp) throws -> UnsafeMutableRawPointer {
        try load()
        typealias IMP = @convention(c) (UInt32, Int32, UInt32) -> UnsafeMutableRawPointer
        let fn = unsafeBitCast(_button!, to: IMP.self)
        let source = Self.buttonSource(for: button)
        return fn(source, op.rawValue, 0x33)
    }

    public func makeKeyboardMessage(nsEvent: NSEvent) throws -> UnsafeMutableRawPointer {
        try load()
        guard let sym = _keyboardNSEvent else { throw IndigoError.symbolMissing("IndigoHIDMessageForKeyboardNSEvent") }
        typealias IMP = @convention(c) (NSEvent) -> UnsafeMutableRawPointer
        let fn = unsafeBitCast(sym, to: IMP.self)
        return fn(nsEvent)
    }

    public func makeArbitraryKey(usage: Int32, op: ButtonOp) throws -> UnsafeMutableRawPointer {
        try load()
        guard let sym = _keyboardArbitrary else { throw IndigoError.symbolMissing("IndigoHIDMessageForKeyboardArbitrary") }
        typealias IMP = @convention(c) (Int32, Int32) -> UnsafeMutableRawPointer
        let fn = unsafeBitCast(sym, to: IMP.self)
        return fn(usage, op.rawValue)
    }

    private static func simulatorKitPath() throws -> String {
        let task = Process()
        task.launchPath = "/usr/bin/xcode-select"
        task.arguments = ["-p"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try task.run()
        task.waitUntilExit()
        let dir = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(dir)/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"
    }
}
