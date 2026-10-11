import CelsiusCore
import SwiftUI

struct PopoverView: View {
    @Bindable var store: ACStore
    /// Freezes the animation clock, for snapshots.
    var fixedDate: Date?

    @State private var showingSettings = false
    @State private var draggingTarget: Double?

    var body: some View {
        Group {
            if showingSettings || store.connection == .needsSetup {
                SettingsView(store: store, canGoBack: store.connection != .needsSetup) {
                    showingSettings = false
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                controls
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .padding(18)
        .frame(width: Theme.popoverWidth)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .animation(.snappy(duration: 0.3), value: showingSettings)
    }

    // MARK: Main screen

    private var status: ACStatus? { store.status }
    private var isOn: Bool { status?.isOn ?? false }
    private var caps: ACCapabilities { store.capabilities }

    private var controls: some View {
        VStack(spacing: 14) {
            header
            ACUnitView(
                isOn: isOn,
                mode: status?.mode,
                fanSpeed: status?.fanSpeed,
                swing: status?.swing ?? false,
                sleeping: status?.sleepMinutesLeft != nil,
                target: draggingTarget ?? status?.targetTemperature,
                isVisible: store.isPopoverVisible || fixedDate != nil,
                fixedDate: fixedDate
            )
            .padding(.top, -6)
            .padding(.bottom, -26)

            HStack(alignment: .center) {
                bigTemperature
                Spacer()
                if caps.supportsEco {
                    EcoToggleCard(isOn: status?.eco ?? false) {
                        store.perform(.eco(!(status?.eco ?? false)))
                    }
                    .disabled(!isOn)
                    .opacity(isOn ? 1 : Theme.disabledOpacity)
                }
            }

            temperatureSlider
            tiles
            footer
        }
        .redacted(reason: status == nil ? .placeholder : [])
    }

    private var header: some View {
        HStack {
            Image(systemName: "thermometer.medium")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
            Text("Room")
                .foregroundStyle(Theme.secondaryText)
            Text(status?.currentTemperature.map { "\(Labels.temperature($0))°C" } ?? "—")
                .fontWeight(.semibold)
                .contentTransition(.numericText())
            Spacer()
            PowerButton(isOn: isOn, accent: Theme.modeColor(status?.mode)) {
                store.perform(.power(!isOn))
            }
            .disabled(status == nil)
        }
        .font(.system(size: 13))
    }

    private var bigTemperature: some View {
        let value = draggingTarget ?? status?.targetTemperature
        let whole = value.map { String(Int($0.rounded(.down))) } ?? "—"
        let half = value.map { $0.rounded(.down) != $0 } ?? false
        return HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(whole)
                .font(.system(size: 54, weight: .medium))
                .contentTransition(.numericText(value: value ?? 0))
            if half {
                Text(".5")
                    .font(.system(size: 26, weight: .medium))
            }
            Text("°C")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Theme.secondaryText)
        }
        .monospacedDigit()
        .animation(.snappy(duration: 0.25), value: value)
        .opacity(isOn && temperatureEditable ? 1 : 0.55)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Target temperature \(Labels.temperature(value)) degrees")
    }

    private var temperatureEditable: Bool { ACMode.acceptsTargetTemperature(status?.mode) }

    private var temperatureSlider: some View {
        let enabled = isOn && temperatureEditable
        return TemperatureSlider(
            value: status?.targetTemperature ?? caps.minTemperature,
            range: caps.minTemperature...caps.maxTemperature,
            step: caps.temperatureStep,
            onChange: { draggingTarget = $0 },
            onCommit: { value in
                draggingTarget = nil
                store.setTargetTemperature(value, debounced: false)
            },
            onStep: { delta in
                let current = status?.targetTemperature ?? caps.minTemperature
                store.setTargetTemperature(current + delta, debounced: true)
            }
        )
        .disabled(!enabled)
        .opacity(enabled ? 1 : Theme.disabledOpacity)
    }

    private var tiles: some View {
        HStack(spacing: 8) {
            ControlTile(
                systemImage: Labels.modeIcon(status?.mode),
                title: "Mode",
                value: Labels.mode(status?.mode),
                options: caps.modes.map { mode in
                    MenuOption(title: Labels.mode(mode), systemImage: Labels.modeIcon(mode), isSelected: mode == status?.mode) {
                        store.perform(.mode(mode))
                    }
                }
            )
            ControlTile(
                systemImage: "fan",
                title: "Fan speed",
                value: Labels.fan(status?.fanSpeed),
                options: caps.fanSpeeds.map { speed in
                    MenuOption(title: Labels.fan(speed), isSelected: speed == status?.fanSpeed) {
                        store.perform(.fanSpeed(speed))
                    }
                }
            )
            if caps.supportsSleep {
                ControlTile(
                    systemImage: "moon",
                    title: "Sleep",
                    value: Labels.sleep(status?.sleepMinutesLeft),
                    accessory: .dot(active: status?.sleepMinutesLeft != nil),
                    options: sleepOptions
                )
            }
            if caps.supportsSwing {
                ControlTile(
                    systemImage: "wind",
                    title: "Airflow",
                    value: status?.swing == true ? "Swing" : "Fixed",
                    options: [
                        MenuOption(title: "Fixed", isSelected: status?.swing != true) { store.perform(.swing(false)) },
                        MenuOption(title: "Swing", isSelected: status?.swing == true) { store.perform(.swing(true)) },
                    ]
                )
            }
        }
        .disabled(!isOn)
        .opacity(isOn ? 1 : Theme.disabledOpacity)
    }

    private var sleepOptions: [MenuOption] {
        let left = status?.sleepMinutesLeft
        var options = [MenuOption(title: "Off", isSelected: left == nil) { store.perform(.sleep(hours: 0)) }]
        for hours in 1...7 {
            let selected = left.map { $0 > (hours - 1) * 60 && $0 <= hours * 60 } ?? false
            options.append(MenuOption(title: "\(hours) h", isSelected: selected) { store.perform(.sleep(hours: hours)) })
        }
        return options
    }

    private var footer: some View {
        HStack(spacing: 6) {
            FooterStatus(store: store)
            Spacer()
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .help("Settings")
        }
        .padding(.top, 2)
    }
}

struct FooterStatus: View {
    var store: ACStore

    var body: some View {
        let (icon, text, color) = describe()
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 12))
        .animation(.easeInOut(duration: 0.2), value: text)
    }

    private func describe() -> (String, String, Color) {
        if let message = store.transientMessage {
            return ("exclamationmark.triangle", message, .orange)
        }
        switch store.connection {
        case .connected where store.isSending:
            return ("arrow.triangle.2.circlepath", "Updating…", Theme.secondaryText)
        case .connected:
            return ("checkmark.shield", "Connected", Theme.secondaryText)
        case .loading:
            return ("arrow.triangle.2.circlepath", "Connecting…", Theme.secondaryText)
        case .offline(let message):
            return ("wifi.slash", message, .orange)
        case .unauthorized:
            return ("key", "Sign in required", .orange)
        case .deviceError:
            return ("exclamationmark.triangle", "The unit reports an error", .orange)
        case .needsSetup:
            return ("key", "Add your LG token", Theme.secondaryText)
        }
    }
}
