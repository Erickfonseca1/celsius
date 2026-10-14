import Foundation
import Testing
@testable import CelsiusCore

/// Vectors produced by msmart-ng, the Python library this protocol is ported from. `state_frame` is a
/// real response from the unit.
private struct Vectors: Decodable {
    struct SetState: Decodable {
        struct Params: Decodable {
            var power_on: Bool
            var target_temperature: Double
            var operational_mode: UInt8
            var fan_speed: UInt8
            var swing_mode: UInt8
            var eco: Bool
            var sleep: Bool?
            var turbo: Bool?
        }
        var params: Params
        var frame: String
    }
    struct Handshake: Decodable {
        var key: String
        var response: String
        var local_key: String
    }
    struct Request: Decodable {
        var packet_id: UInt16
        var data: String
        var packet: String
    }
    var state_frame: String
    var get_state: String
    var set_state: [SetState]
    var v2_packet: String
    var v2_frame: String
    var v3_handshake: Handshake
    var v3_request: Request

    static func load() throws -> Vectors {
        let url = try #require(Bundle.module.url(forResource: "midea-vectors", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }
}

private func bytes(_ hex: String) -> [UInt8] {
    stride(from: 0, to: hex.count, by: 2).map {
        let start = hex.index(hex.startIndex, offsetBy: $0)
        return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
    }
}

private let realConfig = """
{'ip': '192.168.1.20', 'port': 6444, 'id': 123456789012345, 'online': True, 'supported': True, \
'type': <DeviceType.AIR_CONDITIONER: 172>, 'name': 'net_ac_1428', 'sn': '000000P0000000Q1AC0000000000000000', \
'key': '\(String(repeating: "ab", count: 32))', 'token': '\(String(repeating: "cd", count: 64))'}
"""

@Suite struct MideaProtocolTests {
    @Test func getStateMatchesMsmart() throws {
        let vectors = try Vectors.load()
        #expect(MideaFrame.getState(messageID: 0x11) == bytes(vectors.get_state))
    }

    @Test(arguments: 0..<3)
    func setStateMatchesMsmart(index: Int) throws {
        let vector = try Vectors.load().set_state[index]
        var state = MideaState()
        state.isOn = vector.params.power_on
        state.targetTemperature = vector.params.target_temperature
        state.mode = vector.params.operational_mode
        state.fanSpeed = vector.params.fan_speed
        state.swing = vector.params.swing_mode
        state.eco = vector.params.eco
        state.sleepMode = vector.params.sleep ?? false
        state.turbo = vector.params.turbo ?? false
        #expect(state.setCommand(messageID: 0x21) == bytes(vector.frame))
    }

