import AppKit
import SwiftUI

struct PowerButton: View {
    var isOn: Bool
    var accent: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "power")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isOn ? Color.white : Theme.secondaryText)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.white.opacity(isOn ? 0.14 : 0.06)))
                .overlay(Circle().strokeBorder(isOn ? accent.opacity(0.75) : Color.white.opacity(0.18), lineWidth: 1.2))
                .shadow(color: isOn ? accent.opacity(0.55) : .clear, radius: 8)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.3), value: isOn)
        .accessibilityLabel(isOn ? "Turn off" : "Turn on")
        .help(isOn ? "Turn off" : "Turn on")
    }
}

struct PillToggle: View {
    var isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Capsule()
                .fill(isOn ? Color(red: 0.42, green: 0.78, blue: 0.52) : Color.white.opacity(0.14))
                .frame(width: 44, height: 24)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .padding(3)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isOn)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

struct EcoToggleCard: View {
    var isOn: Bool
    var action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "leaf")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isOn ? Color(red: 0.55, green: 0.85, blue: 0.6) : Theme.secondaryText)
            Text("Eco Mode")
                .font(.system(size: 13, weight: .semibold))
            PillToggle(isOn: isOn, action: action)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardStroke))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Eco Mode")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAction { action() }
    }
}

struct CircleIconButton: View {
    var systemName: String
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .overlay(Circle().strokeBorder(Theme.cardStroke))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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
    var accessory: Accessory = .chevron
    var options: [MenuOption]

    enum Accessory {
        case chevron
        case dot(active: Bool)
    }

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
                    switch accessory {
                    case .chevron:
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.secondaryText)
                    case .dot(let active):
                        Circle()
                            .fill(active ? Color(red: 0.55, green: 0.8, blue: 1) : Color.white.opacity(0.3))
                            .frame(width: 6, height: 6)
                            .padding(.top, 3)
                    }
                }
                Spacer(minLength: 10)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                Text(value)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.interpolate)
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.cardStroke))
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
