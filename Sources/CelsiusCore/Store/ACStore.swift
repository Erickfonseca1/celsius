import Foundation
import Observation

public enum ConnectionState: Equatable, Sendable {
    case needsSetup
    case loading
    case connected
    case offline(String)
    case unauthorized
    case deviceError
}

/// Source of truth for the UI: the last state read from LG's cloud, overlaid with optimistic changes.
///
/// The cloud can take a few seconds to reflect a command, so each change is kept as an override until
/// the server confirms it or it expires. Commands are sent one at a time; a newer command for the same
/// field replaces one that hasn't been sent yet.
@MainActor
@Observable
public final class ACStore {
    public private(set) var serverStatus: ACStatus?
    public private(set) var capabilities: ACCapabilities = .fallback
    public private(set) var connection: ConnectionState = .loading
    public private(set) var device: ThinQDevice?
    public private(set) var isSending = false
    /// A short-lived error to show in the footer, e.g. a rejected command.
    public private(set) var transientMessage: String?
    private var overrides: [ACField: Override] = [:]

    /// Polls faster while the popover is open.
    public var isPopoverVisible = false {
        didSet {
            guard oldValue != isPopoverVisible, isActive else { return }
            startPolling(immediately: isPopoverVisible)
        }
    }

    public static let overrideLifetime: TimeInterval = 8
    public static let visibleInterval: Duration = .seconds(20)
    public static let backgroundInterval: Duration = .seconds(300)
    /// How long the −/+ buttons wait for the value to settle before sending it.
    static let stepDebounce: Duration = .milliseconds(700)
    /// When to read the state back after a command, to confirm it (or recover from a failure).
    static let refreshAfterSend: Duration = .seconds(3)
    static let refreshAfterFailure: Duration = .seconds(1)
    static let messageDuration: Duration = .seconds(4)

    @ObservationIgnored private let settings: SettingsStorage
    @ObservationIgnored private let makeClient: (String, String) -> ThinQClient
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let isPreview: Bool
    @ObservationIgnored private var capabilitiesLoaded = false
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var queue: [ACCommand] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var refreshSoonTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var messageTask: Task<Void, Never>?

    struct Override {
        var command: ACCommand
        var expires: Date
    }

    public init(
        settings: SettingsStorage,
        makeClient: @escaping (String, String) -> ThinQClient = { ThinQClient(token: $0, clientID: $1) },
        now: @escaping () -> Date = Date.init
    ) {
        self.settings = settings
        self.makeClient = makeClient
        self.now = now
        self.isPreview = false
        if settings.token?.isEmpty ?? true { connection = .needsSetup }
    }

    /// A store with fixed data that never touches the network, for snapshots.
    public init(previewStatus: ACStatus?, capabilities: ACCapabilities, connection: ConnectionState = .connected) {
        self.settings = InMemorySettings(token: "preview")
        self.makeClient = { ThinQClient(token: $0, clientID: $1) }
        self.now = Date.init
        self.isPreview = true
        self.serverStatus = previewStatus
        self.capabilities = capabilities
        self.connection = connection
        self.device = ThinQDevice(
            deviceId: "preview",
            deviceInfo: .init(deviceType: "DEVICE_AIR_CONDITIONER", modelName: "RAC_056905_WW", alias: "Ar-condicionado")
        )
    }

    // MARK: State

    /// What the UI shows: server state plus pending changes.
    public var status: ACStatus? {
        guard var status = serverStatus else { return nil }
        let date = now()
        for field in ACField.allCases {
            if let override = overrides[field], override.expires > date {
                status = status.applying(override.command)
            }
        }
        return status
    }

    public var hasToken: Bool { !(settings.token?.isEmpty ?? true) }

    // MARK: Lifecycle

    public func start() {
        isActive = true
        startPolling(immediately: true)
    }

    /// Stops polling, e.g. while the Mac sleeps.
    public func suspend() {
        isActive = false
        pollTask?.cancel()
        pollTask = nil
    }

