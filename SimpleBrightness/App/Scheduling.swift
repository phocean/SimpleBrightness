import Foundation

/// Delayed, cancellable work on the main actor. Injected so that tests control time.
@MainActor
protocol Scheduling {
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor @Sendable () -> Void) -> ScheduledWork
}

@MainActor
protocol ScheduledWork: AnyObject {
    func cancel()
}

@MainActor
struct MainQueueScheduler: Scheduling {
    private final class Work: ScheduledWork {
        let item: DispatchWorkItem
        init(_ item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }

    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor @Sendable () -> Void) -> ScheduledWork {
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return Work(item)
    }
}
