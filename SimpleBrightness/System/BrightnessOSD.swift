import AppKit
import CoreGraphics

/// Shows the system brightness overlay through the **private** `OSD.framework`
/// (`OSDManager`), as MonitorControl does. Purely cosmetic: if the class or the
/// selector is missing, nothing is shown and nothing else changes.
///
/// This is the pre-macOS 26 overlay style. The macOS 27 bubble is drawn by Control
/// Center through an internal channel with no usable entry point; a hand-drawn
/// imitation was tried and dropped at the user's request (2026-11-22).
///
/// Checked on macOS 27.3: `+[OSDManager sharedManager]` and
/// `-showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:`
/// (type encoding `v48@0:8q16I24I28I32I36I40B44`) exist.
@MainActor
enum BrightnessOSD {
    private typealias ShowFn = @convention(c) (AnyObject, Selector, Int64, UInt32, UInt32, UInt32, UInt32, UInt32, Bool) -> Void

    private static let brightnessImage: Int64 = 1          // OSDGraphicBacklight
    private static let priority: UInt32 = 0x1F4
    private static let fadeMilliseconds: UInt32 = 1000

    private static let resolved: (manager: AnyObject, show: ShowFn, selector: Selector)? = {
        guard dlopen("/System/Library/PrivateFrameworks/OSD.framework/OSD", RTLD_NOW | RTLD_LOCAL) != nil,
              let cls = NSClassFromString("OSDManager") as? NSObject.Type else { return nil }
        let sharedSelector = NSSelectorFromString("sharedManager")
        guard cls.responds(to: sharedSelector),
              let manager = cls.perform(sharedSelector)?.takeUnretainedValue() as? NSObject else { return nil }
        let selector = NSSelectorFromString("showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:")
        guard manager.responds(to: selector) else { return nil }
        let imp = manager.method(for: selector)
        return (manager, unsafeBitCast(imp, to: ShowFn.self), selector)
    }()

    static func show(_ value: Double, on display: CGDirectDisplayID) {
        guard let resolved else { return }
        // 64 chiclets gives quarter-step precision; the overlay groups them into 16.
        let total: UInt32 = 64
        let filled = UInt32((min(max(value, 0), 1) * Double(total)).rounded())
        resolved.show(resolved.manager, resolved.selector, brightnessImage, display,
                      priority, fadeMilliseconds, filled, total, false)
    }
}
