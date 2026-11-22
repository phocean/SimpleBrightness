import CoreGraphics
import Foundation

/// Sends brightness writes to the hardware off the main thread, keeping only the
/// latest requested value per display.
///
/// A slider drag or a held key produces more values than a display needs. Values
/// submitted while a write is in flight replace each other, so the hardware only
/// sees the most recent one, at most once per `minInterval`.
///
/// Measured on macOS 27.3 (2026-11-22): `DisplayServicesSetBrightness` returns in
/// ~4 µs (the request is queued to a system service), reads take ~40 µs (one
/// outlier at 86 ms on a Studio Display). The writer is therefore about rate
/// limiting and ordering, not about keeping a slow call off the main thread.
protocol BrightnessWriter: AnyObject {
    /// `generation` identifies the request; it is handed back on failure so the
    /// caller can ignore a failure that a newer request already superseded.
    func submit(_ value: Double, for display: CGDirectDisplayID, generation: Int)
    /// Drops writes not started yet (display removed). A write in progress
    /// cannot be recalled.
    func cancelPending(for display: CGDirectDisplayID)
    func cancelAll()
}

final class CoalescingWriter: BrightnessWriter, @unchecked Sendable {
    /// Concurrent so that a long drag on one display never delays another one;
    /// `draining` guarantees a single drain loop per display.
    private let queue = DispatchQueue(label: "com.jcbaptiste.SimpleBrightness.writer", qos: .userInitiated, attributes: .concurrent)
    // Everything below is guarded by `lock`.
    private let lock = NSLock()
    private var pending: [CGDirectDisplayID: (value: Double, generation: Int)] = [:]
    private var draining = Set<CGDirectDisplayID>()
    private var failureHandler: (@MainActor (CGDirectDisplayID, Int) -> Void)?

    private let minInterval: TimeInterval
    private let write: @Sendable (CGDirectDisplayID, Double) -> Bool

    /// - Parameter minInterval: 25 ms caps each display at 40 writes/s, smooth to
    ///   the eye and well within what DisplayServices handles.
    init(minInterval: TimeInterval = 0.025, write: @escaping @Sendable (CGDirectDisplayID, Double) -> Bool) {
        self.minInterval = minInterval
        self.write = write
    }

    /// Called on the main queue when a write fails, with its generation.
    var onFailure: (@MainActor (CGDirectDisplayID, Int) -> Void)? {
        get { lock.withLock { failureHandler } }
        set { lock.withLock { failureHandler = newValue } }
    }

    func submit(_ value: Double, for display: CGDirectDisplayID, generation: Int) {
        let shouldStart = lock.withLock {
            pending[display] = (value, generation)
            return draining.insert(display).inserted
        }
        if shouldStart {
            queue.async { [self] in drain(display) }
        }
    }

    func cancelPending(for display: CGDirectDisplayID) {
        lock.withLock { _ = pending.removeValue(forKey: display) }
    }

    func cancelAll() {
        lock.withLock { pending.removeAll() }
    }

    private func drain(_ display: CGDirectDisplayID) {
        while true {
            let next: (value: Double, generation: Int)? = lock.withLock {
                guard let request = pending.removeValue(forKey: display) else {
                    draining.remove(display)
                    return nil
                }
                return request
            }
            guard let next else { return }
            if !write(display, next.value) {
                let handler = onFailure
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { handler?(display, next.generation) }
                }
            }
            Thread.sleep(forTimeInterval: minInterval)
        }
    }
}
