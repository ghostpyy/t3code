import Foundation
import Network

actor WSServer {
    typealias Handler = @Sendable (PaneToBridgeMessage, ClientID) async -> Void

    struct ClientID: Hashable, Sendable {
        let raw: UUID
    }

    private var listener: NWListener?
    private var clients: [ClientID: NWConnection] = [:]
    private var handler: Handler?
    private let port: UInt16

    init(port: UInt16) {
        self.port = port
    }

    func setHandler(_ handler: @escaping Handler) {
        self.handler = handler
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
        listener.newConnectionHandler = { [weak self] conn in
            Task { await self?.accept(conn) }
        }
        listener.start(queue: DispatchQueue(label: "sim-bridge.ws"))
        self.listener = listener
        FileHandle.standardError.write(Data("[sim-bridge] listening on ws://127.0.0.1:\(port)\n".utf8))
    }

    func broadcast(_ message: BridgeToPaneMessage) async {
        guard let data = try? message.encode() else { return }
        for (_, conn) in clients {
            send(data, on: conn)
        }
    }

    func send(_ message: BridgeToPaneMessage, to client: ClientID) async {
        guard let data = try? message.encode(), let conn = clients[client] else { return }
        send(data, on: conn)
    }

    private func accept(_ conn: NWConnection) {
        let id = ClientID(raw: UUID())
        clients[id] = conn
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Task { await self?.receive(on: id) }
            case .failed, .cancelled:
                Task { await self?.drop(id) }
            default:
                break
            }
        }
        conn.start(queue: DispatchQueue(label: "sim-bridge.ws.client"))
    }

    private func receive(on id: ClientID) {
        guard let conn = clients[id] else { return }
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                Task { await self.dispatch(data: data, from: id) }
            }
            if error != nil {
                Task { await self.drop(id) }
            } else {
                Task { await self.receive(on: id) }
            }
        }
    }

    private func dispatch(data: Data, from id: ClientID) async {
        guard let handler else { return }
        do {
            let msg = try JSONDecoder().decode(PaneToBridgeMessage.self, from: data)
            await handler(msg, id)
        } catch {
            FileHandle.standardError.write(Data("[sim-bridge] decode error: \(error)\n".utf8))
        }
    }

    private func drop(_ id: ClientID) {
        if let conn = clients.removeValue(forKey: id) {
            conn.cancel()
        }
    }

    private nonisolated func send(_ data: Data, on conn: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "send", metadata: [metadata])
        conn.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }
}
