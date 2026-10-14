import Foundation

/// How to reach one Midea unit on the local network. The token and key come from the Midea cloud once
/// (e.g. `msmart-ng discover`); after that, everything stays on the LAN.
public struct MideaConfig: Codable, Sendable, Equatable {
    public var host: String
    public var port: UInt16
    public var deviceID: UInt64
    /// Hex strings, as msmart-ng prints them.
    public var token: String
    public var key: String

    public init(host: String, port: UInt16 = 6444, deviceID: UInt64, token: String, key: String) {
        self.host = host
        self.port = port
        self.deviceID = deviceID
        self.token = token
        self.key = key
    }

    var tokenBytes: [UInt8]? { Self.hex(token) }
    var keyBytes: [UInt8]? { Self.hex(key) }

    /// The string kept in the keychain.
    public var encoded: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// Reads a config from the stored JSON, from msmart-ng's discovery output
    /// (`{'ip': '192.168.1.2', 'port': 6444, 'id': 1234, ..., 'token': '…', 'key': '…'}`), or from JSON
    /// with those msmart-ng names.
    public static func parse(_ text: String) -> MideaConfig? {
        if let data = text.data(using: .utf8), let config = try? JSONDecoder().decode(MideaConfig.self, from: data),
           config.isValid {
            return config
        }
        func value(_ name: String) -> String? {
            let pattern = #"["']\#(name)["']\s*:\s*["']?([^"',}\s]+)"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text)
            else { return nil }
            return String(text[range])
        }
        guard let host = value("ip") ?? value("host"),
              let id = (value("id") ?? value("deviceID")).flatMap(UInt64.init),
              let token = value("token"), let key = value("key")
        else { return nil }
        let port = value("port").flatMap(UInt16.init) ?? 6444
        let config = MideaConfig(host: host, port: port, deviceID: id, token: token, key: key)
        return config.isValid ? config : nil
    }

    var isValid: Bool {
        !host.isEmpty && tokenBytes?.count == 64 && keyBytes?.count == 32
    }

    private static func hex(_ string: String) -> [UInt8]? {
        let chars = Array(string.utf8)
        guard chars.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count / 2)
        for index in stride(from: 0, to: chars.count, by: 2) {
            guard let high = nibble(chars[index]), let low = nibble(chars[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
        }
        return bytes
    }

    private static func nibble(_ char: UInt8) -> UInt8? {
        switch char {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): char - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): char - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): char - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

// MARK: - Mapping

extension MideaState {
    /// The Celsius view of this state. Modes and fan speeds use the same strings as the rest of the app.
    func status(sleepMinutesLeft: Int?) -> ACStatus {
        ACStatus(
            isOn: isOn,
            mode: Self.modeName(mode),
            currentTemperature: indoorTemperature,
            targetTemperature: targetTemperature,
            fanSpeed: Self.fanName(fanSpeed),
            swing: swing & Self.verticalSwing != 0,
            eco: eco,
            sleepMinutesLeft: isOn ? sleepMinutesLeft : nil
        )
    }

    /// The state to send for `command`. The sleep timer isn't a device setting, so it changes nothing.
    func applying(_ command: ACCommand) -> MideaState {
        var copy = self
        switch command {
        case .power(let on):
            copy.isOn = on
        case .mode(let name):
            if let mode = Self.modeValue(name) { copy.mode = mode }
            // Eco and turbo only make sense in cool mode; the unit drops them elsewhere anyway.
            if copy.mode != Mode.cool.rawValue {
                copy.eco = false
                copy.turbo = false
            }
        case .targetTemperature(let value):
            copy.targetTemperature = value
        case .fanSpeed(let name):
            copy.fanSpeed = Self.fanValue(name) ?? copy.fanSpeed
        case .swing(let on):
            copy.swing = on ? copy.swing | Self.verticalSwing : copy.swing & ~Self.verticalSwing
        case .eco(let on):
            copy.eco = on
            if on { copy.turbo = false }
        case .sleep:
            break
        }
        return copy
    }

