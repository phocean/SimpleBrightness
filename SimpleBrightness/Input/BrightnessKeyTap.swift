import AppKit
import ApplicationServices
import CoreGraphics

/// Intercepts the brightness keys (F1/F2, or fn+F1/F2) through a CGEvent tap.
///
/// The tap only subscribes to `NSSystemDefined` events (media/auxiliary keys).
/// Ordinary key presses are never delivered to this app: it is not, and cannot
/// act as, a keylogger. Every system-defined event that is not a brightness key
/// is returned untouched.
///
/// An active (filtering) tap requires the Accessibility permission. Without it
/// `tapCreate` fails and macOS keeps handling the keys natively.
@MainActor
final class BrightnessKeyTap {
    struct Press {
        let direction: BrightnessController.Direction
        /// ⇧⌥: quarter steps, like macOS.
        let fine: Bool
        /// ⌥ alone: macOS opens Displays settings; we leave it alone.
        let optionOnly: Bool
    }

    /// A decoded auxiliary-key event (pure data, unit-tested).
    struct AuxKey: Equatable {
        enum Phase: Equatable { case down, up, other }
        let direction: BrightnessController.Direction?
        let keyCode: Int
        let phase: Phase
        let isRepeat: Bool
    }

    /// Decodes `NSEvent.data1` of an `NX_SUBTYPE_AUX_CONTROL_BUTTONS` event:
    /// key code in the high 16 bits, key state in bits 8–15, repeat flag in bit 0.
    /// `direction` is nil for any key that is not a brightness key.
    nonisolated static func decode(data1 data: Int) -> AuxKey {
        let keyCode = (data & 0xFFFF_0000) >> 16
        let flags = data & 0xFFFF
        let state = (flags & 0xFF00) >> 8
        let direction: BrightnessController.Direction? = switch keyCode {
        case brightnessUp: .up
        case brightnessDown: .down
        default: nil
        }
        let phase: AuxKey.Phase = state == keyDownState ? .down : state == keyUpState ? .up : .other
        return AuxKey(direction: direction, keyCode: keyCode, phase: phase, isRepeat: flags & 0x1 != 0)
    }

    /// Return true to consume the key press (and its release).
    var handler: ((Press) -> Bool)?
    /// Called when macOS disabled the tap and the Accessibility permission is
    /// gone: the tap has been stopped, keys are back to native behaviour.
    var onPermissionLost: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Keys whose key-down we consumed: their key-up must be consumed too.
    private var consumed = Set<Int>()

    // IOKit NX constants (IOKit/hidsystem/ev_keymap.h).
    private static let systemDefinedType: UInt32 = 14       // NX_SYSDEFINED
    private static let auxControlSubtype: Int16 = 8         // NX_SUBTYPE_AUX_CONTROL_BUTTONS
    nonisolated private static let brightnessUp = 2          // NX_KEYTYPE_BRIGHTNESS_UP
    nonisolated private static let brightnessDown = 3        // NX_KEYTYPE_BRIGHTNESS_DOWN
    nonisolated private static let keyDownState = 0x0A
    nonisolated private static let keyUpState = 0x0B

    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    @discardableResult
    func start() -> Bool {
        if tap != nil {
            if isRunning { return true }
            stop()   // stale tap (permission revoked then granted again): recreate it
        }
        let mask = CGEventMask(1) << CGEventMask(Self.systemDefinedType)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: Self.callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Log.keys.error("Event tap creation failed (Accessibility not granted?)")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        Log.keys.info("Event tap started")
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        self.source = nil
        consumed.removeAll()
        Log.keys.info("Event tap stopped")
    }

    /// Returns true when the event must be consumed.
    private func shouldConsume(type: CGEventType, event: CGEvent) -> Bool {
        // macOS disables a tap that is too slow or when secure input starts;
        // re-enable it instead of silently losing the keys.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            guard AXIsProcessTrusted() else {
                Log.keys.notice("Accessibility permission revoked, stopping the event tap")
                // Defer: we are inside the tap's own callback.
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.stop()
                        self?.onPermissionLost?()
                    }
                }
                return false
            }
            Log.keys.notice("Event tap disabled by system (\(type.rawValue)), re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard type.rawValue == Self.systemDefinedType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == Self.auxControlSubtype else {
            return false
        }
        let key = Self.decode(data1: nsEvent.data1)
        guard let direction = key.direction else { return false }

        switch key.phase {
        case .up:
            return consumed.remove(key.keyCode) != nil
        case .other:
            return false
        case .down:
            break
        }

        let modifiers = nsEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let press = Press(direction: direction,
                          fine: modifiers.contains([.shift, .option]),
                          optionOnly: modifiers.contains(.option) && !modifiers.contains(.shift))
        // No pointer position, no per-press detail beyond the key itself.
        Log.keys.debug("Brightness key \(key.keyCode) repeat=\(key.isRepeat)")
        if handler?(press) == true {
            consumed.insert(key.keyCode)
            return true
        }
        consumed.remove(key.keyCode)
        return false
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let tap = Unmanaged<BrightnessKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
        // The run-loop source is on the main run loop, so we are on the main thread.
        nonisolated(unsafe) let event = event
        let consume = MainActor.assumeIsolated { tap.shouldConsume(type: type, event: event) }
        return consume ? nil : Unmanaged.passUnretained(event)
    }
}
