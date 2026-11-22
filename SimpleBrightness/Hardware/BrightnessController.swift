import CoreGraphics
import Foundation

/// Single source of truth for the brightness of every supported display, and the
/// place where synchronisation happens.
///
/// **Echoes.** DisplayServices reports *every* change, including the ones we
/// cause. Each write is remembered for `echoWindow` seconds as a range
/// `[from, to]` (a panel may report intermediate values while it ramps); a
/// notification inside a recent range is an echo and is not propagated. Because a
/// genuine external change can also fall in that range, the hardware is read once
/// more when the window closes, and any difference is handled as an external
/// change (audit 2026-11-22, finding 1).
///
/// **Sync.** All synced displays follow one *level*: the brightness of the
/// built-in display (`external = level + syncOffset`, written clamped to 0…1).
/// The level itself is not clamped to 0…1, so an external display pinned at
/// 100 % by a positive offset comes back down by exactly one step, and mirrored
/// displays move together (audit findings 9 and 10).
///
/// **Settling.** While displays are being added, removed or woken, notifications
/// are ignored: DisplayServices sends bogus values then (measured: built-in
/// "100 %" × 28–32 during a Studio Display replug). Only explicit reads count.
@MainActor
final class BrightnessController {
    enum Direction { case up, down }

    private struct RecentWrite {
        let low: Double
        let high: Double
        let time: TimeInterval
    }

    static let echoWindow: TimeInterval = 2.0
    static let echoTolerance = 0.01
    /// Below this difference two displays are considered already in sync.
    static let syncThreshold = 0.002
    static let maxSyncOffset = 0.3

    private let backend: BrightnessBackend
    private let writer: BrightnessWriter
    private let now: () -> TimeInterval
    private let scheduler: Scheduling

    /// Supported displays, in menu order.
    private(set) var displays: [CGDirectDisplayID] = []
    private var values: [CGDirectDisplayID: Double] = [:]
    private var recentWrites: [CGDirectDisplayID: [RecentWrite]] = [:]
    /// Incremented on every write; a failure report for an older generation is stale.
    private var generations: [CGDirectDisplayID: Int] = [:]
    private var reconcileWork: [CGDirectDisplayID: ScheduledWork] = [:]
    private var builtinDisplays = Set<CGDirectDisplayID>()
    private var unobserved = Set<CGDirectDisplayID>()

    /// Brightness of external displays relative to the built-in one, when synced.
    private(set) var syncOffset: Double = 0
    /// Current sync level (built-in brightness, unclamped). Nil: derive it from
    /// the displays' values.
    private var syncLevel: Double?

    private(set) var isSyncEnabled = false
    /// True while the user session is inactive, the Mac or its screens sleep, or
    /// displays settle: changes are tracked but never propagated.
    var isSuspended = false
    /// True while displays settle: notifications are ignored entirely.
    var isSettling = false

    /// Called after every change of a cached value, whatever its origin.
    var onValueChanged: ((CGDirectDisplayID, Double) -> Void)?

    init(backend: BrightnessBackend,
         writer: BrightnessWriter,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         scheduler: Scheduling = MainQueueScheduler()) {
        self.backend = backend
        self.writer = writer
        self.now = now
        self.scheduler = scheduler
        backend.onChange = { [weak self] display, value in
            self?.hardwareDidChange(display, value)
        }
    }

    private var isSyncActive: Bool { isSyncEnabled && !isSuspended }

    func isSupported(_ display: CGDirectDisplayID) -> Bool { values[display] != nil }

    func value(of display: CGDirectDisplayID) -> Double? { values[display] }

    /// A supported display whose change notifications could not be registered:
    /// the caller retries on its next (bounded) reload.
    var hasUnobservedDisplays: Bool { !unobserved.isEmpty }

    // MARK: Display list

    /// Replaces the set of supported displays with those that can be read *now*.
    /// The new state is built first and swapped in at once: a display whose read
    /// fails is dropped completely (cache, echoes, subscription, pending writes),
    /// never left half-known. Nothing is ever written here: reconnecting a display
    /// must not change any brightness.
    /// - Parameter resubscribe: re-register notifications for displays already
    ///   known (after wake or hotplug, registrations may be stale).
    func updateDisplays(_ supported: [CGDirectDisplayID],
                        builtin: Set<CGDirectDisplayID> = [],
                        resubscribe: Bool = false) {
        builtinDisplays = builtin
        var fresh: [CGDirectDisplayID: Double] = [:]
        var kept: [CGDirectDisplayID] = []
        for display in supported where fresh[display] == nil {
            guard let value = backend.brightness(of: display) else { continue }
            fresh[display] = value
            kept.append(display)
        }
        for display in Set(values.keys).subtracting(fresh.keys) {
            forget(display)
        }
        for display in kept {
            if resubscribe { backend.stopObserving(display) }
            if backend.startObserving(display) {
                unobserved.remove(display)
            } else {
                unobserved.insert(display)
            }
            // A fresh hardware read is the truth: older echo ranges no longer apply.
            recentWrites[display] = nil
            reconcileWork.removeValue(forKey: display)?.cancel()
        }
        values = fresh
        displays = kept
        syncLevel = nil
        for display in kept { onValueChanged?(display, fresh[display]!) }
    }

