import AppKit
import Foundation

@main
struct SimBridgeMain {
    static func main() async {
        let port = parsePort() ?? BridgeProtocol.defaultPort
        _ = AXBridge.ensureTrusted()

        let server = WSServer(port: port)
        let capture = WindowCapture()
        let coordinator = Coordinator(server: server, capture: capture)
        await coordinator.bootstrap()

        do {
            try await server.start()
        } catch {
            FileHandle.standardError.write(Data("[sim-bridge] failed to start: \(error)\n".utf8))
            exit(1)
        }

        await coordinator.run()
    }

    private static func parsePort() -> UInt16? {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--port"), idx + 1 < args.count else { return nil }
        return UInt16(args[idx + 1])
    }
}

actor Coordinator {
    private let server: WSServer
    private let capture: WindowCapture
    private var window: SimulatorWindow?
    private var simInfo: BridgeProtocol.SimInfo?
    private var axIntervalMs: Int = 500
    private var axTask: Task<Void, Never>?

    init(server: WSServer, capture: WindowCapture) {
        self.server = server
        self.capture = capture
    }

    func bootstrap() async {
        await refreshTarget()
        await capture.subscribe { [weak self] data, w, h in
            await self?.broadcastFrame(data, w: w, h: h)
        }
        await server.setHandler { [weak self] msg, client in
            await self?.handle(msg, from: client)
        }
        startAxLoop()
        startWatchdog()
    }

    func run() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func handle(_ msg: PaneToBridgeMessage, from client: WSServer.ClientID) async {
        switch msg {
        case .tap(let x, let y):
            guard let w = window else { return }
            let point = InputSynth.simToScreen(simX: x, simY: y, window: w, simInfo: simInfo)
            InputSynth.tap(at: point)
        case .drag(let fx, let fy, let tx, let ty, let dur):
            guard let w = window else { return }
            let from = InputSynth.simToScreen(simX: fx, simY: fy, window: w, simInfo: simInfo)
            let to = InputSynth.simToScreen(simX: tx, simY: ty, window: w, simInfo: simInfo)
            InputSynth.drag(from: from, to: to, durationMs: dur)
        case .typeText(let text):
            InputSynth.typeText(text)
        case .pressKey(let key):
            InputSynth.pressKey(key)
        case .inspectAt(let x, let y, let requestId):
            let ref: BridgeProtocol.SourceRef?
            if let w = window {
                ref = AXBridge.inspect(at: x, simY: y, pid: w.pid, window: w, simInfo: simInfo)
            } else {
                ref = nil
            }
            await server.send(.inspectResult(requestId: requestId, ref: ref), to: client)
        case .subscribeFrames(let fps):
            await capture.setFps(fps)
        case .subscribeAx(let intervalMs):
            axIntervalMs = max(100, min(5000, intervalMs))
        case .unknown:
            break
        }
    }

    private func broadcastFrame(_ data: Data, w: Int, h: Int) async {
        let ts = Date().timeIntervalSince1970
        await server.broadcast(.frame(image: data, mime: "image/jpeg", w: w, h: h, ts: ts))
    }

    private func refreshTarget() async {
        let next = WindowFinder.locateActiveSimulatorWindow()
        let info = WindowFinder.bootedDeviceInfo()
        let changed = next != window
        window = next
        if let info, info != simInfo {
            simInfo = info
            await server.broadcast(.simInfo(info))
        }
        if changed, let w = next {
            do {
                try await capture.start(windowID: w.windowID)
            } catch {
                FileHandle.standardError.write(Data("[sim-bridge] capture start failed: \(error)\n".utf8))
            }
        } else if next == nil {
            await capture.stop()
        }
    }

    private func startWatchdog() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self?.refreshTarget()
            }
        }
    }

    private func startAxLoop() {
        axTask?.cancel()
        axTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = await self.axIntervalMs
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000)
                await self.emitAxSnapshot()
            }
        }
    }

    private func emitAxSnapshot() async {
        guard let w = window else { return }
        let nodes = AXBridge.snapshot(pid: w.pid, window: w, simInfo: simInfo)
        if nodes.isEmpty { return }
        await server.broadcast(.axSnapshot(nodes: nodes, ts: Date().timeIntervalSince1970))
    }
}