    @Test func parsesRealStateResponse() throws {
        let payload = try MideaFrame.payload(of: bytes(try Vectors.load().state_frame))
        let state = try MideaState(payload: payload)
        #expect(state.isOn == false)
        #expect(state.mode == MideaState.Mode.auto.rawValue)
        #expect(state.targetTemperature == 24)
        #expect(state.fanSpeed == MideaState.Fan.auto)
        #expect(state.swing == 0x0C)
        #expect(state.indoorTemperature == 27.5)
        #expect(state.outdoorTemperature == 31.5)
        #expect(state.eco == false)

        let status = state.status(sleepMinutesLeft: 30)
        #expect(status == ACStatus(
            isOn: false, mode: ACMode.auto, currentTemperature: 27.5, targetTemperature: 24,
            fanSpeed: "AUTO", swing: true, eco: false, sleepMinutesLeft: nil
        ))
    }

    @Test func rejectsCorruptFrames() throws {
        var frame = bytes(try Vectors.load().state_frame)
        frame[12] ^= 0x01
        #expect(throws: MideaError.self) { try MideaFrame.payload(of: frame) }
    }

    @Test func decodesMsmartV2Packet() throws {
        let vectors = try Vectors.load()
        #expect(try MideaPacketV2.decode(bytes(vectors.v2_packet)) == bytes(vectors.v2_frame))
    }

    @Test func v2RoundTrip() throws {
        let frame = MideaFrame.getState(messageID: 7)
        let packet = try MideaPacketV2.encode(deviceID: 123_456_789_012_345, frame: frame)
        #expect(try MideaPacketV2.decode(packet) == frame)
    }

    @Test func sessionKeyFromHandshake() throws {
        let vector = try Vectors.load().v3_handshake
        let key = try MideaPacketV3.sessionKey(cloudKey: bytes(vector.key), response: bytes(vector.response))
        #expect(key == bytes(vector.local_key))
    }

    @Test func tamperedHandshakeIsRejected() throws {
        let vector = try Vectors.load().v3_handshake
        var response = bytes(vector.response)
        response[0] ^= 0xFF
        #expect(throws: MideaError.self) {
            try MideaPacketV3.sessionKey(cloudKey: bytes(vector.key), response: response)
        }
    }

    @Test func encryptedRequestMatchesMsmart() throws {
        let vectors = try Vectors.load()
        let packet = try MideaPacketV3.encryptedRequest(
            packetID: vectors.v3_request.packet_id, data: bytes(vectors.v3_request.data),
            sessionKey: bytes(vectors.v3_handshake.local_key)
        )
        #expect(packet == bytes(vectors.v3_request.packet))
    }

    /// The unit answers with the same framing, so a request decodes like a response once its type is flipped.
    @Test func encryptedPacketRoundTrip() throws {
        let key = bytes(try Vectors.load().v3_handshake.local_key)
        let data = Array(0..<45 as Range<UInt8>)
        var packet = try MideaPacketV3.encryptedRequest(packetID: 9, data: data, sessionKey: key) { Array(repeating: 0xEE, count: $0) }
        packet[5] = packet[5] & 0xF0 | MideaPacketV3.Kind.encryptedResponse.rawValue
        // The signature covers the header, so re-sign after changing the type.
        let decrypted = try MideaCrypto.cbc(encrypt: false, key: key, Array(packet[6..<(packet.count - 32)]))
        packet.replaceSubrange((packet.count - 32)..., with: MideaCrypto.sha256(Array(packet[..<6]) + decrypted))
        #expect(try MideaPacketV3.decode(packet, sessionKey: key) == .data(data))
    }

    @Test func splitsPacketsFromAStream() {
        let first: [UInt8] = [0x83, 0x70, 0x00, 0x02, 0x20, 0x01, 0xAA, 0xBB, 0xCC, 0xDD]
        let second: [UInt8] = [0x83, 0x70, 0x00, 0x00, 0x20, 0x01, 0x01, 0x02]
        var buffer: [UInt8] = [0x00, 0x01] + first + second.prefix(3)
        #expect(MideaPacketV3.nextPacket(from: &buffer) == first)
        #expect(MideaPacketV3.nextPacket(from: &buffer) == nil)
        buffer += second.dropFirst(3)
        #expect(MideaPacketV3.nextPacket(from: &buffer) == second)
        #expect(buffer.isEmpty)
    }

    @Test func crcMatchesKnownValue() {
        // Last two body bytes of msmart's get-state frame: message ID 0x11, then its CRC 0xF4.
        let body: [UInt8] = [0x41, 0x81, 0x00, 0xFF, 0x03, 0xFF, 0x00, 0x02] + Array(repeating: 0, count: 12) + [0x03, 0x11]
        #expect(CRC8.calculate(body) == 0xF4)
    }
}

@Suite struct MideaMappingTests {
    @Test func powerCommand() {
        #expect(MideaState().applying(.power(true)).isOn)
        var on = MideaState()
        on.isOn = true
        #expect(!on.applying(.power(false)).isOn)
    }

    @Test func modeCommandMapsAppModes() {
        var state = MideaState()
        state.mode = MideaState.Mode.cool.rawValue
        state.eco = true
        let dry = state.applying(.mode(ACMode.dry))
        #expect(dry.mode == MideaState.Mode.dry.rawValue)
        #expect(dry.eco == false)
        #expect(state.applying(.mode(ACMode.fan)).mode == MideaState.Mode.fan.rawValue)
        #expect(state.applying(.mode("SOMETHING")).mode == MideaState.Mode.cool.rawValue)
    }

    @Test func swingOnlyTouchesVerticalBits() {
        var state = MideaState()
        state.swing = 0x03
        #expect(state.applying(.swing(true)).swing == 0x0F)
        state.swing = 0x0F
        #expect(state.applying(.swing(false)).swing == 0x03)
    }

