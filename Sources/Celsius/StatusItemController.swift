import AppKit
import CelsiusCore
import SwiftUI

/// Menu bar item showing the room temperature, with the controls in a popover.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let store: ACStore

    init(store: ACStore) {
        self.store = store
        super.init()

        let hosting = NSHostingController(rootView: PopoverView(store: store))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageLeading
        }
        observeStore()
    }

    @objc func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidShow(_ notification: Notification) {
        store.isPopoverVisible = true
    }

    func popoverDidClose(_ notification: Notification) {
        store.isPopoverVisible = false
    }

    // MARK: Menu bar label

    private func observeStore() {
        withObservationTracking {
            updateButton()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStore() }
        }
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let status = store.status
        let isOn = status?.isOn ?? false
        let symbol = isOn ? "air.conditioner.horizontal.fill" : "air.conditioner.horizontal"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Celsius")
            ?? NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Celsius")
        image?.isTemplate = true
        button.image = image?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))

        if let room = status?.currentTemperature {
            button.title = " \(Labels.temperature(room))°"
        } else {
            button.title = ""
        }
        button.appearsDisabled = !isOn && status != nil
        button.toolTip = status.map { status in
            status.isOn
                ? "On · \(Labels.mode(status.mode)) · set to \(Labels.temperature(status.targetTemperature))°C"
                : "Off"
        }
    }
}
