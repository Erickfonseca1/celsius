import Foundation

/// A device as returned by `GET devices`.
public struct ThinQDevice: Decodable, Sendable, Equatable, Identifiable {
    public struct Info: Decodable, Sendable, Equatable {
        public var deviceType: String
        public var modelName: String?
        public var alias: String?

        public init(deviceType: String, modelName: String?, alias: String?) {
            self.deviceType = deviceType
            self.modelName = modelName
            self.alias = alias
        }
    }

    public var deviceId: String
    public var deviceInfo: Info

    public var id: String { deviceId }
    public var isAirConditioner: Bool { deviceInfo.deviceType == "DEVICE_AIR_CONDITIONER" }
    public var displayName: String { deviceInfo.alias ?? deviceInfo.modelName ?? "Air conditioner" }

    public init(deviceId: String, deviceInfo: Info) {
        self.deviceId = deviceId
        self.deviceInfo = deviceInfo
    }
}

/// Job modes reported by the API. Unknown values are kept as-is.
public enum ACMode {
    public static let cool = "COOL"
    public static let dry = "AIR_DRY"
    public static let fan = "FAN"
    public static let auto = "AUTO"
    public static let heat = "HEAT"

    /// Modes in which the target temperature can be changed.
    public static func acceptsTargetTemperature(_ mode: String?) -> Bool {
        guard let mode else { return true }
        return mode != fan && mode != dry
    }
}

/// Flattened air conditioner state, parsed from `GET devices/{id}/state`.
public struct ACStatus: Sendable, Equatable {
    public var isOn: Bool
    public var mode: String?
    public var currentTemperature: Double?
    public var targetTemperature: Double?
    public var fanSpeed: String?
    public var swing: Bool?
    public var eco: Bool?
    /// Minutes until the sleep timer turns the unit off; `nil` when the timer is off.
    public var sleepMinutesLeft: Int?
    public var hasError: Bool

    public init(
        isOn: Bool, mode: String? = nil, currentTemperature: Double? = nil,
        targetTemperature: Double? = nil, fanSpeed: String? = nil, swing: Bool? = nil,
        eco: Bool? = nil, sleepMinutesLeft: Int? = nil, hasError: Bool = false
    ) {
        self.isOn = isOn
        self.mode = mode
        self.currentTemperature = currentTemperature
        self.targetTemperature = targetTemperature
        self.fanSpeed = fanSpeed
        self.swing = swing
        self.eco = eco
        self.sleepMinutesLeft = sleepMinutesLeft
        self.hasError = hasError
    }

    public init(json: JSONValue) {
        isOn = json["operation"]?["airConOperationMode"]?.string == "POWER_ON"
        mode = json["airConJobMode"]?["currentJobMode"]?.string

        let celsius = json["temperatureInUnits"]?.array?.first { $0["unit"]?.string == "C" }
        let temperature = json["temperature"]
        let useTemperature = (temperature?["unit"]?.string ?? "C") == "C"
        currentTemperature = (useTemperature ? temperature?["currentTemperature"]?.double : nil)
            ?? celsius?["currentTemperature"]?.double
        targetTemperature = (useTemperature ? temperature?["targetTemperature"]?.double : nil)
            ?? celsius?["targetTemperature"]?.double

        fanSpeed = json["airFlow"]?["windStrength"]?.string
        swing = json["windDirection"]?["rotateUpDown"]?.bool
        eco = json["powerSave"]?["powerSaveEnabled"]?.bool

        let sleep = json["sleepTimer"]
        if sleep?["relativeStopTimer"]?.string == "UNSET" {
            sleepMinutesLeft = nil
        } else {
            let hours = Int(sleep?["relativeHourToStop"]?.double ?? 0)
            let minutes = Int(sleep?["relativeMinuteToStop"]?.double ?? 0)
            sleepMinutesLeft = hours * 60 + minutes > 0 ? hours * 60 + minutes : nil
        }

        hasError = json["runState"]?["currentState"]?.string == "ERROR"
    }

