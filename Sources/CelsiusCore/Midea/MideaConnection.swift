import Foundation
import Network
import os
import Synchronization

/// One TCP session with a Midea unit over protocol V3: connect, run the token handshake, then send
/// frames and wait for the state response. Any failure tears the session down; the next exchange
/// reconnects, and a failed exchange is tried once more on a fresh session.
actor MideaConnection {
    static let port: UInt16 = 6444
    static let connectTimeout: Duration = .seconds(5)
    static let readTimeout: Duration = .seconds(4)
    /// The unit needs a moment after the handshake before it answers commands.
    static let settleAfterHandshake: Duration = .milliseconds(800)
    /// Sessions are renewed before the unit expires them (12 h).
    static let sessionLifetime: TimeInterval = 11 * 60 * 60

    private static let log = Logger(subsystem: "com.erickfonseca.celsius", category: "midea")

    let config: MideaConfig
    private let queue = DispatchQueue(label: "celsius.midea.connection")
    private var connection: NWConnection?
    private var buffer: [UInt8] = []
    private var sessionKey: [UInt8]?
    private var sessionStart: Date?
    private var packetID: UInt16 = 0
    private var messageID: UInt8 = 0

    init(config: MideaConfig) {
        self.config = config
    }

    /// Reads the current state.
    func state() async throws -> MideaState {
        try await exchange { Self.nextFrame(&$0, MideaFrame.getState) }
    }

    /// Sends a set command for `state` and returns the state the unit reports back.
    func apply(_ state: MideaState) async throws -> MideaState {
        try await exchange { Self.nextFrame(&$0) { state.setCommand(messageID: $0) } }
    }

    private static func nextFrame(_ id: inout UInt8, _ make: (UInt8) -> [UInt8]) -> [UInt8] {
        id = id &+ 1
        return make(id)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        sessionKey = nil
        sessionStart = nil
        buffer = []
    }

    // MARK: Exchange

    private func exchange(_ makeFrame: (inout UInt8) -> [UInt8]) async throws -> MideaState {
        do {
            return try await exchangeOnce(makeFrame(&messageID))
        } catch let error as MideaError where error != .crypto {
            if case .authentication = error { throw error }
            Self.log.info("Exchange failed (\(String(describing: error), privacy: .public)), reconnecting")
            disconnect()
            return try await exchangeOnce(makeFrame(&messageID))
        }
    }

    private func exchangeOnce(_ frame: [UInt8]) async throws -> MideaState {
        do {
            try await ensureSession()
            guard let sessionKey else { throw MideaError.connection("No session") }
            let inner = try MideaPacketV2.encode(deviceID: config.deviceID, frame: frame)
            try await write(try MideaPacketV3.encryptedRequest(packetID: nextPacketID(), data: inner, sessionKey: sessionKey))
            let deadline = ContinuousClock.now + Self.readTimeout
            while true {
                guard case .data(let packet) = try await readPacket(until: deadline) else { continue }
                let payload = try MideaFrame.payload(of: try MideaPacketV2.decode(packet))
                // Units also send unsolicited reports; wait for the state response.
                if payload.first == MideaFrame.stateResponseID { return try MideaState(payload: payload) }
            }
        } catch {
            disconnect()
            throw error
        }
    }

    private func nextPacketID() -> UInt16 {
        defer { packetID = (packetID + 1) & 0x0FFF }
        return packetID
    }

    // MARK: Session

    private func ensureSession() async throws {
        if let sessionStart, connection != nil, sessionKey != nil,
           Date().timeIntervalSince(sessionStart) < Self.sessionLifetime {
            return
        }
        disconnect()
        try await open()
        guard let token = config.tokenBytes, let key = config.keyBytes else {
            throw MideaError.authentication("Token or key is not valid hex")
        }
        try await write(MideaPacketV3.handshakeRequest(packetID: nextPacketID(), token: token))
        guard case .handshake(let response) = try await readPacket(until: .now + Self.readTimeout) else {
            throw MideaError.authentication("No handshake response")
        }
        sessionKey = try MideaPacketV3.sessionKey(cloudKey: key, response: response)
        sessionStart = Date()
        try await Task.sleep(for: Self.settleAfterHandshake)
    }

    private func open() async throws {
        guard let port = NWEndpoint.Port(rawValue: config.port) else { throw MideaError.connection("Invalid port") }
        let connection = NWConnection(host: NWEndpoint.Host(config.host), port: port, using: .tcp)
        self.connection = connection
        let once = Once<Void>()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            once.set(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(.success(()))
                case .failed(let error), .waiting(let error):
                    once.resume(.failure(MideaError.connection(error.localizedDescription)))
                case .cancelled: once.resume(.failure(MideaError.connection("Connection cancelled")))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + Self.seconds(Self.connectTimeout)) {
                once.resume(.failure(MideaError.timeout))
            }
        }
    }

    // MARK: I/O

    private func write(_ bytes: [UInt8]) async throws {
        guard let connection else { throw MideaError.connection("Not connected") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: MideaError.connection(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func readPacket(until deadline: ContinuousClock.Instant) async throws -> MideaPacketV3.Message {
        while true {
            if let packet = MideaPacketV3.nextPacket(from: &buffer) {
                return try MideaPacketV3.decode(packet, sessionKey: sessionKey)
            }
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw MideaError.timeout }
            buffer += try await receive(timeout: remaining)
        }
    }

    /// A pending receive can't be cancelled on its own, so a timeout ends the session.
    private func receive(timeout: Duration) async throws -> [UInt8] {
        guard let connection else { throw MideaError.connection("Not connected") }
        let once = Once<[UInt8]>()
        return try await withCheckedThrowingContinuation { continuation in
            once.set(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    once.resume(.failure(MideaError.connection(error.localizedDescription)))
                } else if let data, !data.isEmpty {
                    once.resume(.success([UInt8](data)))
                } else if isComplete {
                    once.resume(.failure(MideaError.connection("The unit closed the connection")))
                } else {
                    once.resume(.success([]))
                }
            }
            queue.asyncAfter(deadline: .now() + Self.seconds(timeout)) {
                once.resume(.failure(MideaError.timeout))
            }
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// Resumes a continuation exactly once, whichever callback (result or timeout) comes first.
private final class Once<T: Sendable>: Sendable {
    private let state = Mutex<CheckedContinuation<T, any Error>?>(nil)

    func set(_ continuation: CheckedContinuation<T, any Error>) {
        state.withLock { $0 = continuation }
    }

    func resume(_ result: Result<T, any Error>) {
        let continuation = state.withLock { value -> CheckedContinuation<T, any Error>? in
            defer { value = nil }
            return value
        }
        continuation?.resume(with: result)
    }
}
