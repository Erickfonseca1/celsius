import Foundation

/// What the store needs from an air conditioner backend: the LG ThinQ cloud or a Midea unit on the LAN.
/// Errors are reported as `ThinQError`, which drives the connection state.
public protocol ACClient: Sendable {
    func devices() async throws -> [ThinQDevice]
    func capabilities(deviceID: String) async throws -> ACCapabilities
    func status(deviceID: String) async throws -> ACStatus
    func send(_ command: ACCommand, deviceID: String) async throws
}

extension ThinQClient: ACClient {}
