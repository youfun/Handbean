import Foundation
import Network
import Security

/// A per-launch credential is inherited only by the BEAM child. The listener
/// binds IPv4 loopback, accepts one bounded JSON line, and never retries input.
@MainActor
final class ComputerBridge {
    let controller: ComputerController
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private var connections: [UUID: ComputerConnection] = [:]
    private var seen: Set<String> = []
    private var order: [String] = []
    private let token: String

    init(verificationOnly: Bool = false) throws {
        controller = ComputerController(verificationOnly: verificationOnly)
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw BridgeError.unavailable
        }
        token = Data(bytes).base64EncodedString()
    }

    enum BridgeError: Error { case unavailable }

    func start() async throws -> [String: String] {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                guard self.connections.count < 8 else { connection.cancel(); return }
                let id = UUID()
                let client = ComputerConnection(connection: connection, bridge: self, cleanup: { [weak self] in
                    self?.connections.removeValue(forKey: id)
                })
                self.connections[id] = client
                client.start()
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.listenerStateChanged(state)
                }
            }
            listener.start(queue: .main)
        }
        return ["HANDBEAN_COMPUTER_PORT": String(port), "HANDBEAN_COMPUTER_TOKEN": token]
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            let port = listener?.port?.rawValue
            finishStart(port: port)
        case .failed, .cancelled:
            finishStart(port: nil)
        default: break
        }
    }

    private func finishStart(port: UInt16?) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        if let port { continuation.resume(returning: port) }
        else { continuation.resume(throwing: BridgeError.unavailable) }
    }

    func accept(_ request: [String: Any]) -> Bool {
        guard let supplied = request["token"] as? String,
              supplied.utf8.count == token.utf8.count,
              zip(supplied.utf8, token.utf8).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0,
              let id = request["id"] as? String, UUID(uuidString: id) != nil,
              let session = request["session"] as? String, !session.isEmpty, session.count <= 120,
              let deadline = request["deadline_ms"] as? Double,
              deadline > Date().timeIntervalSince1970 * 1000,
              deadline <= Date().timeIntervalSince1970 * 1000 + 60_000,
              request["input"] is [String: Any], !seen.contains(id) else { return false }
        seen.insert(id)
        order.append(id)
        if order.count > 256 { seen.remove(order.removeFirst()) }
        return true
    }

    func stop() {
        controller.stop()
        for connection in Array(connections.values) { connection.close() }
        finishStart(port: nil)
        listener?.cancel()
        listener = nil
    }
}

@MainActor
private final class ComputerConnection {
    private let connection: NWConnection
    private unowned let bridge: ComputerBridge
    private let cleanup: () -> Void
    private var buffer = Data()
    private var task: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var requestID: String?
    private var completed = false
    private var closed = false

    init(connection: NWConnection, bridge: ComputerBridge, cleanup: @escaping () -> Void) {
        self.connection = connection
        self.bridge = bridge
        self.cleanup = cleanup
    }
    func start() {
        connection.start(queue: .main)
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !Task.isCancelled { self?.close() }
        }
        receive()
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, eof, error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                if let data {
                    if self.requestID != nil { self.close(); return }
                    self.buffer.append(data)
                    guard self.buffer.count <= 32_768 else { self.close(); return }
                    if self.buffer.last == 10 { self.dispatch() }
                }
                if eof || error != nil { self.close() }
                else { self.receive() } // EOF while approval/capture is pending cancels it.
            }
        }
    }
    private func dispatch() {
        guard let request = (try? JSONSerialization.jsonObject(with: buffer)) as? [String: Any],
              bridge.accept(request), let id = request["id"] as? String,
              let session = request["session"] as? String,
              let input = request["input"] as? [String: Any],
              let deadline = request["deadline_ms"] as? Double else { close(); return }
        buffer.removeAll()
        requestID = id
        timer?.cancel()
        let remaining = max(0, deadline / 1000 - Date().timeIntervalSince1970)
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            if !Task.isCancelled { self?.close() }
        }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.bridge.controller.perform(id: id, session: session, input: input, deadline: deadline)
            guard !self.closed, !Task.isCancelled else { return }
            self.completed = true
            self.timer?.cancel()
            guard var data = try? JSONSerialization.data(withJSONObject: ["id": id, "result": result]) else { self.close(); return }
            data.append(10)
            self.connection.send(content: data, completion: .contentProcessed { [weak self] _ in
                Task { @MainActor in self?.close() }
            })
        }
    }
    func close() {
        guard !closed else { return }
        closed = true
        if !completed, let id = requestID { bridge.controller.cancel(request: id) }
        task?.cancel()
        timer?.cancel()
        connection.cancel()
        cleanup()
    }
}
