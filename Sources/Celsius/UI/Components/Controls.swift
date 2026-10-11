import AppKit
import SwiftUI

/// A Control Center–style row: a round icon that fills with the accent color when on, and a title.
struct CircleToggleRow: View {
    var systemImage: String
    var title: String
    var isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isOn ? Color.white : Color.primary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.12))))
                Text(title)
                    .font(.system(size: 13))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: isOn)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// A full-width row that reads like a menu item, highlighted on hover (e.g. "Settings…").
struct MenuRow: View {
    var title: String
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(isHovered ? 0.1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -6)
        .onHover { isHovered = $0 }
    }
}

/// A native pop-up button that takes the width it's given. SwiftUI's menu `Picker` sizes itself to its
/// longest option, so two of them side by side never line up.
struct PopUpButton<Value: Hashable>: NSViewRepresentable {
    var options: [(title: String, value: Value)]
    @Binding var selection: Value

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let titles = options.map(\.title)
        if button.itemTitles != titles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        }
        button.selectItem(at: options.firstIndex { $0.value == selection } ?? -1)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView button: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? button.intrinsicContentSize.width, height: button.intrinsicContentSize.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: PopUpButton

        init(parent: PopUpButton) { self.parent = parent }

        @objc func changed(_ button: NSPopUpButton) {
            let index = button.indexOfSelectedItem
            guard parent.options.indices.contains(index) else { return }
            parent.selection = parent.options[index].value
        }
    }
}