    static func modeName(_ mode: UInt8) -> String {
        switch Mode(rawValue: mode) {
        case .auto: ACMode.auto
        case .cool: ACMode.cool
        case .dry, .smartDry: ACMode.dry
        case .heat: ACMode.heat
        case .fan: ACMode.fan
        case nil: "MODE_\(mode)"
        }
    }

    static func modeValue(_ name: String) -> UInt8? {
        switch name {
        case ACMode.auto: Mode.auto.rawValue
        case ACMode.cool: Mode.cool.rawValue
        case ACMode.dry: Mode.dry.rawValue
        case ACMode.heat: Mode.heat.rawValue
        case ACMode.fan: Mode.fan.rawValue
        default: nil
        }
    }

    /// Speeds are 0–100 or 102 for auto; the unit's three steps are reported as 40, 60 and 80 (or 100).
    static func fanName(_ speed: UInt8) -> String {
        switch speed {
        case Fan.auto, 101...: "AUTO"
        case ...Fan.low: "LOW"
        case ...Fan.medium: "MID"
        default: "HIGH"
        }
    }

    static func fanValue(_ name: String) -> UInt8? {
        switch name {
        case "AUTO": Fan.auto
        case "LOW": Fan.low
        case "MID": Fan.medium
        case "HIGH": Fan.high
        default: nil
        }
    }
}

// MARK: - Client

/// Talks to a Midea / Springer Midea air conditioner directly over the local network.
///
/// This unit ignores LAN timers, so the sleep timer is kept here: the client remembers when to turn
/// the unit off and does it then, even across app restarts (as long as the Mac is awake by then).
public struct MideaClient: ACClient {
    public static let capabilities = ACCapabilities(
        modes: [ACMode.cool, ACMode.dry, ACMode.fan, ACMode.auto],
        fanSpeeds: ["LOW", "MID", "HIGH", "AUTO"],
        minTemperature: 16, maxTemperature: 30, temperatureStep: 0.5,
        supportsEco: true, supportsSwing: true, supportsSleep: true
    )

    let session: MideaSession?

    init(session: MideaSession?) {
        self.session = session
    }

    public func devices() async throws -> [ThinQDevice] {
        let session = try requireSession()
        let config = session.config
        return [ThinQDevice(
            deviceId: String(config.deviceID),
            deviceInfo: .init(deviceType: "DEVICE_AIR_CONDITIONER", modelName: "Midea · \(config.host)", alias: "Air conditioner")
        )]
    }

    public func capabilities(deviceID: String) async throws -> ACCapabilities {
        Self.capabilities
    }

    public func status(deviceID: String) async throws -> ACStatus {
        let session = try requireSession()
        return try await Self.mapErrors { try await session.status() }
    }

    public func send(_ command: ACCommand, deviceID: String) async throws {
        let session = try requireSession()
        try await Self.mapErrors { try await session.send(command) }
    }

    private func requireSession() throws -> MideaSession {
        guard let session else { throw ThinQError.unauthorized }
        return session
    }

    /// Feeds Midea failures into the app's error states: unreachable → offline/reconnecting, refused
    /// token → setup prompt.
    static func mapErrors<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as MideaError {
            switch error {
            case .timeout: throw ThinQError.network("The air conditioner isn't answering")
            case .connection: throw ThinQError.network("Can't reach the air conditioner")
            case .authentication: throw ThinQError.unauthorized
            case .malformed, .crypto: throw ThinQError.invalidResponse
            }
        }
    }

