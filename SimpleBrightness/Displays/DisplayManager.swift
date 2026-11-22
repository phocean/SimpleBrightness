import AppKit
import CoreGraphics

struct DisplayInfo: Equatable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltin: Bool
    let isSupported: Bool
}

/// Display topology: which displays are online, what they are called, which one
/// is under a given point. Purely public CoreGraphics/AppKit API.
@MainActor
final class DisplayManager {
    private(set) var displays: [DisplayInfo] = []
    /// Called (coalesced) when macOS reports a display reconfiguration; the
    /// owner decides how long to let things settle.
    var onReconfiguration: (() -> Void)?

    private let backend: BrightnessBackend?
    private var pendingRefresh: DispatchWorkItem?
    private var isRegistered = false

    init(backend: BrightnessBackend?) {
        self.backend = backend
    }

    func start() {
        guard !isRegistered else { return }
        isRegistered = CGDisplayRegisterReconfigurationCallback(Self.reconfigurationCallback,
                                                                Unmanaged.passUnretained(self).toOpaque()) == .success
        refresh()
    }

    /// Re-enumerates online displays. Built-in first, then left to right.
    func refresh() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return }

        let names = Dictionary(NSScreen.screens.compactMap { screen in
            screen.displayID.map { ($0, screen.localizedName) }
        }, uniquingKeysWith: { first, _ in first })

        displays = ids.prefix(Int(count))
            .sorted { lhs, rhs in
                let lb = CGDisplayIsBuiltin(lhs) != 0, rb = CGDisplayIsBuiltin(rhs) != 0
                if lb != rb { return lb }
                return CGDisplayBounds(lhs).minX < CGDisplayBounds(rhs).minX
            }
            .map { id in
                let builtin = CGDisplayIsBuiltin(id) != 0
                let fallback = builtin
                    ? String(localized: "Built-in Display")
                    : String(localized: "Display \(id)")
                return DisplayInfo(id: id,
                                   name: names[id] ?? fallback,
                                   isBuiltin: builtin,
                                   isSupported: backend?.supports(id) ?? false)
            }
        // IDs only: display names can carry personal data (AirPlay/Sidecar device names).
        Log.displays.info("Displays: \(self.displays.map { "\($0.id) builtin=\($0.isBuiltin) supported=\($0.isSupported)" }.joined(separator: ", "), privacy: .public)")
    }

    /// Displays containing `point` (CoreGraphics global coordinates, origin at
    /// the top-left of the main display). Several when mirrored.
    func displays(at point: CGPoint) -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, UInt32(ids.count), &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// Current pointer location in CoreGraphics global coordinates.
    static func pointerLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onReconfiguration?() }
        pendingRefresh = work
        // Coalesce the burst of callbacks macOS sends for one change.
        DispatchQueue.main.async(execute: work)
    }

    private static let reconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
        guard !flags.contains(.beginConfigurationFlag), let userInfo else { return }
        let manager = Unmanaged<DisplayManager>.fromOpaque(userInfo).takeUnretainedValue()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { manager.scheduleRefresh() }
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}
