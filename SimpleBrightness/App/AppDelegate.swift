import AppKit
import ApplicationServices

/// Wires the pieces together and follows the system lifecycle (sleep, wake,
/// display changes, fast user switching).
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        // `make uninstall` runs the binary with this flag while the bundle still
        // exists: the login item can only be unregistered by the app itself.
        if CommandLine.arguments.contains("--unregister-login-item") {
            exit(LoginItem.unregisterForUninstall() ? 0 : 1)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private var controller: BrightnessController?
    private var writer: CoalescingWriter?
    private var displayManager: DisplayManager!
    private var statusMenu: StatusMenuController!
    private let keyTap = BrightnessKeyTap()
    private var isSessionActive = true
    private var isSleeping = false
    private var areScreensAsleep = false
    /// True for a few seconds after displays were added, removed or woken.
    private var isSettling = false
    private var settleWork: DispatchWorkItem?
    /// Settle passes after a display change, in seconds from the change. The
    /// first two always run; the later ones only while a display is still
    /// unsupported or unobserved. Sync resumes after the last pass that ran.
    private static let settlePasses: [TimeInterval] = [0.6, 3, 6, 10]
    private var isWatchingAccessibility = false

    private static let didPromptAccessibilityKey = "didPromptAccessibility"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests run inside the app as host: do not create the menu, the event
        // tap or the Accessibility prompt there.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let backend = DisplayServicesBackend()
        if let backend {
            let writer = CoalescingWriter { display, value in backend.setBrightness(value, of: display) }
            let controller = BrightnessController(backend: backend, writer: writer)
            writer.onFailure = { [weak controller] display, generation in
                controller?.writeDidFail(on: display, generation: generation)
            }
            self.controller = controller
            self.writer = writer
        } else {
            Log.app.error("No brightness backend: every display will be shown as unsupported")
        }

        displayManager = DisplayManager(backend: backend)
        displayManager.onReconfiguration = { [weak self] in self?.displaysDidChange() }
        displayManager.start()
        controller?.updateDisplays(supportedDisplayIDs(), builtin: builtinDisplayIDs())
        // Restore the mode and offset only: no brightness is written at launch
        // (sync is still off while the offset is restored).
        controller?.setSyncOffset(Preferences.syncOffset)
        controller?.setSyncEnabled(Preferences.isSyncEnabled, reference: nil)

        statusMenu = StatusMenuController(
            displayManager: displayManager,
            controller: controller,
            keysAuthorized: { [weak self] in self?.keysAuthorized() ?? false },
            actions: .init(
                setBrightness: { [weak self] display, value in self?.controller?.setBrightness(value, for: display) },
                toggleSync: { [weak self] in self?.toggleSync() },
                setSyncOffset: { [weak self] offset in
                    Preferences.syncOffset = offset
                    self?.controller?.setSyncOffset(offset)
                },
                requestAccessibility: { [weak self] in self?.requestAccessibility() }))
        controller?.onValueChanged = { [weak self] display, value in
            self?.statusMenu.brightnessDidChange(display, value)
        }

        keyTap.handler = { [weak self] press in self?.handleKey(press) ?? false }
        keyTap.onPermissionLost = { [weak self] in self?.startKeyTap(prompt: false) }
        let firstLaunch = !UserDefaults.standard.bool(forKey: Self.didPromptAccessibilityKey)
        if firstLaunch { UserDefaults.standard.set(true, forKey: Self.didPromptAccessibilityKey) }
        startKeyTap(prompt: firstLaunch)

        observeSystem()

        // Hidden icon: launching the app by hand shows it once (not at login).
        if !Preferences.menuBarIconMode.isVisible(hasExternalDisplay: displayManager.displays.contains { !$0.isBuiltin },
                                                  revealed: false),
           !launchedAsLoginItem {
            statusMenu.reveal(openMenu: false)
        }
    }

    private var launchedAsLoginItem = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The open-application event is only readable here, before launch completes.
        launchedAsLoginItem = Self.isLoginItemLaunch()
    }

    /// Opening the app again while it runs (Finder, Spotlight, Dock) shows the
    /// icon and its menu: the way back to a hidden icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusMenu?.reveal(openMenu: true)
        return false
    }

    /// Launch Services tags a login-item launch on the open-application event.
    /// If it does not (unverified for SMAppService), the only cost is the icon
    /// showing for a minute after login, menu closed.
    private static func isLoginItemLaunch() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == AEEventID(kAEOpenApplication)
            && event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    // MARK: Keys

    private func handleKey(_ press: BrightnessKeyTap.Press) -> Bool {
        guard let controller, isSessionActive else { return false }
        // ⌥ + brightness key opens Displays settings in macOS: keep that.
        guard !press.optionOnly else { return false }
        // Resolve the target now, at the time of the key press.
        let pointer = DisplayManager.pointerLocation()
        let targets = displayManager.displays(at: pointer).filter(controller.isSupported)
        // While displays settle the cache may hold a value from before the change:
        // read the hardware first (~40 µs per display, measured).
        if isSettling { controller.refresh(targets) }
        // Display not supported: let macOS do whatever it natively does.
        guard let first = targets.first,
              let value = controller.step(press.direction, fine: press.fine, on: targets) else { return false }
        BrightnessOSD.show(value, on: first)
        return true
    }

    /// Starts the tap if Accessibility is granted. Otherwise waits for macOS to
    /// announce a change of the Accessibility list: no polling.
    private func startKeyTap(prompt: Bool) {
        guard isSessionActive else { return }
        // Literal value of kAXTrustedCheckOptionPrompt (the C global is not concurrency-safe in Swift 6).
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        if AXIsProcessTrustedWithOptions(options), keyTap.start() { return }
        watchAccessibilityChanges()
    }

    /// `com.apple.accessibility.api` is posted on the distributed centre whenever
    /// the Accessibility list changes (undocumented name, but a public channel;
    /// used by many utilities). The trust state updates slightly after the
    /// notification, hence the short delay.
    private func watchAccessibilityChanges() {
        guard !isWatchingAccessibility else { return }
        isWatchingAccessibility = true
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    guard let self, !self.keyTap.isRunning, self.isSessionActive, AXIsProcessTrusted() else { return }
                    self.keyTap.start()
                }
            }
        }
    }

    /// Also a fallback for the notification: opening the menu re-checks once.
    private func keysAuthorized() -> Bool {
        if !keyTap.isRunning, isSessionActive, AXIsProcessTrusted() { keyTap.start() }
        return keyTap.isRunning
    }

    private func requestAccessibility() {
        startKeyTap(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Sync

    private func toggleSync() {
        guard let controller else { return }
        let enabled = !controller.isSyncEnabled
        Preferences.isSyncEnabled = enabled
        let reference = displayManager.displays(at: DisplayManager.pointerLocation()).first(where: controller.isSupported)
            ?? controller.displays.first
        controller.setSyncEnabled(enabled, reference: reference)
        Log.sync.info("Sync \(enabled ? "enabled" : "disabled", privacy: .public)")
    }

    // MARK: System lifecycle

    private func supportedDisplayIDs() -> [CGDirectDisplayID] {
        displayManager.displays.filter(\.isSupported).map(\.id)
    }

    private func builtinDisplayIDs() -> Set<CGDirectDisplayID> {
        Set(displayManager.displays.filter(\.isBuiltin).map(\.id))
    }

    /// Re-enumerates displays, re-reads their values from the hardware and
    /// re-subscribes to their notifications.
    private func reloadDisplays() {
        displayManager.refresh()
        controller?.updateDisplays(supportedDisplayIDs(), builtin: builtinDisplayIDs(), resubscribe: true)
        statusMenu?.displaysDidChange()
    }

    /// Measured on macOS 27.3 (2026-11-22), unplugging and replugging a Studio
    /// Display: (1) it comes back online ~3 s before DisplayServices can read it,
    /// so a single check classifies it as unsupported for good; (2) during the
    /// replug DisplayServices reports bogus values (built-in "100 %" × 28–32).
    /// So, after any display change: notifications are ignored and sync is held
    /// until the last useful re-read (see `settlePasses`); values always come from
    /// an explicit read. Bounded: nothing runs once the displays are stable.
    private func displaysDidChange() {
        setSettling(true)
        runSettlePass(0, after: Self.settlePasses[0])
    }

    private func runSettlePass(_ index: Int, after delay: TimeInterval) {
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reloadDisplays()
            let next = index + 1
            let needsMore = next < 2
                || self.displayManager.displays.contains { !$0.isSupported }
                || self.controller?.hasUnobservedDisplays == true
            if next < Self.settlePasses.count, needsMore {
                self.runSettlePass(next, after: Self.settlePasses[next] - Self.settlePasses[index])
            } else {
                self.setSettling(false)
            }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func setSettling(_ settling: Bool) {
        isSettling = settling
        controller?.isSettling = settling
        updateSuspension()
    }

    /// Sync never propagates while the Mac or its screens sleep (macOS dims panels
    /// before sleep), while displays settle, or while another user session is in front.
    private func updateSuspension() {
        controller?.isSuspended = isSleeping || areScreensAsleep || isSettling || !isSessionActive
    }

    private func observeSystem() {
        let center = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ body: @escaping @MainActor (AppDelegate) -> Void) {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    body(self)
                }
            }
        }
        on(NSWorkspace.willSleepNotification) { app in
            app.isSleeping = true
            app.updateSuspension()
            // Nothing queued before sleep may land after wake.
            app.writer?.cancelAll()
            app.controller?.resetEchoes()
        }
        on(NSWorkspace.didWakeNotification) { app in
            // Keys work again at once; displays come back over a few seconds, so
            // values and subscriptions are refreshed once they settled.
            app.isSleeping = false
            app.displaysDidChange()
        }
        on(NSWorkspace.screensDidSleepNotification) { app in
            app.areScreensAsleep = true
            app.updateSuspension()
        }
        on(NSWorkspace.screensDidWakeNotification) { app in
            app.areScreensAsleep = false
            app.displaysDidChange()
        }
        on(NSWorkspace.sessionDidResignActiveNotification) { app in
            app.isSessionActive = false
            app.keyTap.stop()
            app.writer?.cancelAll()
            app.updateSuspension()
        }
        on(NSWorkspace.sessionDidBecomeActiveNotification) { app in
            app.isSessionActive = true
            app.displaysDidChange()
            app.startKeyTap(prompt: false)
        }
    }
}
