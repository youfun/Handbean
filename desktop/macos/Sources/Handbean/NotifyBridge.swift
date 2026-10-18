import Foundation
import HandbeanCore
import Network
import Security

/// One authenticated loopback session from the BEAM this app spawned.
/// Visibility is pushed by AppKit; completion text is posted by this process.
@MainActor
final class NotifyBridge {
    private var listener: NWListener?
    private var connection: NotifyClient?
    private var pending: [NWConnection] = []
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private let token: String
    private let poster: MacNotifications
    var currentVisibility: () -> Bool = { true }

    init(poster: MacNotifications = .shared) throws {
        self.poster = poster
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NotifyBridgeError.unavailable
        }
        token = Data(bytes).base64EncodedString()
    }

    enum NotifyBridgeError: Error { case unavailable }

    func start() async throws -> [String: String] {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.accept(connection)
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
        return ["HANDBEAN_NOTIFY_PORT": String(port), "HANDBEAN_NOTIFY_TOKEN": token]
    }

    func setVisible(_ visible: Bool) {
        connection?.sendVisible(visible)
    }

    func stop() {
        connection?.close()
        connection = nil
        for connection in pending {
            connection.cancel()
        }
        pending.removeAll()
        finishStart(port: nil)
        listener?.cancel()
        listener = nil
    }

    private func accept(_ incoming: NWConnection) {
        guard pending.count < 4 else {
            incoming.cancel()
            return
        }
        pending.append(incoming)
        let client = NotifyClient(connection: incoming, bridge: self) { [weak self] client in
            self?.drop(client)
        }
        client.start()
    }

    fileprivate func authenticate(_ client: NotifyClient, token supplied: String) -> Bool {
        guard NotifyProtocol.tokensMatch(supplied, token) else { return false }
        pending.removeAll { $0 === client.connection }
        if connection !== client {
            connection?.close()
            connection = client
        }
        client.sendVisible(currentVisibility())
        return true
    }

    fileprivate func forgetPending(_ connection: NWConnection) {
        pending.removeAll { $0 === connection }
    }

    fileprivate func handle(_ inbound: NotifyInbound) {
        switch inbound {
        case .hello:
            break
        case .showEnded(let ended):
            poster.post(ended)
        case .updateRunning(let running, let waiting):
            if running + waiting > 0 {
                poster.requestAuthorizationIfNeeded()
            }
            poster.setBadge(running: running, waiting: waiting)
        }
    }

    private func drop(_ client: NotifyClient) {
        forgetPending(client.connection)
        if connection === client {
            connection = nil
        }
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            finishStart(port: listener?.port?.rawValue)
        case .failed, .cancelled:
            finishStart(port: nil)
        default:
            break
        }
    }

    private func finishStart(port: UInt16?) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        if let port {
            continuation.resume(returning: port)
        } else {
            continuation.resume(throwing: NotifyBridgeError.unavailable)
        }
    }
}

@MainActor
private final class NotifyClient {
    fileprivate let connection: NWConnection
    private unowned let bridge: NotifyBridge
    private let cleanup: (NotifyClient) -> Void
    private var buffer = Data()
    private var authenticated = false
    private var closed = false
    private var timer: Task<Void, Never>?

    init(connection: NWConnection, bridge: NotifyBridge, cleanup: @escaping (NotifyClient) -> Void) {
        self.connection = connection
        self.bridge = bridge
        self.cleanup = cleanup
    }

    func start() {
        connection.start(queue: .main)
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !self.authenticated, !Task.isCancelled else { return }
            self.close()
        }
        receive()
    }

    func sendVisible(_ visible: Bool) {
        guard authenticated, let data = NotifyProtocol.visibleData(visible) else { return }
        connection.send(content: data, completion: .idempotent)
    }

    func close() {
        guard !closed else { return }
        closed = true
        timer?.cancel()
        connection.cancel()
        cleanup(self)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: NotifyProtocol.maxLineBytes) { [weak self] data, _, eof, error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                if let data {
                    self.buffer.append(data)
                    guard self.buffer.count <= NotifyProtocol.maxLineBytes else {
                        self.close()
                        return
                    }
                    self.consume()
                    if self.closed { return }
                }
                if eof || error != nil {
                    self.close()
                } else {
                    self.receive()
                }
            }
        }
    }

    private func consume() {
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard let text = String(data: line, encoding: .utf8), let inbound = NotifyProtocol.parseLine(text) else {
                close()
                return
            }
            if !authenticated {
                guard case .hello(let supplied) = inbound, bridge.authenticate(self, token: supplied) else {
                    close()
                    return
                }
                authenticated = true
                timer?.cancel()
            } else {
                bridge.handle(inbound)
            }
            if closed { return }
        }
    }
}
