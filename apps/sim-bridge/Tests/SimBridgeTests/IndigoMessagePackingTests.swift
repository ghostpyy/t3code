import XCTest
import CSupport
@testable import SimBridge

final class IndigoMessagePackingTests: XCTestCase {
    func testTouchRatioClamp() {
        let (rx, ry) = IndigoBridge.normalizeRatio(x: 100, y: 200, pixelWidth: 400, pixelHeight: 800)
        XCTAssertEqual(rx, 0.25, accuracy: 0.0001)
        XCTAssertEqual(ry, 0.25, accuracy: 0.0001)
    }

    func testButtonSourceLookup() {
        XCTAssertEqual(IndigoBridge.buttonSource(for: .home), 0x0)
        XCTAssertEqual(IndigoBridge.buttonSource(for: .lock), 0x1)
        XCTAssertEqual(IndigoBridge.buttonSource(for: .siri), 0x400002)
        XCTAssertEqual(IndigoBridge.buttonSource(for: .side), 0xbb8)
        XCTAssertEqual(IndigoBridge.buttonSource(for: .applePay), 0x1f4)
    }

    /// Verifies the touch-message builder returns nil (not a crash) when no
    /// SimulatorKit symbol is available. Smoke-test guards against a silent
    /// regression where the C helper starts trusting a null symbol pointer.
    func testBuildIndigoTouchMessageRejectsNullSymbol() {
        var size: Int = 0
        let result = T3BuildIndigoTouchMessage(nil, 0.5, 0.5, 1, &size)
        XCTAssertNil(result)
    }

    /// End-to-end shape test: when SimulatorKit is available on the host
    /// (always true on macOS build machines with Xcode installed), the
    /// builder must return a 0x140 / 320-byte buffer with the magic
    /// `payload.field1 = 0x0000000b` eventKind and eventType=0x2.
    func testBuildIndigoTouchMessageProducesCorrectShape() throws {
        // Load SimulatorKit if possible; skip test if dev machine lacks it.
        do { try IndigoBridge.shared.load() } catch {
            throw XCTSkip("SimulatorKit not available: \(error.localizedDescription)")
        }

        // Resolve the symbol via the same path the runtime uses.
        guard let handle = dlopen(
            "/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit",
            RTLD_NOW
        ) else {
            throw XCTSkip("SimulatorKit not dlopen-able")
        }
        defer { dlclose(handle) }
        guard let sym = dlsym(handle, "IndigoHIDMessageForMouseNSEvent") else {
            throw XCTSkip("IndigoHIDMessageForMouseNSEvent symbol missing")
        }

        var size: Int = 0
        guard let raw = T3BuildIndigoTouchMessage(sym, 0.5, 0.5, 1, &size) else {
            XCTFail("builder returned nil")
            return
        }
        defer { free(raw) }
        XCTAssertEqual(size, 0x140, "touch message must be 320 bytes")

        // Validate the first 32 bytes: header is opaque, but innerSize at 0x18
        // is u32 = 0xa0, eventType at 0x1c is u8 = 0x02, payload.field1 at
        // 0x20 is u32 = 0x0000000b.
        let bytes = raw.assumingMemoryBound(to: UInt8.self)
        let innerSize = UnsafeRawPointer(bytes.advanced(by: 0x18))
            .load(as: UInt32.self)
        let eventType = bytes.advanced(by: 0x1c).pointee
        let eventKind = UnsafeRawPointer(bytes.advanced(by: 0x20))
            .load(as: UInt32.self)
        // sizeof(IndigoPayload) under #pragma pack(push, 4) = 0x90 (144).
        // fb-idb documents `stride = sizeof(IndigoPayload) = 0x90` in
        // +[FBSimulatorIndigoHID touchMessageWithPayload:]. Our layout must
        // match so the guest's dispatcher walks the duplicated payload at
        // the same offset.
        XCTAssertEqual(innerSize, 0x90)
        XCTAssertEqual(eventType, 0x02)
        XCTAssertEqual(eventKind, 0x0000000b)
    }
}