    private func startPolling(immediately: Bool) {
        guard !isPreview else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var first = immediately
            while !Task.isCancelled {
                guard let self else { return }
                if first {
                    await self.refresh()
                } else {
                    first = true
                }
                let interval = self.isPopoverVisible ? Self.visibleInterval : Self.backgroundInterval
                try? await Task.sleep(for: interval)
            }
        }
    }

    // MARK: Setup

    /// Saves a new token and connects to the first air conditioner on the account.
    public func connect(token: String) async {
        settings.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        forgetDevice()
        connection = .loading
        await refresh()
        if isActive { startPolling(immediately: false) }
    }

    public func signOut() {
        settings.token = nil
        forgetDevice()
        queue = []
        connection = .needsSetup
    }

    private func forgetDevice() {
        settings.deviceID = nil
        device = nil
        serverStatus = nil
        overrides = [:]
        capabilitiesLoaded = false
    }

    // MARK: Refresh

    public func refresh() async {
        guard !isPreview, !isRefreshing else { return }
        guard let token = settings.token, !token.isEmpty else {
            connection = .needsSetup
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        if serverStatus == nil { connection = .loading }

        let client = makeClient(token, settings.clientID)
        do {
            let deviceID = try await resolveDevice(client)
            if !capabilitiesLoaded {
                capabilities = try await client.capabilities(deviceID: deviceID)
                capabilitiesLoaded = true
            }
            let status = try await client.status(deviceID: deviceID)
            serverStatus = status
            pruneOverrides()
            connection = status.hasError ? .deviceError : .connected
        } catch {
            handle(error)
        }
    }

    private func resolveDevice(_ client: ThinQClient) async throws -> String {
        if let device, device.id == settings.deviceID { return device.id }
        let devices = try await client.devices().filter(\.isAirConditioner)
        guard let chosen = devices.first(where: { $0.id == settings.deviceID }) ?? devices.first else {
            throw ThinQError.api(code: "", message: "No air conditioner found on this LG account")
        }
        device = chosen
        settings.deviceID = chosen.id
        capabilitiesLoaded = false
        return chosen.id
    }

    /// Drops overrides the server has confirmed or that have expired.
    private func pruneOverrides() {
        guard let serverStatus else { return }
        let date = now()
        overrides = overrides.filter { _, override in
            override.expires > date && serverStatus.applying(override.command) != serverStatus
        }
    }

    private func scheduleRefresh(after delay: Duration) {
        guard !isPreview else { return }
        refreshSoonTask?.cancel()
        refreshSoonTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    // MARK: Commands

    public func perform(_ command: ACCommand) {
        guard let current = status else { return }
        // Re-sending the current value is wasteful and, for power, rejected by the API.
        if current.applying(command) == current, !queue.contains(where: { $0.field == command.field }) {
            return
        }
        if command.field == .target { debounceTask?.cancel() }
        overrides[command.field] = Override(command: command, expires: now().addingTimeInterval(Self.overrideLifetime))
        enqueue(command)
    }

    /// Updates the target right away and sends it once the value settles (used by the −/+ buttons).
    public func setTargetTemperature(_ value: Double, debounced: Bool) {
        let command = ACCommand.targetTemperature(capabilities.snap(value))
        guard debounced else {
            perform(command)
            return
        }
        overrides[.target] = Override(command: command, expires: now().addingTimeInterval(Self.overrideLifetime + 1))
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.stepDebounce)
            guard !Task.isCancelled, let self else { return }
            self.overrides[.target]?.expires = self.now().addingTimeInterval(Self.overrideLifetime)
            self.enqueue(command)
        }
    }

    private func enqueue(_ command: ACCommand) {
        if let index = queue.firstIndex(where: { $0.field == command.field }) {
            queue[index] = command
        } else {
            queue.append(command)
        }
        guard worker == nil else { return }
        isSending = true
        worker = Task { [weak self] in
            while let self, !self.queue.isEmpty {
                let next = self.queue.removeFirst()
                await self.send(next)
            }
            self?.worker = nil
            self?.isSending = false
        }
    }

    private func send(_ command: ACCommand) async {
        guard !isPreview else { return }
        guard let token = settings.token, let deviceID = device?.id else { return }
        do {
            try await makeClient(token, settings.clientID).send(command, deviceID: deviceID)
            if overrides[command.field]?.command == command {
                overrides[command.field]?.expires = now().addingTimeInterval(Self.overrideLifetime)
            }
            scheduleRefresh(after: Self.refreshAfterSend)
        } catch {
            if overrides[command.field]?.command == command {
                overrides[command.field] = nil
            }
            handle(error)
            scheduleRefresh(after: Self.refreshAfterFailure)
        }
    }

    private func handle(_ error: any Error) {
        if error is CancellationError { return }
        let error = error as? ThinQError ?? .network(error.localizedDescription)
        switch error {
        case .unauthorized:
            connection = .unauthorized
        case .deviceOffline, .network:
            connection = .offline(error.message)
        case .rateLimited, .rejected, .api, .invalidResponse:
            if serverStatus == nil { connection = .offline(error.message) }
            showMessage(error.message)
        }
    }

    private func showMessage(_ message: String) {
        transientMessage = message
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: Self.messageDuration)
            guard !Task.isCancelled else { return }
            self?.transientMessage = nil
        }
    }
}
