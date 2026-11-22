import CoreGraphics
import XCTest
@testable import SimpleBrightness

private let builtin: CGDirectDisplayID = 1
private let studio: CGDirectDisplayID = 2

// MARK: - Basics, sync, echoes

@MainActor
final class BrightnessControllerTests: XCTestCase {
    func testLaunchWritesNothing() {
        let rig = Rig()
        XCTAssertTrue(rig.writer.writes.isEmpty)
        XCTAssertEqual(rig.controller.value(of: builtin), 0.5)
        XCTAssertEqual(rig.backend.observed, [builtin, studio])
    }

    func testRestoringSyncAtLaunchDoesNotAlign() {
        let rig = Rig()
        rig.controller.setSyncOffset(0.1)
        rig.controller.setSyncEnabled(true, reference: nil)
        XCTAssertTrue(rig.writer.writes.isEmpty)
    }

    func testIndependentWhenSyncOff() {
        let rig = Rig()
        rig.controller.setBrightness(0.8, for: builtin)
        XCTAssertEqual(rig.writer.displays, [builtin])
        rig.deliverEchoes()
        rig.externalChange(studio, 0.1)
        XCTAssertTrue(rig.writer.writes.isEmpty)
        XCTAssertEqual(rig.controller.value(of: builtin), 0.8)
    }

    func testEnablingSyncAlignsOnReference() {
        let rig = Rig()
        rig.controller.setSyncEnabled(true, reference: studio)
        XCTAssertEqual(rig.writer.writes.map(\.display), [builtin])
        XCTAssertEqual(rig.writer.writes.first?.value, 0.3)
    }

    func testUserChangePropagatesWithoutLoop() {
        let rig = Rig()
        rig.controller.setSyncEnabled(true, reference: nil)
        rig.controller.setBrightness(0.7, for: builtin)
        XCTAssertEqual(Set(rig.writer.displays), [builtin, studio])
        for _ in 0..<5 { rig.deliverEchoes() }
        XCTAssertTrue(rig.writer.writes.isEmpty)
    }

    func testExternalChangePropagatesBothWays() {
        let rig = Rig()
        rig.controller.setSyncEnabled(true, reference: nil)
        rig.externalChange(studio, 0.9)
        XCTAssertEqual(rig.writer.writes.map(\.display), [builtin])
        XCTAssertEqual(rig.writer.writes.first?.value, 0.9)
        rig.deliverEchoes()
        rig.scheduler.advance(by: 5)
        rig.externalChange(builtin, 0.2)
        XCTAssertEqual(rig.writer.writes.map(\.display), [studio])
        rig.deliverEchoes()
        XCTAssertTrue(rig.writer.writes.isEmpty)
    }

    func testRampingPanelIsNotMistakenForExternalChange() {
        let rig = Rig()
        rig.controller.setSyncEnabled(true, reference: nil)
        rig.controller.setBrightness(1.0, for: builtin)
        rig.writer.writes.removeAll()
        for value in [0.6, 0.75, 0.9, 1.0] { rig.controller.hardwareDidChange(builtin, value) }
        XCTAssertTrue(rig.writer.writes.isEmpty)
    }

    func testRoundingPanelsConvergeAndEndAligned() {
        let rig = Rig()
        rig.controller.setSyncEnabled(true, reference: nil)
        rig.externalChange(builtin, 0.333)
        var rounds = 0
        while !rig.writer.writes.isEmpty && rounds < 10 {
            rig.deliverEchoes { display, value in
                let grid = display == studio ? 20.0 : 16.0
                return (value * grid).rounded() / grid
            }
            rig.scheduler.advance(by: 0.1)
            rounds += 1
        }
        XCTAssertLessThan(rounds, 10)
        XCTAssertEqual(rig.controller.value(of: studio)!, rig.controller.value(of: builtin)!, accuracy: 0.05)
    }

    func testExternalChangeAfterEchoWindowPropagates() {
        let rig = Rig()
        rig.controller.setSyncEnabled(true, reference: nil)
        rig.controller.setBrightness(0.7, for: builtin)
        rig.deliverEchoes()
        rig.scheduler.advance(by: BrightnessController.echoWindow + 0.5)
        rig.externalChange(builtin, 0.6)
        XCTAssertEqual(rig.writer.displays, [studio])
    }

