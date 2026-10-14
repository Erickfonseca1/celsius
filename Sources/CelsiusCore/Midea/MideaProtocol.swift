import Foundation

// The Midea LAN protocol, ported from msmart-ng (https://github.com/mill1000/midea-msmart).
//
// Three layers, outermost first:
// - V3 packet (`0x8370`): AES-CBC under a session key agreed in a token handshake, SHA-256 signed.
// - V2 packet (`0x5A5A`): AES-ECB under a fixed key, MD5 signed. Carries one frame.
// - Frame (`0xAA`): the appliance command or response, with a checksum.

/// Builds and reads `0xAA` frames for an air conditioner (device type `0xAC`).
enum MideaFrame {
    static let deviceType: UInt8 = 0xAC
    static let controlType: UInt8 = 0x02
    static let queryType: UInt8 = 0x03
    static let headerLength = 10
    /// First payload byte of a state response.
    static let stateResponseID: UInt8 = 0xC0

    static func checksum(_ bytes: some Sequence<UInt8>) -> UInt8 {
        let sum = bytes.reduce(0) { $0 &+ Int($1) }
        return UInt8(truncatingIfNeeded: 0 &- sum)
    }

    /// A command frame: the body, a message ID and a CRC-8 of both, behind a 10-byte header.
    static func command(_ body: [UInt8], type: UInt8, messageID: UInt8) -> [UInt8] {
        var payload = body + [messageID]
        payload.append(CRC8.calculate(payload))
        var frame = [UInt8](repeating: 0, count: headerLength)
        frame[0] = 0xAA
        frame[1] = UInt8(truncatingIfNeeded: payload.count + headerLength)
        frame[2] = deviceType
        frame[9] = type
        frame += payload
        frame.append(checksum(frame[1...]))
        return frame
    }

    static func getState(messageID: UInt8) -> [UInt8] {
        let body: [UInt8] = [0x41, 0x81, 0x00, 0xFF, 0x03, 0xFF, 0x00, 0x02]
            + [UInt8](repeating: 0, count: 12) + [0x03]
        return command(body, type: queryType, messageID: messageID)
    }

    /// The response payload (from the response ID up to, not including, the CRC), after checking the
    /// frame checksum and the payload's CRC (some units use a second checksum instead).
    static func payload(of frame: [UInt8]) throws -> [UInt8] {
        guard frame.count > headerLength + 2, frame[0] == 0xAA else {
            throw MideaError.malformed("Frame too short")
        }
        guard checksum(frame[1..<(frame.count - 1)]) == frame[frame.count - 1] else {
            throw MideaError.malformed("Frame checksum mismatch")
        }
        guard frame[2] == deviceType else { throw MideaError.malformed("Not an air conditioner frame") }
        let body = Array(frame[headerLength..<(frame.count - 1)])
        let check = body[body.count - 1]
        let content = body.dropLast()
        guard CRC8.calculate(content) == check || checksum(content) == check else {
            throw MideaError.malformed("Payload CRC mismatch")
        }
        return Array(content)
    }
}

/// The air conditioner's state as the unit reports it, with every field a set command must echo back.
struct MideaState: Equatable, Sendable {
    enum Mode: UInt8 { case auto = 1, cool, dry, heat, fan, smartDry }
    enum Fan {
        static let auto: UInt8 = 102
        static let high: UInt8 = 80
        static let medium: UInt8 = 60
        static let low: UInt8 = 40
    }
    /// Swing bits: vertical (up/down) is `0xC`, horizontal (left/right) is `0x3`.
    static let verticalSwing: UInt8 = 0x0C

    var isOn = false
    var targetTemperature = 24.0
    var mode: UInt8 = Mode.auto.rawValue
    var fanSpeed: UInt8 = Fan.auto
    var swing: UInt8 = 0
    var turbo = false
    var eco = false
    var sleepMode = false
    var fahrenheit = false
    var followMe = false
    var purifier = false
    var auxHeat = false
    var independentAuxHeat = false
    var freezeProtection = false
    var targetHumidity: UInt8 = 40
    var indoorTemperature: Double?
    var outdoorTemperature: Double?
    var errorCode: UInt8 = 0

    init() {}