    /// Re-reads displays from the hardware, e.g. before a key step while displays
    /// settle (the cache may predate a hotplug).
    func refresh(_ targets: [CGDirectDisplayID]) {
        for display in targets where values[display] != nil {
            guard let value = backend.brightness(of: display) else { continue }
            values[display] = value
            recentWrites[display] = nil
            onValueChanged?(display, value)
        }
        syncLevel = nil
    }

    /// Forgets every pending echo (before sleep: the uptime clock stops while
    /// asleep, so an old window would otherwise resume after wake).
    func resetEchoes() {
        recentWrites.removeAll()
        reconcileWork.values.forEach { $0.cancel() }
        reconcileWork.removeAll()
    }

    // MARK: Changes made by this app

    /// Sets a display from the UI. With sync on, every other display follows.
    func setBrightness(_ value: Double, for display: CGDirectDisplayID) {
        guard value.isFinite, isSupported(display) else { return }
        let value = Self.clamp01(value)
        if isSyncActive {
            setLevel(value - offset(of: display), source: display, sourceValue: value)
        } else {
            applyIfNeeded(value, to: display)
        }
    }

    /// One keyboard step on `targets` (several only when displays are mirrored).
    /// With sync on, the step moves the shared level once, so every display moves
    /// by the same amount. Returns the new value of the first target, or nil if
    /// none of the targets is supported.
    @discardableResult
    func step(_ direction: Direction, fine: Bool, on targets: [CGDirectDisplayID]) -> Double? {
        let supported = targets.filter(isSupported)
        guard let first = supported.first, let current = values[first] else { return nil }
        if isSyncActive {
            let range = levelRange
            let next = min(max(Self.steppedRaw(from: currentLevel(), direction: direction, fine: fine),
                               range.lowerBound), range.upperBound)
            setLevel(next, source: nil, sourceValue: nil)
            return values[first]
        }
        let next = Self.stepped(from: current, direction: direction, fine: fine)
        for display in supported {
            applyIfNeeded(next, to: display)
        }
        return next
    }

    /// Native macOS grid: 16 steps, or 64 with ⇧⌥. A value that sits between two
    /// grid points moves to the next grid point, never more than one step.
    nonisolated static func stepped(from value: Double, direction: Direction, fine: Bool) -> Double {
        clamp01(steppedRaw(from: value, direction: direction, fine: fine))
    }

    /// Same grid, without clamping (the sync level may leave 0…1).
    nonisolated static func steppedRaw(from value: Double, direction: Direction, fine: Bool) -> Double {
        let steps = fine ? 64.0 : 16.0
        let position = value * steps
        let epsilon = 1e-6
        switch direction {
        case .up: return ((position + epsilon).rounded(.down) + 1) / steps
        case .down: return ((position - epsilon).rounded(.up) - 1) / steps
        }
    }

    func setSyncEnabled(_ enabled: Bool, reference: CGDirectDisplayID?) {
        isSyncEnabled = enabled
        syncLevel = nil
        // Turning sync on is an explicit user action: align everyone on the
        // display the user is looking at. Never done at launch or on reconnect.
        guard enabled, !isSuspended, let reference, let value = values[reference] else { return }
        setLevel(value - offset(of: reference), source: reference, sourceValue: value)
    }

    /// Changes the offset; with sync on, external displays move at once around
    /// the built-in display (the user is watching them while dragging).
    func setSyncOffset(_ offset: Double) {
        guard offset.isFinite else { return }
        syncOffset = min(max(offset, -Self.maxSyncOffset), Self.maxSyncOffset)
        guard isSyncActive,
              let reference = displays.first(where: builtinDisplays.contains),
              let value = values[reference] else { return }
        setLevel(value, source: reference, sourceValue: value)
    }

    /// Whether the offset applies at all (needs a built-in and an external display).
    var canUseSyncOffset: Bool {
        displays.contains(where: builtinDisplays.contains) && displays.contains { !builtinDisplays.contains($0) }
    }

    // MARK: Changes reported by the system

    func hardwareDidChange(_ display: CGDirectDisplayID, _ value: Double) {
        guard value.isFinite, values[display] != nil, !isSettling else { return }
        // An echo (possibly late, or an intermediate ramp value) must not
        // overwrite the value we asked for: the next key step starts from the cache.
        guard !isEcho(value, on: display) else { return }
        externalChange(on: display, value)
    }

