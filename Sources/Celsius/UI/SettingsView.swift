import AppKit
import CelsiusCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var store: ACStore
    var canGoBack: Bool
    var onBack: () -> Void

    @State private var token = ""
    @State private var isConnecting = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var configError: String?

    private static let helpPage = URL(string: "https://github.com/mill1000/midea-msmart#discover")!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                if canGoBack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                }
                Text("Settings")
                    .font(.system(size: 15, weight: .semibold))
            }

            section("Midea") {
                VStack(alignment: .leading, spacing: 10) {
                    if let device = store.device, store.hasToken {
                        HStack(spacing: 10) {
                            Image(systemName: "air.conditioner.horizontal")
                                .font(.system(size: 16))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                Text(device.deviceInfo.modelName ?? "")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.secondaryText)
                                    .lineLimit(1)
                            }
                            Spacer()
                            FooterStatus(store: store)
                        }
                    } else {
                        Text("Paste your air conditioner's details (IP, id, token and key) from msmart-ng to connect over your local network.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 8) {
                        SecureField(store.hasToken ? "Replace details" : "{'ip': …, 'id': …, 'token': …, 'key': …}", text: $token)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.3)))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.cardStroke))
                            .onSubmit(connect)
                        Button(action: pasteToken) {
                            Image(systemName: "doc.on.clipboard")
                        }
                        .help("Paste the device details from the clipboard")
                        .accessibilityLabel("Paste device details")
                        .disabled(isConnecting)
                        Button(action: connect) {
                            if isConnecting {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Connect")
                            }
                        }
                        .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)
                    }

                    if let configError {
                        Label(configError, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.warning)
                    } else if case .unauthorized = store.connection {
                        Label("The air conditioner refused this token and key. Get them again and paste them here.", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.warning)
                    }

                    Link(destination: Self.helpPage) {
                        Label("How to get the token and key with msmart-ng", systemImage: "arrow.up.right.square")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(Theme.accent)
                }
            }

            if store.hasToken {
                section("Temperature") {
                    temperatureLimits
                }
            }

            section("General") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(.system(size: 13))
                        .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                    if let loginError {
                        Text(loginError)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.warning)
                    }
                    versionRow
                }
            }

            HStack {
                if store.hasToken {
                    Button("Sign out") {
                        store.signOut()
                    }
                }
                Spacer()
                Button("Quit Celsius") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .font(.system(size: 12))
        }
    }

    /// Minimum and maximum steppers bounded by what the device accepts, plus half degrees when it has them.
    private var temperatureLimits: some View {
        let device = store.deviceCapabilities
        let limits = store.temperatureLimits
        return VStack(alignment: .leading, spacing: 8) {
            limitRow("Minimum", value: $store.temperatureLimits.minimum, in: device.minTemperature, limits.maximum - 1)
            limitRow("Maximum", value: $store.temperatureLimits.maximum, in: limits.minimum + 1, device.maxTemperature)
            if device.temperatureStep < 1 {
                Toggle("Half degrees", isOn: $store.temperatureLimits.halfDegrees)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
        .font(.system(size: 13))
    }

    /// Saved limits can fall outside a different device's range, so the bounds never invert.
    private func limitRow(_ title: String, value: Binding<Double>, in lower: Double, _ upper: Double) -> some View {
        let range = lower...max(lower, upper)
        return HStack {
            Text(title)
            Spacer()
            Text("\(Labels.temperature(value.wrappedValue))°C")
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
            Stepper(title, value: value, in: range, step: 1)
                .labelsHidden()
                .controlSize(.small)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.secondaryText)
            content()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
        }
    }

    /// The running version, with a link to the new release when there is one.
    private var versionRow: some View {
        HStack(spacing: 8) {
            Text("Version \(Self.currentVersion)")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
            Spacer()
            if let update = store.availableUpdate {
                Link(destination: update.url) {
                    Label("Update to \(update.version)", systemImage: "arrow.down.circle")
                        .font(.system(size: 12))
                }
                .foregroundStyle(Theme.accent)
            }
        }
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private func pasteToken() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        token = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func connect() {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !isConnecting else { return }
        guard let config = MideaConfig.parse(value) else {
            configError = "Couldn't find the IP, id, token and key in this text."
            return
        }
        configError = nil
        isConnecting = true
        Task {
            await store.connect(token: config.encoded)
            isConnecting = false
            if store.connection == .connected || store.connection == .deviceError {
                token = ""
                if canGoBack { onBack() }
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "Couldn't change this: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