    /// Audit finding 1: a genuine change inside a recent echo range is first
    /// swallowed, then caught by the read when the echo window closes.
    func testExternalChangeInsideEchoRangeIsReconciled() {
        let rig = Rig()
        rig.controller.setSyncEnabled(true, reference: nil)
        rig.controller.setBrightness(0.8, for: builtin)           // range [0.5, 0.8]
        rig.deliverEchoes()
        rig.scheduler.advance(by: 1)
        rig.externalChange(builtin, 0.6)                           // Control Center, inside the range
        XCTAssertTrue(rig.writer.writes.isEmpty, "looks like an echo at first")
        XCTAssertEqual(rig.controller.value(of: builtin), 0.8)
        rig.scheduler.advance(by: BrightnessController.echoWindow)
        XCTAssertEqual(rig.controller.value(of: builtin), 0.6)
        XCTAssertEqual(rig.writer.writes, [.init(display: studio, value: 0.6, generation: 2)])
    }

    func testReconcileWithNothingNewDoesNothing() {
        let rig = Rig()
        rig.controller.setSyncEnabled(true, reference: nil)
        rig.controller.setBrightness(0.8, for: builtin)
        rig.deliverEchoes()
        rig.scheduler.advance(by: 10)
        XCTAssertTrue(rig.writer.writes.isEmpty)
    }

    func testSuspendedSyncDoesNotPropagate() {
        let rig = Rig()
        rig.controller.setSyncEnabled(true, reference: nil)
        rig.controller.isSuspended = true
        rig.externalChange(studio, 0.9)
        rig.controller.setBrightness(0.1, for: builtin)
        XCTAssertEqual(rig.writer.displays, [builtin])
    }

    func testUnplugAndReplugReadsButDoesNotWrite() {
        let rig = Rig()
        rig.controller.updateDisplays([builtin], builtin: [builtin])
        XCTAssertFalse(rig.controller.isSupported(studio))
        XCTAssertEqual(rig.backend.observed, [builtin])
        XCTAssertEqual(rig.writer.cancelled, [studio])
        rig.backend.hardware[studio] = 0.65
        rig.controller.updateDisplays([builtin, studio], builtin: [builtin])
        XCTAssertEqual(rig.controller.value(of: studio), 0.65)
        XCTAssertTrue(rig.writer.writes.isEmpty)
    }

    func testSteps() {
        typealias C = BrightnessController
        XCTAssertEqual(C.stepped(from: 0.5, direction: .up, fine: false), 0.5625)
        XCTAssertEqual(C.stepped(from: 0.5, direction: .down, fine: false), 0.4375)
        XCTAssertEqual(C.stepped(from: 0.30, direction: .up, fine: false), 0.3125)
        XCTAssertEqual(C.stepped(from: 0.30, direction: .down, fine: false), 0.25)
        XCTAssertEqual(C.stepped(from: 1.0, direction: .up, fine: false), 1.0)
        XCTAssertEqual(C.stepped(from: 0.0, direction: .down, fine: false), 0.0)
        XCTAssertEqual(C.stepped(from: 0.5, direction: .up, fine: true), 0.515625)
        XCTAssertEqual(C.stepped(from: 0.3750001, direction: .up, fine: false), 0.4375)
        XCTAssertEqual(C.steppedRaw(from: 1.0, direction: .up, fine: false), 1.0625)
    }
}

// MARK: - Robustness (audit 2026-11-22)

@MainActor
final class BrightnessControllerRobustnessTests: XCTestCase {
    func testLateEchoDoesNotRewindKeySteps() {
        let rig = Rig()
        rig.controller.step(.up, fine: false, on: [builtin])       // 0.5625
        rig.controller.step(.up, fine: false, on: [builtin])       // 0.625
        rig.controller.hardwareDidChange(builtin, 0.5625)          // late echo of the first press
        XCTAssertEqual(rig.controller.step(.up, fine: false, on: [builtin]), 0.6875)
    }