    /// Parses the payload of a `0xC0` state response.
    init(payload p: [UInt8]) throws {
        guard p.count >= 17, p[0] == MideaFrame.stateResponseID else {
            throw MideaError.malformed("Not a state response")
        }
        isOn = p[1] & 0x01 != 0
        targetTemperature = Double(p[2] & 0x0F) + 16 + (p[2] & 0x10 != 0 ? 0.5 : 0)
        mode = (p[2] >> 5) & 0x07
        fanSpeed = p[3] & 0x7F
        swing = p[7] & 0x0F
        turbo = p[8] & 0x20 != 0 || p[10] & 0x02 != 0
        independentAuxHeat = p[8] & 0x40 != 0
        followMe = p[8] & 0x80 != 0
        eco = p[9] & 0x10 != 0
        purifier = p[9] & 0x20 != 0
        auxHeat = p[9] & 0x08 != 0
        sleepMode = p[10] & 0x01 != 0
        fahrenheit = p[10] & 0x04 != 0
        indoorTemperature = Self.temperature(p[11], decimals: Double(p[15] & 0x0F) / 10, fahrenheit: fahrenheit)
        outdoorTemperature = Self.temperature(p[12], decimals: Double(p[15] >> 4) / 10, fahrenheit: fahrenheit)
        let alternateTarget = p[13] & 0x1F
        if alternateTarget != 0 {
            targetTemperature = Double(alternateTarget) + 12 + (p[2] & 0x10 != 0 ? 0.5 : 0)
        }
        errorCode = p[16]
        if p.count >= 20 { targetHumidity = p[19] & 0x7F }
        if p.count >= 22 { freezeProtection = p[21] & 0x80 != 0 }
    }

    /// Temperatures are sent as `value * 2 + 50`, with an optional extra decimal digit.
    static func temperature(_ raw: UInt8, decimals: Double, fahrenheit: Bool) -> Double? {
        guard raw != 0xFF else { return nil }
        let value = (Double(raw) - 50) / 2
        let whole = value.rounded(.towardZero)
        if !fahrenheit, decimals != 0 { return whole + (value >= 0 ? decimals : -decimals) }
        if decimals >= 0.5 { return whole + (value >= 0 ? 0.5 : -0.5) }
        return value
    }

    /// The `0x40` set command that puts the unit in this state. Timers are left off (`0x7F`): this
    /// unit ignores LAN timers, so the sleep timer is kept by the app.
    func setCommand(messageID: UInt8, beep: Bool = true) -> [UInt8] {
        let whole = Int(targetTemperature.rounded(.down))
        let half = targetTemperature - Double(whole) > 0
        var temperature: UInt8 = 0
        var alternate: UInt8 = 0
        if (17...30).contains(whole) {
            temperature = UInt8(whole - 16) & 0x0F
        } else {
            alternate = UInt8(clamping: whole - 12) & 0x1F
        }
        if half { temperature |= 0x10 }

        let body: [UInt8] = [
            0x40,
            0x02 | (beep ? 0x40 : 0) | (isOn ? 0x01 : 0),
            temperature | ((mode & 0x07) << 5),
            fanSpeed,
            0x7F, 0x7F, 0x00,
            0x30 | (swing & 0x3F),
            (followMe ? 0x80 : 0) | (turbo ? 0x20 : 0),
            (eco ? 0x80 : 0) | (purifier ? 0x20 : 0) | (auxHeat ? 0x08 : 0),
            (sleepMode ? 0x01 : 0) | (turbo ? 0x02 : 0) | (fahrenheit ? 0x04 : 0),
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            alternate,
            targetHumidity & 0x7F,
            0x00,
            freezeProtection ? 0x80 : 0,
            independentAuxHeat ? 0x08 : 0,
            0x00,
        ]
        return MideaFrame.command(body, type: MideaFrame.controlType, messageID: messageID)
    }
}

/// The inner `0x5A5A` packet that carries one frame.
enum MideaPacketV2 {
    static func encode(deviceID: UInt64, frame: [UInt8], date: Date = Date()) throws -> [UInt8] {
        let encrypted = try MideaCrypto.ecb(encrypt: true, frame)
        let length = 40 + encrypted.count + 16
        var packet: [UInt8] = [0x5A, 0x5A, 0x01, 0x11]
        packet += littleEndian(UInt64(length), count: 2)
        packet += [0x20, 0x00]
        packet += [0, 0, 0, 0]
        packet += timestamp(date)
        packet += littleEndian(deviceID, count: 8)
        packet += [UInt8](repeating: 0, count: 12)
        packet += encrypted
        return packet + MideaCrypto.md5(packet + MideaCrypto.signKey)
    }

