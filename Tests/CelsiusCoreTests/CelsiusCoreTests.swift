import Foundation
import Testing
@testable import CelsiusCore

private func fixture(_ name: String) throws -> JSONValue {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
}

private func json(_ data: Data?) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: try #require(data))
}

// MARK: - Parsing real responses

@Suite struct ParsingTests {
    @Test func statusFromRealState() throws {
        let status = ACStatus(json: try #require(try fixture("state")["response"]))
        #expect(status == ACStatus(
            isOn: true, mode: "COOL", currentTemperature: 26, targetTemperature: 18,
            fanSpeed: "HIGH", swing: false, eco: false, sleepMinutesLeft: nil, hasError: false
        ))
    }

    @Test func sleepTimerRunning() {
        let json: JSONValue = ["sleepTimer": ["relativeStopTimer": "SET", "relativeHourToStop": 1, "relativeMinuteToStop": 35]]
        #expect(ACStatus(json: json).sleepMinutesLeft == 95)
    }

    @Test func temperatureFallsBackToCelsiusEntry() {
        let json: JSONValue = [
            "temperatureInUnits": .array([
                ["currentTemperature": 78, "targetTemperature": 64, "unit": "F"],
                ["currentTemperature": 25, "targetTemperature": 21.5, "unit": "C"],
            ]),
        ]
        let status = ACStatus(json: json)
        #expect(status.currentTemperature == 25)
        #expect(status.targetTemperature == 21.5)
    }

    @Test func capabilitiesFromRealProfile() throws {
        let caps = ACCapabilities(profile: try #require(try fixture("profile")["response"]))
        #expect(Set(caps.modes) == ["FAN", "AIR_DRY", "AUTO", "COOL"])
        #expect(!caps.modes.contains("HEAT"))
        #expect(caps.fanSpeeds == ["LOW", "MID", "HIGH", "AUTO"])
        #expect(caps.minTemperature == 18)
        #expect(caps.maxTemperature == 30)
        #expect(caps.temperatureStep == 0.5)
        #expect(caps.supportsEco && caps.supportsSwing && caps.supportsSleep)
    }

    @Test func capabilitiesFallBackWhenProfileIsEmpty() {
        #expect(ACCapabilities(profile: .object([:])) == .fallback)
    }

    @Test func capabilitiesHideMissingFeatures() {
        let profile: JSONValue = ["property": ["airConJobMode": ["currentJobMode": ["mode": .array(["r", "w"]), "value": ["w": .array(["COOL"])]]]]]
        let caps = ACCapabilities(profile: profile)
        #expect(caps.modes == ["COOL"])
        #expect(!caps.supportsEco && !caps.supportsSwing && !caps.supportsSleep)
    }

    @Test func devicesFromRealList() throws {
        let data = try JSONEncoder().encode(try #require(try fixture("devices")["response"]))
        let devices = try JSONDecoder().decode([ThinQDevice].self, from: data)
        #expect(devices.count == 1)
        #expect(devices[0].isAirConditioner)
        #expect(devices[0].displayName == "Ar-condicionado")
    }

    @Test func snapRespectsStepAndRange() {
        let caps = ACCapabilities(
            modes: [], fanSpeeds: [], minTemperature: 18, maxTemperature: 30, temperatureStep: 0.5,
            supportsEco: true, supportsSwing: true, supportsSleep: true
        )
        #expect(caps.snap(23.3) == 23.5)
        #expect(caps.snap(23.2) == 23)
        #expect(caps.snap(10) == 18)
        #expect(caps.snap(31) == 30)
    }

    @Test func limitsNarrowRangeAndDropHalfDegrees() {
        let caps = ACCapabilities.fallback  // 18–30, step 1
        let device = ACCapabilities(
            modes: [], fanSpeeds: [], minTemperature: 18, maxTemperature: 30, temperatureStep: 0.5,
            supportsEco: true, supportsSwing: true, supportsSleep: true
        )
        let limited = device.limited(to: .standard)
        #expect(limited.minTemperature == 18 && limited.maxTemperature == 25)
        #expect(limited.temperatureStep == 1)
        #expect(limited.snap(18.5) == 19)
        #expect(limited.snap(29) == 25)

        let half = device.limited(to: TemperatureLimits(minimum: 18, maximum: 25, halfDegrees: true))
        #expect(half.temperatureStep == 0.5)

        // Limits never go beyond what the device accepts, and a device step of 1 stays 1.
        let wide = caps.limited(to: TemperatureLimits(minimum: 10, maximum: 40, halfDegrees: true))
        #expect(wide.minTemperature == 18 && wide.maxTemperature == 30 && wide.temperatureStep == 1)
    }
}

// MARK: - Command payloads (formats validated against the real unit)

@Suite struct CommandTests {
    @Test(arguments: [
        (ACCommand.power(true), #"{"operation":{"airConOperationMode":"POWER_ON"}}"#),
        (.power(false), #"{"operation":{"airConOperationMode":"POWER_OFF"}}"#),
        (.mode("AIR_DRY"), #"{"airConJobMode":{"currentJobMode":"AIR_DRY"}}"#),
        (.targetTemperature(18), #"{"temperature":{"targetTemperature":18,"unit":"C"}}"#),
        (.targetTemperature(23.5), #"{"temperature":{"targetTemperature":23.5,"unit":"C"}}"#),
        (.fanSpeed("HIGH"), #"{"airFlow":{"windStrength":"HIGH"}}"#),
        (.swing(true), #"{"windDirection":{"rotateUpDown":true}}"#),
        (.eco(false), #"{"powerSave":{"powerSaveEnabled":false}}"#),
        (.sleep(hours: 2), #"{"sleepTimer":{"relativeHourToStop":2,"relativeMinuteToStop":0}}"#),
        (.sleep(hours: 0), #"{"sleepTimer":{"relativeStopTimer":"UNSET"}}"#),
    ])
    func payload(command: ACCommand, expected: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let sortedExpected = try encoder.encode(try JSONDecoder().decode(JSONValue.self, from: Data(expected.utf8)))
        #expect(String(decoding: try encoder.encode(command.payload), as: UTF8.self) == String(decoding: sortedExpected, as: UTF8.self))
    }

    @Test func applyingSleepKeepsRunningCountdown() {
        let status = ACStatus(isOn: true, sleepMinutesLeft: 100)
        #expect(status.applying(.sleep(hours: 2)) == status)
        #expect(status.applying(.sleep(hours: 3)).sleepMinutesLeft == 180)
        #expect(status.applying(.sleep(hours: 0)).sleepMinutesLeft == nil)
    }

    @Test(arguments: [(nil, nil), (1, 1), (60, 1), (61, 2), (95, 2), (120, 2), (121, 3)] as [(Int?, Int?)])
    func sleepTimerHoursRoundsUp(minutesLeft: Int?, hours: Int?) {
        #expect(ACStatus(isOn: true, sleepMinutesLeft: minutesLeft).sleepTimerHours == hours)
    }
}

// MARK: - HTTP client

final class RecordedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var all: [URLRequest] { lock.withLock { storage } }
    func append(_ request: URLRequest) { lock.withLock { storage.append(request) } }
}

private func stubTransport(
    status: Int = 200,
    body: String,
    recorder: RecordedRequests? = nil
) -> ThinQClient.Transport {
    { request in
        recorder?.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

@Suite struct ClientTests {
    @Test func sendsRequiredHeaders() async throws {
        let recorder = RecordedRequests()
        let client = ThinQClient(token: "tok", clientID: "celsius-x", transport: stubTransport(body: #"{"response":{}}"#, recorder: recorder))
        try await client.send(.eco(true), deviceID: "dev1")

        let request = try #require(recorder.all.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api-aic.lgthinq.com/devices/dev1/control")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(request.value(forHTTPHeaderField: "x-country") == "BR")
        #expect(request.value(forHTTPHeaderField: "x-client-id") == "celsius-x")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "v6GFvkweNo7DK7yD3ylIZ9w52aKBU0eJ7wLXkSR3")
        #expect(request.value(forHTTPHeaderField: "x-service-phase") == "OP")
        #expect(request.value(forHTTPHeaderField: "x-conditional-control") == "true")
        #expect(request.value(forHTTPHeaderField: "x-message-id")?.count == 22)
        #expect(try json(request.httpBody) == ACCommand.eco(true).payload)
    }

    @Test func messageIDIsURLSafe() {
        for _ in 0..<50 {
            let id = ThinQClient.messageID()
            #expect(id.count == 22)
            #expect(!id.contains("+") && !id.contains("/") && !id.contains("="))
        }
    }

    @Test func mapsInvalidTokenToUnauthorized() async {
        // Real response for an invalid token.
        let client = ThinQClient(token: "bad", clientID: "c", transport: stubTransport(
            status: 401, body: #"{"messageId":"x","error":{"message":"Not allowed api call","code":"1309"}}"#
        ))
        await #expect(throws: ThinQError.unauthorized) { try await client.devices() }
    }

    @Test func mapsStateRejection() async {
        // Real response for POWER_ON while already on.
        let client = ThinQClient(token: "t", clientID: "c", transport: stubTransport(
            status: 400, body: #"{"messageId":"x","error":{"message":"Command not supported in POWER_ON","code":"2302"}}"#
        ))
        await #expect(throws: ThinQError.rejected("Command not supported in POWER_ON")) {
            try await client.send(.power(true), deviceID: "d")
        }
    }

    @Test func mapsOfflineDevice() async {
        let client = ThinQClient(token: "t", clientID: "c", transport: stubTransport(
            status: 400, body: #"{"error":{"message":"Not connected device","code":"1222"}}"#
        ))
        await #expect(throws: ThinQError.deviceOffline) { try await client.status(deviceID: "d") }
    }
}

// MARK: - Store

final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSinceReferenceDate: 0)
}

@MainActor
@Suite struct StoreTests {
    private func makeStore(state: String, clock: Clock, recorder: RecordedRequests) -> ACStore {
        let devices = #"{"response":[{"deviceId":"d1","deviceInfo":{"deviceType":"DEVICE_AIR_CONDITIONER","alias":"AC"}}]}"#
        let transport: ThinQClient.Transport = { request in
            recorder.append(request)
            let path = request.url!.path
            let body = path.hasSuffix("/devices") ? devices
                : path.hasSuffix("/state") ? #"{"response":\#(state)}"#
                : #"{"response":{}}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        return ACStore(
            settings: InMemorySettings(token: "tok"),
            makeClient: { ThinQClient(token: $0, clientID: $1, transport: transport) },
            now: { clock.now }
        )
    }

    private let offState = #"{"operation":{"airConOperationMode":"POWER_OFF"},"airConJobMode":{"currentJobMode":"COOL"},"temperature":{"currentTemperature":26,"targetTemperature":18,"unit":"C"}}"#

    @Test func temperatureLimitsArePersisted() {
        let settings = InMemorySettings(token: "tok")
        let store = ACStore(settings: settings)
        #expect(store.capabilities.maxTemperature == 25)
        store.temperatureLimits.maximum = 27
        #expect(settings.temperatureLimits.maximum == 27)
        #expect(store.capabilities.maxTemperature == 27)
    }

    @Test func needsSetupWithoutToken() {
        let store = ACStore(settings: InMemorySettings())
        #expect(store.connection == .needsSetup)
    }

    @Test func optimisticOverrideSurvivesStaleServerStateUntilExpiry() async throws {
        let clock = Clock()
        let store = makeStore(state: offState, clock: clock, recorder: RecordedRequests())
        await store.refresh()
        #expect(store.connection == .connected)
        #expect(store.status?.isOn == false)

        store.perform(.power(true))
        #expect(store.status?.isOn == true)
        for _ in 0..<50 where store.isSending {
            try await Task.sleep(for: .milliseconds(10))
        }

        // The cloud still reports "off" a moment later: the UI keeps showing the change.
        clock.now += 2
        await store.refresh()
        #expect(store.status?.isOn == true)

        // Never confirmed: after the lifetime it falls back to the server state.
        clock.now += ACStore.overrideLifetime
        await store.refresh()
        #expect(store.status?.isOn == false)
    }

    @Test func confirmedOverrideIsDropped() async throws {
        let clock = Clock()
        let store = makeStore(state: offState, clock: clock, recorder: RecordedRequests())
        await store.refresh()
        store.perform(.targetTemperature(18))  // Same as the server: nothing to do.
        #expect(store.isSending == false)
    }

    @Test func sendsCommandToDevice() async throws {
        let recorder = RecordedRequests()
        let store = makeStore(state: offState, clock: Clock(), recorder: recorder)
        await store.refresh()
        store.perform(.power(true))
        for _ in 0..<50 where store.isSending {
            try await Task.sleep(for: .milliseconds(10))
        }
        let control = try #require(recorder.all.first { $0.url?.path.hasSuffix("/control") == true })
        #expect(control.url?.path == "/devices/d1/control")
        #expect(try json(control.httpBody) == ACCommand.power(true).payload)
    }
}
