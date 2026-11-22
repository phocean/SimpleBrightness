import AppKit

/// Menu-bar item and its menu. Rebuilt each time it opens; sliders then follow
/// hardware changes live while it stays open.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    struct Actions {
        var setBrightness: (CGDirectDisplayID, Double) -> Void
        var toggleSync: () -> Void
        var setSyncOffset: (Double) -> Void
        var requestAccessibility: () -> Void
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let displayManager: DisplayManager
    private let controller: BrightnessController?
    private let actions: Actions
    private let keysAuthorized: () -> Bool
    private var sliders: [CGDirectDisplayID: MenuSliderView] = [:]
    private var isOpen = false

    init(displayManager: DisplayManager,
         controller: BrightnessController?,
         keysAuthorized: @escaping () -> Bool,
         actions: Actions) {
        self.displayManager = displayManager
        self.controller = controller
        self.keysAuthorized = keysAuthorized
        self.actions = actions
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "SimpleBrightness")
            button.image?.isTemplate = true
            button.toolTip = "SimpleBrightness"
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    /// Live update for an open menu.
    func brightnessDidChange(_ display: CGDirectDisplayID, _ value: Double) {
        sliders[display]?.update(value: value)
    }

    /// Topology changed (display plugged, unplugged, woken): an open menu is
    /// rebuilt in place so it never shows a display that is gone.
    func displaysDidChange() {
        if isOpen { rebuild() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isOpen = false
        sliders.removeAll()
    }

    private func rebuild() {
        menu.removeAllItems()
        sliders.removeAll()

        menu.addItem(.sectionHeader(title: String(localized: "Displays")))
        if displayManager.displays.isEmpty {
            menu.addItem(disabledItem(String(localized: "No displays detected")))
        }
        for display in displayManager.displays {
            if let controller, display.isSupported, let value = controller.value(of: display.id) {
                let view = MenuSliderView(title: display.name, value: value)
                view.onChange = { [actions] value in actions.setBrightness(display.id, value) }
                let item = NSMenuItem()
                item.view = view
                menu.addItem(item)
                sliders[display.id] = view
            } else {
                menu.addItem(disabledItem(String(localized: "\(display.name) — not supported")))
            }
        }

        menu.addItem(.separator())
        let sync = NSMenuItem(title: String(localized: "Synchronize Brightness"),
                              action: #selector(toggleSync), keyEquivalent: "")
        sync.target = self
        sync.state = (controller?.isSyncEnabled ?? false) ? .on : .off
        sync.isEnabled = controller != nil
        menu.addItem(sync)

        // Offset of external displays, only meaningful while syncing a built-in
        // display with at least one external one.
        if let controller, controller.isSyncEnabled, controller.canUseSyncOffset {
            let view = MenuSliderView(
                title: String(localized: "External Displays Offset"),
                value: controller.syncOffset,
                range: -BrightnessController.maxSyncOffset...BrightnessController.maxSyncOffset,
                step: 0.01,
                centerMark: true,
                format: { $0.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always(includingZero: false))) })
            view.onChange = { [actions] value in actions.setSyncOffset(value) }
            let item = NSMenuItem()
            item.view = view
            item.toolTip = String(localized: "Brightness of external displays relative to the built-in display while synchronized.")
            menu.addItem(item)
        }

        let login = NSMenuItem(title: String(localized: "Open at Login"),
                               action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        if !keysAuthorized() {
            menu.addItem(.separator())
            let warning = NSMenuItem(title: String(localized: "Allow Brightness Keys…"),
                                     action: #selector(requestAccessibility), keyEquivalent: "")
            warning.target = self
            warning.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            warning.toolTip = String(localized: "F1/F2 need the Accessibility permission to control the display under the pointer.")
            menu.addItem(warning)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: String(localized: "Quit SimpleBrightness"),
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func toggleSync() { actions.toggleSync() }

    @objc private func toggleLoginItem() {
        guard let error = LoginItem.setEnabled(!LoginItem.isEnabled) else { return }
        // Shown after the menu has closed; a failure must not look like a silent no-op.
        DispatchQueue.main.async {
            let alert = NSAlert(error: error)
            alert.messageText = String(localized: "Open at Login could not be changed")
            NSApp.activate()
            alert.runModal()
        }
    }

    @objc private func requestAccessibility() { actions.requestAccessibility() }
}