    static func decode(_ packet: [UInt8]) throws -> [UInt8] {
        guard packet.count >= 6, packet[0] == 0x5A, packet[1] == 0x5A else {
            throw MideaError.malformed("Not a V2 packet")
        }
        let length = Int(packet[4]) | Int(packet[5]) << 8
        guard length >= 56, packet.count >= length else { throw MideaError.malformed("V2 packet truncated") }
        let body = Array(packet[..<(length - 16)])
        guard MideaCrypto.md5(body + MideaCrypto.signKey) == Array(packet[(length - 16)..<length]) else {
            throw MideaError.malformed("V2 signature mismatch")
        }
        return try MideaCrypto.ecb(encrypt: false, Array(body[40...]))
    }

    /// Two digits per byte, least significant first: hundredths, seconds, minutes, hours, day, month, year.
    static func timestamp(_ date: Date) -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let year = c.year ?? 2000
        return [
            UInt8((c.nanosecond ?? 0) / 10_000_000), UInt8(c.second ?? 0), UInt8(c.minute ?? 0),
            UInt8(c.hour ?? 0), UInt8(c.day ?? 1), UInt8(c.month ?? 1), UInt8(year % 100), UInt8(year / 100),
        ]
    }

    static func littleEndian(_ value: UInt64, count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
    }
}

/// The outer `0x8370` packet of protocol V3.
enum MideaPacketV3 {
    enum Kind: UInt8 {
        case handshakeRequest = 0x0, handshakeResponse = 0x1
        case encryptedResponse = 0x3, encryptedRequest = 0x6, error = 0xF
    }

    static func handshakeRequest(packetID: UInt16, token: [UInt8]) -> [UInt8] {
        header(length: token.count, typeByte: Kind.handshakeRequest.rawValue) + bigEndian(packetID) + token
    }

    /// The session key: the handshake response decrypted with the cloud key, XORed with that key.
    static func sessionKey(cloudKey: [UInt8], response: [UInt8]) throws -> [UInt8] {
        guard response.count == 64 else { throw MideaError.authentication("Unexpected handshake length") }
        let decrypted = try MideaCrypto.cbc(encrypt: false, key: cloudKey, Array(response[..<32]))
        guard MideaCrypto.sha256(decrypted) == Array(response[32...]) else {
            throw MideaError.authentication("Handshake signature mismatch")
        }
        return zip(decrypted, cloudKey).map { $0 ^ $1 }
    }

    /// `random` supplies the padding bytes; tests pass a fixed source.
    static func encryptedRequest(
        packetID: UInt16, data: [UInt8], sessionKey: [UInt8],
        random: (Int) -> [UInt8] = { (0..<$0).map { _ in UInt8.random(in: 0...255) } }
    ) throws -> [UInt8] {
        let remainder = (data.count + 2) % 16
        let pad = remainder == 0 ? 0 : 16 - remainder
        let head = header(length: data.count + pad + 32, typeByte: UInt8(pad) << 4 | Kind.encryptedRequest.rawValue)
        let payload = bigEndian(packetID) + data + random(pad)
        let hash = MideaCrypto.sha256(head + payload)
        return head + (try MideaCrypto.cbc(encrypt: true, key: sessionKey, payload)) + hash
    }

    /// Removes and returns the first complete packet in `buffer`, dropping any bytes before it.
    static func nextPacket(from buffer: inout [UInt8]) -> [UInt8]? {
        guard let start = buffer.indices.dropLast().first(where: { buffer[$0] == 0x83 && buffer[$0 + 1] == 0x70 }) else {
            if buffer.last != 0x83 { buffer.removeAll() }
            return nil
        }
        if start > 0 { buffer.removeFirst(start) }
        guard buffer.count >= 6 else { return nil }
        let total = (Int(buffer[2]) << 8 | Int(buffer[3])) + 8
        guard buffer.count >= total else { return nil }
        let packet = Array(buffer[..<total])
        buffer.removeFirst(total)
        return packet
    }

    enum Message: Equatable {
        case handshake([UInt8])
        case data([UInt8])
    }

    static func decode(_ packet: [UInt8], sessionKey: [UInt8]?) throws -> Message {
        guard packet.count >= 8, packet[0] == 0x83, packet[1] == 0x70, packet[4] == 0x20 else {
            throw MideaError.malformed("Not a V3 packet")
        }
        switch Kind(rawValue: packet[5] & 0x0F) {
        case .handshakeResponse:
            return .handshake(Array(packet[8...]))
        case .encryptedResponse:
            guard let sessionKey, packet.count >= 6 + 32 + 16 else {
                throw MideaError.malformed("Encrypted packet without a session")
            }
            let head = Array(packet[..<6])
            let decrypted = try MideaCrypto.cbc(encrypt: false, key: sessionKey, Array(packet[6..<(packet.count - 32)]))
            guard MideaCrypto.sha256(head + decrypted) == Array(packet[(packet.count - 32)...]) else {
                throw MideaError.malformed("V3 signature mismatch")
            }
            let pad = Int(packet[5] >> 4)
            guard decrypted.count >= 2 + pad else { throw MideaError.malformed("V3 payload too short") }
            return .data(Array(decrypted[2..<(decrypted.count - pad)]))
        case .error:
            throw MideaError.authentication("The unit answered with an error packet")
        default:
            throw MideaError.malformed("Unexpected V3 packet type")
        }
    }