    @Test(arguments: [
        (UInt8(102), "AUTO"), (20, "LOW"), (40, "LOW"), (60, "MID"), (80, "HIGH"), (100, "HIGH"),
    ] as [(UInt8, String)])
    func fanNames(raw: UInt8, name: String) {
        #expect(MideaState.fanName(raw) == name)
        if let value = MideaState.fanValue(name) { #expect(MideaState.fanName(value) == name) }
    }

    @Test func everyAppCommandRoundTripsThroughTheUnitState() throws {
        var state = MideaState()
        state.isOn = true
        state.mode = MideaState.Mode.cool.rawValue
        let commands: [ACCommand] = [
            .targetTemperature(21), .fanSpeed("MID"), .swing(true), .eco(true), .mode(ACMode.cool), .power(true),
        ]
        for command in commands {
            let sent = state.applying(command)
            let echoed = try MideaState(payload: Self.stateResponse(for: sent))
            let status = echoed.status(sleepMinutesLeft: nil)
            #expect(status.applying(command) == status, "\(command)")
        }
    }

    /// Builds the state response the unit would send for `state`, by mirroring the set command's bytes.
    private static func stateResponse(for state: MideaState) -> [UInt8] {
        let command = state.setCommand(messageID: 1)
        var payload = [UInt8](repeating: 0, count: 23)
        payload[0] = MideaFrame.stateResponseID
        payload[1] = command[11] & 0x01
        payload[2] = command[12]
        payload[3] = command[13]
        payload[4] = 0x7F; payload[5] = 0x7F
        payload[7] = command[17] & 0x0F
        payload[9] = state.eco ? 0x10 : 0
        payload[11] = 0x69
        payload[12] = 0x6B
        return payload
    }

    @Test func parsesDiscoveryOutputAndJSON() throws {
        let config = try #require(MideaConfig.parse(realConfig))
        #expect(config.host == "192.168.1.20")
        #expect(config.port == 6444)
        #expect(config.deviceID == 123_456_789_012_345)
        #expect(config.tokenBytes?.count == 64)
        #expect(config.keyBytes?.count == 32)
        #expect(MideaConfig.parse(config.encoded) == config)
        #expect(MideaConfig.parse("not a config") == nil)
        #expect(MideaConfig.parse(realConfig.replacingOccurrences(of: "'key': '", with: "'key': 'zz")) == nil)
    }
}

@Suite struct MideaSessionTests {
    @Test func sleepTimerCountsDownAndIsRemembered() async throws {
        let clock = TestClock()
        let store = SleepTimerStore.makeMemory()
        let config = try #require(MideaConfig.parse(realConfig))
        let session = MideaSession(config: config, timerStore: store, now: { clock.now })
        try await session.send(.sleep(hours: 2))
        #expect(await session.sleepMinutesLeft == 120)
        clock.advance(by: 25 * 60)
        #expect(await session.sleepMinutesLeft == 95)
        #expect(store.load() != nil)

        // A new session (app relaunch) picks the saved deadline back up.
        let relaunched = MideaSession(config: config, timerStore: store, now: { clock.now })
        try await relaunched.send(.sleep(hours: 0))
        #expect(await relaunched.sleepMinutesLeft == nil)
        #expect(store.load() == nil)
    }

    @Test func aLongMissedTimerIsDropped() async throws {
        let clock = TestClock()
        let store = SleepTimerStore.makeMemory()
        store.save(clock.now.addingTimeInterval(-3600))
        let config = try #require(MideaConfig.parse(realConfig))
        let session = MideaSession(config: config, timerStore: store, now: { clock.now })
        // Any call restores the timer first; sleep(0) doesn't touch the network.
        try await session.send(.sleep(hours: 0))
        #expect(store.load() == nil)
    }

    @MainActor @Test func unparsableConfigAsksForSetup() async throws {
        let client = MideaClient.factory(defaults: UserDefaults(suiteName: "celsius-tests")!)("garbage", "")
        await #expect(throws: ThinQError.unauthorized) { try await client.devices() }
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSinceReferenceDate: 800_000_000)

    var now: Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current += seconds } }
}

extension SleepTimerStore {
    static func makeMemory() -> SleepTimerStore {
        let box = Box()
        return SleepTimerStore(load: { box.value }, save: { box.value = $0 })
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Date?
        var value: Date? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}

@Suite struct MideaEnergyTests {
    @Test func energyQueryMatchesMsmart() throws {
        let url = try #require(Bundle.module.url(forResource: "midea-vectors", withExtension: "json", subdirectory: "Fixtures"))
        let json = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        let query = try #require(json["get_energy"]?.string)
        #expect(MideaFrame.getEnergy(messageID: 0x11) == bytes(query))

        // A real group 4 response: 605.59 kWh in BCD.
        let frame = try #require(json["energy_frame"]?.string)
        let payload = try MideaFrame.payload(of: bytes(frame))
        #expect(MideaFrame.totalEnergy(payload: payload) == 605.59)
        #expect(MideaFrame.totalEnergy(payload: [0xC0] + Array(repeating: 0, count: 20)) == nil)
    }
}

/// Feeds the estimator the way the unit behaves: a 0.01 kWh counter read every 15 seconds.
private struct Meter {
    var estimator = PowerEstimator()
    var date = Date(timeIntervalSinceReferenceDate: 800_000_000)
    /// Exact energy used so far, in kWh; the unit reports it rounded down to 0.01.
    var energy = 605.5937
    var condition = PowerEstimator.Condition(eco: false, mode: MideaState.Mode.cool.rawValue)
    var isOn = true