    /// The state the unit is expected to reach once `command` is applied.
    public func applying(_ command: ACCommand) -> ACStatus {
        var copy = self
        switch command {
        case .power(let on): copy.isOn = on
        case .mode(let mode): copy.mode = mode
        case .targetTemperature(let value): copy.targetTemperature = value
        case .fanSpeed(let speed): copy.fanSpeed = speed
        case .swing(let on): copy.swing = on
        case .eco(let on): copy.eco = on
        case .sleep(let hours):
            // The device counts down from the moment it accepts the timer, so a running timer
            // is confirmed by any value within the hour that was requested.
            if hours == 0 {
                copy.sleepMinutesLeft = nil
            } else if let left = sleepMinutesLeft, left > (hours - 1) * 60, left <= hours * 60 {
                copy.sleepMinutesLeft = left
            } else {
                copy.sleepMinutesLeft = hours * 60
            }
        }
        return copy
    }
}

/// What the device supports, parsed from `GET devices/{id}/profile`.
public struct ACCapabilities: Sendable, Equatable {
    public var modes: [String]
    public var fanSpeeds: [String]
    public var minTemperature: Double
    public var maxTemperature: Double
    public var temperatureStep: Double
    public var supportsEco: Bool
    public var supportsSwing: Bool
    public var supportsSleep: Bool

    public static let fallback = ACCapabilities(
        modes: [ACMode.cool, ACMode.dry, ACMode.fan, ACMode.auto],
        fanSpeeds: ["LOW", "MID", "HIGH", "AUTO"],
        minTemperature: 18, maxTemperature: 30, temperatureStep: 1,
        supportsEco: true, supportsSwing: true, supportsSleep: true
    )

    public init(
        modes: [String], fanSpeeds: [String], minTemperature: Double, maxTemperature: Double,
        temperatureStep: Double, supportsEco: Bool, supportsSwing: Bool, supportsSleep: Bool
    ) {
        self.modes = modes
        self.fanSpeeds = fanSpeeds
        self.minTemperature = minTemperature
        self.maxTemperature = maxTemperature
        self.temperatureStep = temperatureStep
        self.supportsEco = supportsEco
        self.supportsSwing = supportsSwing
        self.supportsSleep = supportsSleep
    }

    public init(profile: JSONValue) {
        let property = profile["property"]
        let fallback = ACCapabilities.fallback

        func writable(_ resource: String, _ key: String) -> JSONValue? {
            guard let entry = property?[resource]?[key],
                  entry["mode"]?.array?.contains(.string("w")) == true
            else { return nil }
            return entry
        }

        func writableStrings(_ resource: String, _ key: String) -> [String]? {
            let values = writable(resource, key)?["value"]?["w"]?.array?.compactMap(\.string)
            return values?.isEmpty == false ? values : nil
        }

        modes = writableStrings("airConJobMode", "currentJobMode") ?? fallback.modes
        fanSpeeds = writableStrings("airFlow", "windStrength") ?? fallback.fanSpeeds

        let range = writable("temperature", "targetTemperature")?["value"]?["w"]
        if let min = range?["min"]?.double, let max = range?["max"]?.double, min < max {
            minTemperature = min
            maxTemperature = max
            temperatureStep = range?["step"]?.double.flatMap { $0 > 0 ? $0 : nil } ?? 1
        } else {
            minTemperature = fallback.minTemperature
            maxTemperature = fallback.maxTemperature
            temperatureStep = fallback.temperatureStep
        }

        let hasProfile = property != nil
        supportsEco = hasProfile ? writable("powerSave", "powerSaveEnabled") != nil : fallback.supportsEco
        supportsSwing = hasProfile ? writable("windDirection", "rotateUpDown") != nil : fallback.supportsSwing
        supportsSleep = hasProfile ? writable("sleepTimer", "relativeHourToStop") != nil : fallback.supportsSleep
    }

    /// Clamps and snaps a temperature to the device's range and step.
    public func snap(_ value: Double) -> Double {
        let clamped = min(max(value, minTemperature), maxTemperature)
        let steps = ((clamped - minTemperature) / temperatureStep).rounded()
        return min(minTemperature + steps * temperatureStep, maxTemperature)
    }
}