    /// A hardware write failed (display asleep or gone). Stale reports (an older
    /// write than the latest one) are ignored. Otherwise the hardware is trusted
    /// again and, with sync on, the group is realigned on what the panel really has.
    func writeDidFail(on display: CGDirectDisplayID, generation: Int) {
        guard generations[display] == generation, values[display] != nil else { return }
        recentWrites[display] = nil
        guard let actual = backend.brightness(of: display) else { return }
        values[display] = actual
        onValueChanged?(display, actual)
        guard isSyncActive else { return }
        syncLevel = nil
        setLevel(actual - offset(of: display), source: display, sourceValue: actual)
    }

    // MARK: Private

    private func externalChange(on display: CGDirectDisplayID, _ value: Double) {
        let previousLevel = currentLevel()
        values[display] = value
        onValueChanged?(display, value)
        guard isSyncActive else { return }
        // A display pinned at a bound says nothing new if the level already maps there.
        if (value <= 0 || value >= 1), Self.clamp01(previousLevel + offset(of: display)) == value {
            return
        }
        Log.sync.debug("External change on \(display): \(value)")
        setLevel(value - offset(of: display), source: display, sourceValue: value)
    }

    /// Moves the shared level and writes every display that is not already within
    /// `syncThreshold` of its target (this is what makes rounding panels converge).
    private func setLevel(_ level: Double, source: CGDirectDisplayID?, sourceValue: Double?) {
        let range = levelRange
        let level = min(max(level, range.lowerBound), range.upperBound)
        syncLevel = level
        for display in displays {
            let target = (display == source ? sourceValue : nil) ?? Self.clamp01(level + offset(of: display))
            applyIfNeeded(target, to: display)
        }
    }

    private func currentLevel() -> Double {
        if let syncLevel { return syncLevel }
        if let builtin = displays.first(where: builtinDisplays.contains), let value = values[builtin] {
            return value
        }
        if let first = displays.first, let value = values[first] {
            return value - offset(of: first)
        }
        return 0
    }

    /// Levels at which at least one display is still inside 0…1.
    private var levelRange: ClosedRange<Double> {
        let offsets = displays.map(offset(of:))
        let low = min(0, -(offsets.max() ?? 0))
        let high = max(1, 1 - (offsets.min() ?? 0))
        return low...high
    }

    private func offset(of display: CGDirectDisplayID) -> Double {
        builtinDisplays.contains(display) ? 0 : syncOffset
    }

    private func applyIfNeeded(_ value: Double, to display: CGDirectDisplayID) {
        guard let current = values[display], abs(current - value) > Self.syncThreshold else { return }
        apply(value, to: display)
    }

    private func apply(_ value: Double, to display: CGDirectDisplayID) {
        guard value.isFinite, let old = values[display] else { return }
        var writes = pruned(display)
        writes.append(RecentWrite(low: min(old, value), high: max(old, value), time: now()))
        recentWrites[display] = writes
        values[display] = value
        onValueChanged?(display, value)
        let generation = (generations[display] ?? 0) + 1
        generations[display] = generation
        writer.submit(value, for: display, generation: generation)
        scheduleReconcile(display)
    }

    /// When the echo window of `display` closes (no write for `echoWindow`), read
    /// the hardware once: a genuine change that looked like an echo is caught here.
    private func scheduleReconcile(_ display: CGDirectDisplayID) {
        reconcileWork.removeValue(forKey: display)?.cancel()
        reconcileWork[display] = scheduler.schedule(after: Self.echoWindow + 0.1) { [weak self] in
            self?.reconcile(display)
        }
    }

    private func reconcile(_ display: CGDirectDisplayID) {
        reconcileWork[display] = nil
        guard !isSettling, let cached = values[display],
              let actual = backend.brightness(of: display) else { return }
        recentWrites[display] = nil
        if abs(actual - cached) > Self.echoTolerance {
            externalChange(on: display, actual)
        }
    }

    private func forget(_ display: CGDirectDisplayID) {
        backend.stopObserving(display)
        writer.cancelPending(for: display)
        values[display] = nil
        recentWrites[display] = nil
        generations[display] = nil
        unobserved.remove(display)
        reconcileWork.removeValue(forKey: display)?.cancel()
    }

    private func isEcho(_ value: Double, on display: CGDirectDisplayID) -> Bool {
        let writes = pruned(display)
        recentWrites[display] = writes
        let tolerance = Self.echoTolerance
        return writes.contains { value >= $0.low - tolerance && value <= $0.high + tolerance }
    }

    private func pruned(_ display: CGDirectDisplayID) -> [RecentWrite] {
        let limit = now() - Self.echoWindow
        return (recentWrites[display] ?? []).filter { $0.time >= limit }.suffix(64)
    }

    nonisolated private static func clamp01(_ value: Double) -> Double { min(max(value, 0), 1) }
}