    mutating func run(watts: Double, for seconds: TimeInterval, every interval: TimeInterval = 15) -> PowerReading? {
        var reading: PowerReading?
        var elapsed = 0.0
        repeat {
            reading = estimator.record(
                at: date, counter: (energy * 100).rounded(.down) / 100, isOn: isOn, condition: condition
            )
            date += interval
            energy += watts * interval / 3_600_000
            elapsed += interval
        } while elapsed < seconds
        return reading
    }
}

@Suite struct PowerEstimatorTests {
    @Test(arguments: [450.0, 900.0, 250.0])
    func measuresASteadyDraw(watts: Double) throws {
        var meter = Meter()
        let readingReading = meter.run(watts: watts, for: 20 * 60)
        let reading = try #require(readingReading)
        let measured = try #require(reading.watts)
        #expect(reading.isMeasured)
        #expect(abs(measured - watts) / watts < 0.06, "measured \(measured) W for \(watts) W")
    }

    @Test func nothingToShowRightAfterStartingWithoutHistory() throws {
        var meter = Meter()
        let readingReading = meter.run(watts: 450, for: 15)
        let reading = try #require(readingReading)
        #expect(reading.watts == nil)
        #expect(reading.isMeasured == false)
        #expect(reading.restart == .started)
    }

    @Test func ecoStartsTheMeasurementOverAndShowsWhatItLearnedBefore() throws {
        var meter = Meter()
        _ = meter.run(watts: 600, for: 15 * 60)

        meter.condition.eco = true
        let ecoStartReading = meter.run(watts: 350, for: 15)
        let ecoStart = try #require(ecoStartReading)
        #expect(ecoStart.restart == .ecoOn)
        #expect(ecoStart.energy == 0)
        #expect(ecoStart.watts == nil, "no Eco history yet")

        let ecoMeasuredReading = meter.run(watts: 350, for: 25 * 60)

        let ecoMeasured = try #require(ecoMeasuredReading)
        #expect(abs(try #require(ecoMeasured.watts) - 350) < 25)

        // Back to normal: the earlier normal-mode figure shows at once, marked as not measured yet.
        meter.condition.eco = false
        let backReading = meter.run(watts: 600, for: 15)
        let back = try #require(backReading)
        #expect(back.restart == .ecoOff)
        #expect(back.isMeasured == false)
        #expect(abs(try #require(back.watts) - 600) < 40)

        // And Eco again: its own figure, not the blended one.
        meter.condition.eco = true
        let againReading = meter.run(watts: 350, for: 15)
        let again = try #require(againReading)
        #expect(abs(try #require(again.watts) - 350) < 25)
    }

    @Test func modeChangeStartsOver() throws {
        var meter = Meter()
        _ = meter.run(watts: 500, for: 5 * 60)
        meter.condition.mode = MideaState.Mode.fan.rawValue
        let reading = meter.run(watts: 30, for: 15)
        #expect(reading?.restart == .modeChanged)
    }

    @Test func aQuietCounterBringsTheFigureDownQuickly() throws {
        var meter = Meter()
        _ = meter.run(watts: 600, for: 15 * 60)
        // The compressor idles: almost nothing for ten minutes.
        let idleReading = meter.run(watts: 5, for: 10 * 60)
        let idle = try #require(idleReading)
        #expect(try #require(idle.watts) <= 61)
    }

    @Test func countsEnergySinceTheRestart() throws {
        var meter = Meter()
        let readingReading = meter.run(watts: 600, for: 30 * 60)
        let reading = try #require(readingReading)
        // 0.3 kWh in half an hour at 600 W, give or take one counter step.
        #expect(abs(reading.energy - 0.3) <= 0.011)
    }

    @Test func turningOffClearsTheReading() {
        var meter = Meter()
        _ = meter.run(watts: 600, for: 5 * 60)
        meter.isOn = false
        let reading = meter.run(watts: 0, for: 15)
        #expect(reading == nil)
        meter.isOn = true
        let restarted = meter.run(watts: 600, for: 15)
        #expect(restarted?.restart == .started)
    }
}