    /// Finding 3: bogus values while displays settle never reach the cache.
    func testNotificationsIgnoredWhileSettling() {
        let rig = Rig()
        rig.controller.setSyncEnabled(true, reference: nil)
        rig.controller.isSettling = true
        rig.controller.isSuspended = true
        rig.controller.hardwareDidChange(builtin, 1.0)             // bogus "100 %"
        XCTAssertEqual(rig.controller.value(of: builtin), 0.5)
        rig.controller.isSettling = false
        rig.controller.isSuspended = false
        XCTAssertTrue(rig.writer.writes.isEmpty)
    }

    func testRefreshReadsHardwareBeforeStep() {
        let rig = Rig()
        rig.backend.hardware[builtin] = 0.25                       // changed behind our back
        rig.controller.refresh([builtin])
        XCTAssertEqual(rig.controller.step(.up, fine: false, on: [builtin]), 0.3125)
    }

    /// Finding 4: a failure report older than the latest write is ignored.
    func testStaleWriteFailureIsIgnored() {
        let rig = Rig()
        rig.controller.setBrightness(0.8, for: builtin)            // generation 1
        rig.controller.setBrightness(0.9, for: builtin)            // generation 2
        rig.controller.writeDidFail(on: builtin, generation: 1)
        XCTAssertEqual(rig.controller.value(of: builtin), 0.9)
    }

    func testCurrentWriteFailureRealignsTheGroup() {
        let rig = Rig()
        rig.controller.setSyncEnabled(true, reference: nil)
        rig.controller.setSyncEnabled(true, reference: builtin)    // both at 0.5
        rig.deliverEchoes()
        rig.controller.setBrightness(0.8, for: builtin)
        let failed = rig.writer.writes.first { $0.display == builtin }!
        rig.writer.writes.removeAll()
        rig.controller.writeDidFail(on: builtin, generation: failed.generation)   // panel stayed at 0.5
        XCTAssertEqual(rig.controller.value(of: builtin), 0.5)
        XCTAssertEqual(rig.controller.value(of: studio), 0.5, "the group follows what the panel really has")
    }

    /// Finding 5: a display whose read fails is dropped completely.
    func testUnreadableDisplayIsDroppedCompletely() {
        let rig = Rig()
        rig.backend.unreadable = [studio]
        rig.controller.updateDisplays([builtin, studio], builtin: [builtin], resubscribe: true)
        XCTAssertFalse(rig.controller.isSupported(studio))
        XCTAssertEqual(rig.controller.displays, [builtin])
        XCTAssertFalse(rig.backend.observed.contains(studio))
        XCTAssertTrue(rig.writer.cancelled.contains(studio))
    }

    func testFailedObservationIsReported() {
        let rig = Rig()
        rig.backend.refusesObservation = [studio]
        rig.controller.updateDisplays([builtin, studio], builtin: [builtin], resubscribe: true)
        XCTAssertTrue(rig.controller.isSupported(studio))
        XCTAssertTrue(rig.controller.hasUnobservedDisplays)
        rig.backend.refusesObservation = []
        rig.controller.updateDisplays([builtin, studio], builtin: [builtin], resubscribe: true)
        XCTAssertFalse(rig.controller.hasUnobservedDisplays)
    }

    /// Finding 14: NaN never enters the cache, the offset or a write.
    func testNaNIsRejected() {
        let rig = Rig()
        rig.controller.setSyncEnabled(true, reference: nil)
        rig.controller.hardwareDidChange(builtin, .nan)
        rig.controller.setBrightness(.nan, for: builtin)
        rig.controller.setSyncOffset(.nan)
        XCTAssertEqual(rig.controller.value(of: builtin), 0.5)
        XCTAssertEqual(rig.controller.syncOffset, 0)
        XCTAssertTrue(rig.writer.writes.isEmpty)
    }