    private static func header(length: Int, typeByte: UInt8) -> [UInt8] {
        [0x83, 0x70] + bigEndian(UInt16(length)) + [0x20, typeByte]
    }

    private static func bigEndian(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }
}

/// CRC-8/854 used inside Midea frames.
enum CRC8 {
    static func calculate(_ bytes: some Sequence<UInt8>) -> UInt8 {
        bytes.reduce(0) { table[Int($0 ^ $1)] }
    }

    private static let table: [UInt8] = [
        0x00, 0x5E, 0xBC, 0xE2, 0x61, 0x3F, 0xDD, 0x83, 0xC2, 0x9C, 0x7E, 0x20, 0xA3, 0xFD, 0x1F, 0x41,
        0x9D, 0xC3, 0x21, 0x7F, 0xFC, 0xA2, 0x40, 0x1E, 0x5F, 0x01, 0xE3, 0xBD, 0x3E, 0x60, 0x82, 0xDC,
        0x23, 0x7D, 0x9F, 0xC1, 0x42, 0x1C, 0xFE, 0xA0, 0xE1, 0xBF, 0x5D, 0x03, 0x80, 0xDE, 0x3C, 0x62,
        0xBE, 0xE0, 0x02, 0x5C, 0xDF, 0x81, 0x63, 0x3D, 0x7C, 0x22, 0xC0, 0x9E, 0x1D, 0x43, 0xA1, 0xFF,
        0x46, 0x18, 0xFA, 0xA4, 0x27, 0x79, 0x9B, 0xC5, 0x84, 0xDA, 0x38, 0x66, 0xE5, 0xBB, 0x59, 0x07,
        0xDB, 0x85, 0x67, 0x39, 0xBA, 0xE4, 0x06, 0x58, 0x19, 0x47, 0xA5, 0xFB, 0x78, 0x26, 0xC4, 0x9A,
        0x65, 0x3B, 0xD9, 0x87, 0x04, 0x5A, 0xB8, 0xE6, 0xA7, 0xF9, 0x1B, 0x45, 0xC6, 0x98, 0x7A, 0x24,
        0xF8, 0xA6, 0x44, 0x1A, 0x99, 0xC7, 0x25, 0x7B, 0x3A, 0x64, 0x86, 0xD8, 0x5B, 0x05, 0xE7, 0xB9,
        0x8C, 0xD2, 0x30, 0x6E, 0xED, 0xB3, 0x51, 0x0F, 0x4E, 0x10, 0xF2, 0xAC, 0x2F, 0x71, 0x93, 0xCD,
        0x11, 0x4F, 0xAD, 0xF3, 0x70, 0x2E, 0xCC, 0x92, 0xD3, 0x8D, 0x6F, 0x31, 0xB2, 0xEC, 0x0E, 0x50,
        0xAF, 0xF1, 0x13, 0x4D, 0xCE, 0x90, 0x72, 0x2C, 0x6D, 0x33, 0xD1, 0x8F, 0x0C, 0x52, 0xB0, 0xEE,
        0x32, 0x6C, 0x8E, 0xD0, 0x53, 0x0D, 0xEF, 0xB1, 0xF0, 0xAE, 0x4C, 0x12, 0x91, 0xCF, 0x2D, 0x73,
        0xCA, 0x94, 0x76, 0x28, 0xAB, 0xF5, 0x17, 0x49, 0x08, 0x56, 0xB4, 0xEA, 0x69, 0x37, 0xD5, 0x8B,
        0x57, 0x09, 0xEB, 0xB5, 0x36, 0x68, 0x8A, 0xD4, 0x95, 0xCB, 0x29, 0x77, 0xF4, 0xAA, 0x48, 0x16,
        0xE9, 0xB7, 0x55, 0x0B, 0x88, 0xD6, 0x34, 0x6A, 0x2B, 0x75, 0x97, 0xC9, 0x4A, 0x14, 0xF6, 0xA8,
        0x74, 0x2A, 0xC8, 0x96, 0x15, 0x4B, 0xA9, 0xF7, 0xB6, 0xE8, 0x0A, 0x54, 0xD7, 0x89, 0x6B, 0x35,
    ]
}
