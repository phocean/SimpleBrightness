import CoreGraphics
import Foundation
@testable import SimpleBrightness

/// Simulated displays: `hardware` is what the panels really show, distinct from
/// the controller's cache.
final class FakeBackend: BrightnessBackend, @unchecked Sendable {
    var hardware: [CGDirectDisplayID: Double]
    var unreadable = Set<CGDirectDisplayID>()
    var refusesObservation = Set<CGDirectDisplayID>()
    private(set) var observed = Set<CGDirectDisplayID>()
    @MainActor var onChange: (@MainActor (CGDirectDisplayID, Double) -> Void)?

    init(_ hardware: [CGDirectDisplayID: Double]) { self.hardware = hardware }

    func supports(_ display: CGDirectDisplayID) -> Bool { brightness(of: display) != nil }
    func brightness(of display: CGDirectDisplayID) -> Double? {
        unreadable.contains(display) ? nil : hardware[display]
    }
    func setBrightness(_ value: Double, of display: CGDirectDisplayID) -> Bool {
        hardware[display] = value
        return true
    }
    @MainActor func startObserving(_ display: CGDirectDisplayID) -> Bool {
        guard !refusesObservation.contains(display) else { return false }
        observed.insert(display)
        return true
    }
    @MainActor func stopObserving(_ display: CGDirectDisplayID) { observed.remove(display) }
}

/// Records writes; the test decides when the hardware "answers".
final class RecordingWriter: BrightnessWriter {
    struct Write: Equatable {
        let display: CGDirectDisplayID
        let value: Double
        let generation: Int
    }
    var writes: [Write] = []
    var cancelled: [CGDirectDisplayID] = []
    var cancelledAll = 0
    func submit(_ value: Double, for display: CGDirectDisplayID, generation: Int) {
        writes.append(Write(display: display, value: value, generation: generation))
    }
    func cancelPending(for display: CGDirectDisplayID) { cancelled.append(display) }
    func cancelAll() { cancelledAll += 1 }
    var displays: [CGDirectDisplayID] { writes.map(\.display) }
}

/// Runs scheduled work only when the test says so.
@MainActor
final class ManualScheduler: Scheduling {
    final class Work: ScheduledWork {
        let fireAt: TimeInterval
        let body: @MainActor @Sendable () -> Void
        var isCancelled = false
        init(fireAt: TimeInterval, body: @escaping @MainActor @Sendable () -> Void) {
            self.fireAt = fireAt
            self.body = body
        }
        func cancel() { isCancelled = true }
    }
    var now: TimeInterval = 0
    private(set) var works: [Work] = []

    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor @Sendable () -> Void) -> ScheduledWork {
        let item = Work(fireAt: now + delay, body: work)
        works.append(item)
        return item
    }

    /// Advances time and runs what became due, in order.
    func advance(by delta: TimeInterval) {
        now += delta
        while let next = works.filter({ !$0.isCancelled && $0.fireAt <= now }).min(by: { $0.fireAt < $1.fireAt }) {
            next.isCancelled = true
            next.body()
        }
        works.removeAll { $0.isCancelled }
    }
}

/// A controller over two displays: 1 = built-in, 2 = external.
@MainActor
struct Rig {
    nonisolated static let builtin: CGDirectDisplayID = 1
    nonisolated static let studio: CGDirectDisplayID = 2

    let backend: FakeBackend
    let writer = RecordingWriter()
    let scheduler = ManualScheduler()
    let controller: BrightnessController

    init(builtin: Double = 0.5, studio: Double = 0.3) {
        backend = FakeBackend([Self.builtin: builtin, Self.studio: studio])
        let scheduler = self.scheduler
        controller = BrightnessController(backend: backend, writer: writer,
                                          now: { scheduler.now }, scheduler: scheduler)
        controller.updateDisplays([Self.builtin, Self.studio], builtin: [Self.builtin])
    }

    /// The hardware applies every pending write and reports it (the echo).
    func deliverEchoes(transform: (CGDirectDisplayID, Double) -> Double = { $1 }) {
        let pending = writer.writes
        writer.writes.removeAll()
        for write in pending {
            let shown = transform(write.display, write.value)
            backend.hardware[write.display] = shown
            controller.hardwareDidChange(write.display, shown)
        }
    }

    /// Something other than the app changes a panel (Control Center, auto-brightness).
    func externalChange(_ display: CGDirectDisplayID, _ value: Double) {
        backend.hardware[display] = value
        controller.hardwareDidChange(display, value)
    }
}