    func testResetEchoesCancelsReconcile() {
        let rig = Rig()
        rig.controller.setBrightness(0.8, for: builtin)
        rig.controller.resetEchoes()
        rig.backend.hardware[builtin] = 0.2
        rig.scheduler.advance(by: 10)
        XCTAssertEqual(rig.controller.value(of: builtin), 0.8, "no reconcile after a reset")
    }
}

// MARK: - Offset

@MainActor
final class SyncOffsetTests: XCTestCase {
    private func syncedRig(builtin b: Double = 0.5, studio s: Double = 0.5, offset: Double) -> Rig {
        let rig = Rig(builtin: b, studio: s)
        rig.controller.setSyncOffset(offset)
        rig.controller.setSyncEnabled(true, reference: nil)
        rig.controller.setSyncOffset(offset)                       // align now that sync is on
        rig.deliverEchoes()
        return rig
    }

    func testOffsetAppliesToExternalOnly() {
        let rig = syncedRig(offset: 0.1)
        XCTAssertEqual(rig.controller.value(of: studio)!, 0.6, accuracy: 1e-9)
        XCTAssertEqual(rig.controller.value(of: builtin), 0.5)
    }

    func testOffsetWorksBothWays() {
        let rig = syncedRig(offset: -0.1)
        rig.controller.setBrightness(0.8, for: builtin)
        XCTAssertEqual(rig.controller.value(of: studio)!, 0.7, accuracy: 1e-9)
        rig.deliverEchoes()
        rig.scheduler.advance(by: 5)
        rig.externalChange(studio, 0.3)
        XCTAssertEqual(rig.controller.value(of: builtin)!, 0.4, accuracy: 1e-9)
    }

    func testOffsetIsClamped() {
        let rig = syncedRig(offset: 0.2)
        rig.controller.setBrightness(0.95, for: builtin)
        XCTAssertEqual(rig.controller.value(of: studio), 1.0)
        rig.controller.setSyncOffset(5)
        XCTAssertEqual(rig.controller.syncOffset, BrightnessController.maxSyncOffset)
    }

    /// Finding 9: an external display pinned at 100 % must not make the next step
    /// jump on the built-in one.
    func testStepNearTheTopKeepsTheRelation() {
        let rig = syncedRig(offset: 0.1)
        rig.controller.setBrightness(0.95, for: builtin)           // studio pinned at 1.0
        rig.deliverEchoes()
        rig.controller.step(.down, fine: false, on: [studio])
        XCTAssertEqual(rig.controller.value(of: builtin)!, 0.9375, accuracy: 1e-9, "one step, not −11 %")
        XCTAssertEqual(rig.controller.value(of: studio), 1.0)
        rig.deliverEchoes()
        rig.controller.step(.down, fine: false, on: [studio])
        XCTAssertEqual(rig.controller.value(of: builtin)!, 0.875, accuracy: 1e-9)
        XCTAssertEqual(rig.controller.value(of: studio)!, 0.975, accuracy: 1e-9)
    }

    /// Finding 10: mirrored targets with an offset move up together.
    func testMirroredStepWithOffsetNeverGoesBackwards() {
        let rig = syncedRig(offset: 0.1)                           // 0.5 / 0.6
        rig.controller.step(.up, fine: false, on: [builtin, studio])
        XCTAssertEqual(rig.controller.value(of: builtin)!, 0.5625, accuracy: 1e-9)
        XCTAssertEqual(rig.controller.value(of: studio)!, 0.6625, accuracy: 1e-9)
    }

    func testOffsetEchoesDoNotLoop() {
        let rig = syncedRig(offset: 0.1)
        rig.controller.setBrightness(0.3, for: studio)
        for _ in 0..<3 { rig.deliverEchoes() }
        XCTAssertTrue(rig.writer.writes.isEmpty)
        XCTAssertEqual(rig.controller.value(of: builtin)!, 0.2, accuracy: 1e-9)
    }

    func testOffsetNeedsBuiltinAndExternal() {
        let rig = syncedRig(offset: 0.1)
        XCTAssertTrue(rig.controller.canUseSyncOffset)
        rig.controller.updateDisplays([studio], builtin: [])
        XCTAssertFalse(rig.controller.canUseSyncOffset)
    }
}
