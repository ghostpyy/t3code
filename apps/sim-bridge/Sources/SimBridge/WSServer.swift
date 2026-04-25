import Foundation
import Network

/// Message-agnostic WebSocket transport. Consumers own encoding/decoding and
/// deal purely in `Data`. Delivers inbound client frames to `onMessage` and
/// fans outbound `Data` to all clients via `broadcast(data:)`.
///
/// Frames are sent as WebSocket text (JSON by convention); if callers need
/// binary framing they should broadcast bytes that already encode the frame.
final class WSServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "sim-bridge.ws")
    private var listener: NWListener?
    private var clients: [UUID: NWConnection] = [:]
    private let clientsLock = NSLock()
    private let port: UInt16

    /// Invoked on the server's internal queue for every inbound client frame.
    var onMessage: ((Data) -> Void)?

    init(port: UInt16) {
        self.port = port
    }

    func start() throws {
        let parameters = NWParameters(tls: nil)
        parameters.allowLocalEndpointReuse = true
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "WSServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bad port"])
        }
        let listener = try NWListener(using: parameters, on: nwPort)
        let logPort = port
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                FileHandle.standardError.write(Data("[sim-bridge] listener ready on ws://127.0.0.1:\(logPort)\n".utf8))
            case .failed(let err):
                FileHandle.standardError.write(Data("[sim-bridge] listener failed: \(err)\n".utf8))
                exit(2)
            case .cancelled:
                FileHandle.standardError.write(Data("[sim-bridge] listener cancelled\n".utf8))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        clientsLock.lock()
        for (_, conn) in clients { conn.cancel() }
        clients.removeAll()
        clientsLock.unlock()
    }

    /// Send one frame to every connected client.
    func broadcast(data: Data) {
        clientsLock.lock()
        let snapshot = Array(clients.values)
        clientsLock.unlock()
        for conn in snapshot { send(data, on: conn) }
    }

    // MARK: - private

    private func accept(_ conn: NWConnection) {
        let id = UUID()
        clientsLock.lock()
        clients[id] = conn
        clientsLock.unlock()
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receive(on: id)
            case .failed, .cancelled:
                self?.drop(id)
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func receive(on id: UUID) {
        clientsLock.lock()
        let conn = clients[id]
        clientsLock.unlock()
        guard let conn else { return }
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.onMessage?(data)
            }
            if error != nil {
                self.drop(id)
            } else {
                self.receive(on: id)
            }
        }
    }

    private func drop(_ id: UUID) {
        clientsLock.lock()
        let conn = clients.removeValue(forKey: id)
        clientsLock.unlock()
        conn?.cancel()
    }

    private func send(_ data: Data, on conn: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "send", metadata: [metadata])
        conn.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }
}
