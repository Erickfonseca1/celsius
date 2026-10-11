import AppKit
import SwiftUI

struct PowerButton: View {
    var isOn: Bool
    var accent: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            // Same language as the Eco chip: a tint of the mode color when on, muted when off.
            Image(systemName: "power")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? accent : Theme.secondaryText)
                .frame(width: 30, height: 30)
                .background(Circle().fill(isOn ? accent.opacity(0.14) : Color.white.opacity(0.05)))
                .overlay(Circle().strokeBorder(isOn ? accent.opacity(0.35) : Theme.cardStroke))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.3), value: isOn)
        .accessibilityLabel(isOn ? "Turn off" : "Turn on")
        .help(isOn ? "Turn off" : "Turn on")
    }
}

/// A compact on/off chip: green leaf and tint when on, muted when off.
struct EcoToggle: View {
    var isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "leaf.fill" : "leaf")
                    .contentTransition(.symbolEffect(.replace))
                Text("Eco")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isOn ? Theme.ecoGreen : Theme.secondaryText)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Capsule().fill(isOn ? Theme.ecoGreen.opacity(0.14) : Color.white.opacity(0.05)))
            .overlay(Capsule().strokeBorder(isOn ? Theme.ecoGreen.opacity(0.35) : Theme.cardStroke))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: isOn)
        .accessibilityLabel("Eco Mode")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
        .help(isOn ? "Turn off Eco Mode" : "Turn on Eco Mode")
    }
}

/// One option in a tile's menu.
struct MenuOption {
    var title: String
    var systemImage: String?
    var isSelected: Bool
    var action: () -> Void
}

/// Card with an icon, a caption and the current value. Clicking it opens a menu with the options.
struct ControlTile: View {
    var systemImage: String
    var title: String
    var value: String
    /// A status dot in the corner (e.g. a running timer); `nil` shows none.
    var indicator: Bool? = nil
    var options: [MenuOption]

    var body: some View {
        Button {
            MenuPresenter.show(options)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(systemName: systemImage)
                        .font(.system(size: 19, weight: .regular))
                        .frame(height: 22)
                    Spacer(minLength: 4)
                    if let indicator {
                        Circle()
                            .fill(indicator ? Theme.accent : Color.white.opacity(0.3))
                            .frame(width: 6, height: 6)
                            .padding(.top, 3)
                    }
                }
                Spacer(minLength: 10)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                // The Mac pop-up menu affordance: up/down chevrons right after the value.
                HStack(spacing: 4) {
                    Text(value)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .contentTransition(.interpolate)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                }
                .font(.system(size: 13, weight: .semibold))
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
            .card()
            .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
        .buttonStyle(TilePressStyle())
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityHint("Opens options")
    }
}

struct TilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? 0.04 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Pops up a native menu at the mouse location. SwiftUI's `Menu` flattens custom labels on macOS,
/// so the tiles draw themselves and use this for the options.
@MainActor
enum MenuPresenter {
    private final class Item: NSMenuItem {
        var handler: (() -> Void)?

        @objc func fire() { handler?() }
    }

    static func show(_ options: [MenuOption]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for option in options {
            let item = Item(title: option.title, action: #selector(Item.fire), keyEquivalent: "")
            item.target = item
            item.handler = option.action
            item.state = option.isSelected ? .on : .off
            if let name = option.systemImage {
                item.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            }
            menu.addItem(item)
        }
        menu.appearance = NSAppearance(named: .darkAqua)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}
