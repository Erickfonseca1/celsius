import CelsiusCore
import SwiftUI

struct PopoverView: View {
    var store: ACStore
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
                    EcoToggle(isOn: status?.eco ?? false) {
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
            accent: Theme.modeColor(status?.mode),
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
        VStack(spacing: 10) {
            modePicker
            HStack(spacing: 8) {
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
                        indicator: status?.sleepMinutesLeft != nil,
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
        }
        .disabled(!isOn)
        .opacity(isOn ? 1 : Theme.disabledOpacity)
    }

    /// Few options, switched often: a segmented control instead of a menu.
    private var modePicker: some View {
        Picker("Mode", selection: Binding(
            get: { status?.mode ?? "" },
            set: { store.perform(.mode($0)) }
        )) {
            ForEach(caps.modes, id: \.self) { mode in
                Text(Labels.mode(mode)).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var sleepOptions: [MenuOption] {
        let selected = status?.sleepTimerHours
        let off = MenuOption(title: "Off", isSelected: selected == nil) { store.perform(.sleep(hours: 0)) }
        return [off] + (1...7).map { hours in
            MenuOption(title: "\(hours) h", isSelected: selected == hours) { store.perform(.sleep(hours: hours)) }
        }
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
