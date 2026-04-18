import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ScreenCaptureKit

actor WindowCapture {
    private var stream: SCStream?
    private var output: FrameOutput?
    private var currentWindowID: CGWindowID?
    private var fps: Int = 30
    private var captureWidth: Int = 0
    private var captureHeight: Int = 0
    private var subscribers: [@Sendable (Data, Int, Int) async -> Void] = []
    private var running = false

    func subscribe(_ handler: @escaping @Sendable (Data, Int, Int) async -> Void) {
        subscribers.append(handler)
    }

    func setFps(_ value: Int) async {
        fps = max(1, min(60, value))
        if running, let id = currentWindowID {
            await stop()
            try? await start(windowID: id)
        }
    }

    func start(windowID: CGWindowID) async throws {
        if running, currentWindowID == windowID { return }
        await stop()

        let content = try await SCShareableContent.current
        guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
            throw NSError(domain: "WindowCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Window not found"])
        }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let cfg = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let w = Int(scWindow.frame.width * scale)
        let h = Int(scWindow.frame.height * scale)
        cfg.width = w
        cfg.height = h
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.queueDepth = 5
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false
        cfg.scalesToFit = true

        let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
        let output = FrameOutput { [weak self] data, w, h in
            guard let self else { return }
            await self.dispatch(data: data, w: w, h: h)
        }
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "sim-bridge.capture"))
        try await stream.startCapture()

        self.stream = stream
        self.output = output
        self.currentWindowID = windowID
        self.captureWidth = w
        self.captureHeight = h
        self.running = true
    }

    func stop() async {
        if let stream = self.stream {
            try? await stream.stopCapture()
        }
        stream = nil
        output = nil
        running = false
    }

    private func dispatch(data: Data, w: Int, h: Int) async {
        for sub in subscribers {
            await sub(data, w, h)
        }
    }
}

private final class FrameOutput: NSObject, SCStreamOutput {
    let handler: @Sendable (Data, Int, Int) async -> Void
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private static let colorSpace = CGColorSpaceCreateDeviceRGB()
    private static let jpegOptions: [CIImageRepresentationOption: Any] = [
        CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.65
    ]
    private let throttleQueue = DispatchQueue(label: "sim-bridge.encode", qos: .userInteractive)
    private var encoding = false

    init(handler: @escaping @Sendable (Data, Int, Int) async -> Void) {
        self.handler = handler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if encoding { return }
        encoding = true

        let ci = CIImage(cvPixelBuffer: imageBuffer)
        let extent = ci.extent
        let w = Int(extent.width)
        let h = Int(extent.height)

        throttleQueue.async { [handler, weak self] in
            defer { self?.encoding = false }
            guard let jpeg = FrameOutput.ciContext.jpegRepresentation(
                of: ci,
                colorSpace: FrameOutput.colorSpace,
                options: FrameOutput.jpegOptions
            ) else { return }
            Task { await handler(jpeg, w, h) }
        }
    }
}