    /// A factory for `ACStore` that keeps one session per stored config, so polling reuses the
    /// connection instead of shaking hands every time.
    @MainActor
    public static func factory(defaults: UserDefaults = .standard) -> (String, String) -> any ACClient {
        var cached: (String, MideaSession)?
        return { stored, _ in
            if let cached, cached.0 == stored { return MideaClient(session: cached.1) }
            guard let config = MideaConfig.parse(stored) else { return MideaClient(session: nil) }
            let session = MideaSession(config: config, timerStore: SleepTimerStore(defaults: defaults, deviceID: config.deviceID))
            cached = (stored, session)
            return MideaClient(session: session)
        }
    }
}

/// Where the sleep timer's deadline is remembered between launches.
struct SleepTimerStore: Sendable {
    var load: @Sendable () -> Date?
    var save: @Sendable (Date?) -> Void

    init(load: @escaping @Sendable () -> Date?, save: @escaping @Sendable (Date?) -> Void) {
        self.load = load
        self.save = save
    }

    init(defaults: UserDefaults, deviceID: UInt64) {
        let key = "midea.sleepDeadline.\(deviceID)"
        nonisolated(unsafe) let defaults = defaults
        self.init(load: { defaults.object(forKey: key) as? Date }, save: { defaults.set($0, forKey: key) })
    }
}

/// The connection plus the state that lives beside it: the last state read (set commands must echo
/// every field) and the app-side sleep timer.
actor MideaSession {
    /// A deadline missed by more than this (the Mac was asleep) is dropped instead of acted on late.
    static let lateTimerGrace: TimeInterval = 15 * 60

    let config: MideaConfig
    private let connection: MideaConnection
    private let timerStore: SleepTimerStore
    private let now: @Sendable () -> Date
    private var lastState: MideaState?
    private var sleepDeadline: Date?
    private var timerTask: Task<Void, Never>?
    private var timerRestored = false

    init(config: MideaConfig, timerStore: SleepTimerStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.config = config
        self.connection = MideaConnection(config: config)
        self.timerStore = timerStore
        self.now = now
    }

    func status() async throws -> ACStatus {
        restoreTimerIfNeeded()
        let state = try await connection.state()
        lastState = state
        if !state.isOn, sleepDeadline != nil { setSleepDeadline(nil) }
        return state.status(sleepMinutesLeft: sleepMinutesLeft)
    }

    func send(_ command: ACCommand) async throws {
        restoreTimerIfNeeded()
        if case .sleep(let hours) = command {
            setSleepDeadline(hours > 0 ? now().addingTimeInterval(Double(hours) * 3600) : nil)
            return
        }
        let current: MideaState
        if let lastState {
            current = lastState
        } else {
            current = try await connection.state()
        }
        lastState = try await connection.apply(current.applying(command))
        if case .power(false) = command { setSleepDeadline(nil) }
    }

    var sleepMinutesLeft: Int? {
        guard let sleepDeadline else { return nil }
        let seconds = sleepDeadline.timeIntervalSince(now())
        return seconds > 0 ? Int((seconds / 60).rounded(.up)) : nil
    }

    // MARK: Sleep timer

    private func restoreTimerIfNeeded() {
        guard !timerRestored else { return }
        timerRestored = true
        guard let saved = timerStore.load() else { return }
        if now().timeIntervalSince(saved) > Self.lateTimerGrace {
            setSleepDeadline(nil)
        } else {
            setSleepDeadline(saved)
        }
    }

    private func setSleepDeadline(_ deadline: Date?) {
        sleepDeadline = deadline
        timerStore.save(deadline)
        timerTask?.cancel()
        timerTask = nil
        guard let deadline else { return }
        let delay = max(0, deadline.timeIntervalSince(now()))
        timerTask = Task { [weak self] in
            // Task.sleep runs on the continuous clock, so time asleep counts toward the timer.
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.sleepTimerFired()
        }
    }

    private func sleepTimerFired() async {
        timerTask = nil
        do {
            try await send(.power(false))
        } catch {
            // Try again shortly; the timer stays set until the unit is off.
            setSleepDeadline(now().addingTimeInterval(60))
        }
    }
}
