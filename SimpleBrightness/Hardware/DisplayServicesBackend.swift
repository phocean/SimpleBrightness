import CoreGraphics
import Foundation
import os

/// Hardware brightness through Apple's **private** `DisplayServices.framework`.
///
/// Why a private API: on Apple Silicon there is no public API that changes the
/// backlight of the built-in panel or of an Apple external display. The legacy
/// `IODisplaySetFloatParameter(kIODisplayBrightnessKey)` has no effect there.
/// DisplayServices is what Control Center and the brightness keys use; it is also
/// what MonitorControl and Lunar rely on for Apple displays.
///
/// Measured on macOS 27.3 (26C5035r), MacBook Pro M4 + Studio Display:
/// - `DisplayServicesCanChangeBrightness` is true for the Studio Display,
/// - get/set change the real backlight (read-back is exact),
/// - `DisplayServicesRegisterForBrightnessChangeNotifications` fires for changes
///   made by any process, with `userInfo["value"]`; it fires for our own writes too,
/// - `DisplayServicesUnregisterForBrightnessChangeNotifications(display, observer)`
///   stops the callbacks.
/// The same changes are *not* visible through the distributed or Darwin notification
/// centres, so there is no public way to observe them.
///
/// Compatibility: the framework and these symbols have been stable since at least
/// macOS 11. Every symbol is resolved with `dlsym` at launch; if any is missing the
/// backend is not created and every display is shown as unsupported (no crash, no
/// fallback to software dimming).
final class DisplayServicesBackend: BrightnessBackend, @unchecked Sendable {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanFn = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias RegisterFn = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?, CFNotificationCallback) -> Int32
    private typealias UnregisterFn = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?) -> Int32

    private static let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    private static let log = Logger(subsystem: Log.subsystem, category: "DisplayServices")

    private let getFn: GetFn
    private let setFn: SetFn
    private let canFn: CanFn
    private let registerFn: RegisterFn
    private let unregisterFn: UnregisterFn

    /// The C callback cannot capture context; it forwards here. Only ever touched
    /// on the main queue.
    @MainActor private static var current: DisplayServicesBackend?

    // Observation state lives on the main actor; the compiler enforces it.
    @MainActor var onChange: (@MainActor (CGDirectDisplayID, Double) -> Void)?
    @MainActor private var observed = Set<CGDirectDisplayID>()
    /// Serialises reads (main actor) and writes (writer queue) of DisplayServices:
    /// the private API is not documented as thread-safe. Calls take µs, so the
    /// lock is never held long.
    private let ioLock = NSLock()

    @MainActor
    init?() {
        guard let handle = dlopen(Self.path, RTLD_NOW | RTLD_LOCAL) else {
            Self.log.error("DisplayServices.framework not found")
            return nil
        }
        func load<T>(_ name: String, as type: T.Type) -> T? {
            guard let symbol = dlsym(handle, name) else {
                Self.log.error("Missing symbol \(name, privacy: .public)")
                return nil
            }
            return unsafeBitCast(symbol, to: type)
        }
        guard
            let get = load("DisplayServicesGetBrightness", as: GetFn.self),
            let set = load("DisplayServicesSetBrightness", as: SetFn.self),
            let can = load("DisplayServicesCanChangeBrightness", as: CanFn.self),
            let register = load("DisplayServicesRegisterForBrightnessChangeNotifications", as: RegisterFn.self),
            let unregister = load("DisplayServicesUnregisterForBrightnessChangeNotifications", as: UnregisterFn.self)
        else { return nil }
        getFn = get
        setFn = set
        canFn = can
        registerFn = register
        unregisterFn = unregister
        Self.current = self
    }

    func supports(_ display: CGDirectDisplayID) -> Bool {
        guard canFn(display) else { return false }
        return brightness(of: display) != nil
    }

    func brightness(of display: CGDirectDisplayID) -> Double? {
        var value: Float = 0
        let status = ioLock.withLock { getFn(display, &value) }
        guard status == 0, value.isFinite else { return nil }
        return Double(min(max(value, 0), 1))
    }

    @discardableResult
    func setBrightness(_ value: Double, of display: CGDirectDisplayID) -> Bool {
        guard value.isFinite else { return false }
        let clamped = Float(min(max(value, 0), 1))
        let status = ioLock.withLock { setFn(display, clamped) }
        if status != 0 {
            Self.log.error("Set failed on \(display) status=\(status)")
        }
        return status == 0
    }

    @MainActor
    @discardableResult
    func startObserving(_ display: CGDirectDisplayID) -> Bool {
        guard !observed.contains(display) else { return true }
        let status = registerFn(display, Self.observerToken(for: display), Self.callback)
        guard status == 0 else {
            Self.log.error("Cannot observe display \(display) status=\(status)")
            return false
        }
        observed.insert(display)
        Self.log.debug("Observe \(display)")
        return true
    }

    @MainActor
    func stopObserving(_ display: CGDirectDisplayID) {
        guard observed.remove(display) != nil else { return }
        _ = unregisterFn(display, Self.observerToken(for: display))
    }

    /// The observer pointer is only an opaque token handed back to the callback;
    /// we use it to carry the display ID (never 0 for a real display).
    private static func observerToken(for display: CGDirectDisplayID) -> UnsafeRawPointer? {
        UnsafeRawPointer(bitPattern: UInt(display))
    }

    private static let callback: CFNotificationCallback = { _, observer, _, _, userInfo in
        guard let observer else { return }
        let display = CGDirectDisplayID(truncatingIfNeeded: UInt(bitPattern: observer))
        guard
            let info = userInfo as NSDictionary?,
            let number = info["value"] as? NSNumber,
            number.doubleValue.isFinite
        else { return }
        let value = min(max(number.doubleValue, 0), 1)
        // The thread is not documented; always hop to the main queue.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                DisplayServicesBackend.current?.onChange?(display, value)
            }
        }
    }
}
