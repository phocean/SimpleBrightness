import CoreGraphics

/// Abstraction over a way of driving the *hardware* backlight of a display.
///
/// Every implementation must change the real panel luminance. Gamma tables,
/// overlays or any other software dimming are out of scope by design: a display
/// that no backend can drive is reported as unsupported instead.
///
/// Values are normalised to `0...1`. Two displays at the same value do not
/// necessarily emit the same luminance (nits); see README.
protocol BrightnessBackend: AnyObject, Sendable {
    /// Whether this backend can drive the given display's backlight.
    func supports(_ display: CGDirectDisplayID) -> Bool

    /// Current hardware brightness, or `nil` if it cannot be read.
    func brightness(of display: CGDirectDisplayID) -> Double?

    /// Writes the hardware brightness. May block (USB round-trip); must be
    /// safe to call from a background queue.
    @discardableResult
    func setBrightness(_ value: Double, of display: CGDirectDisplayID) -> Bool

    /// Starts delivering change notifications for `display` to `onChange`.
    /// Returns false if the registration failed (the display stays usable but
    /// external changes are not seen until a later retry).
    @MainActor @discardableResult func startObserving(_ display: CGDirectDisplayID) -> Bool
    @MainActor func stopObserving(_ display: CGDirectDisplayID)

    /// Called on the main queue for every brightness change the system reports,
    /// including the ones this app caused itself.
    @MainActor var onChange: (@MainActor (CGDirectDisplayID, Double) -> Void)? { get set }
}
