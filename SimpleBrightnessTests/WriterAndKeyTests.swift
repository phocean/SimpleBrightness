import CoreGraphics
import XCTest
@testable import SimpleBrightness

final class CoalescingWriterTests: XCTestCase {
    /// Thread-safe log of the values the "hardware" received.
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []
        func append(_ value: Double) { lock.withLock { values.append(value) } }
        var all: [Double] { lock.withLock { values } }
    }

    func testOnlyTheLatestPendingValueIsWritten() {
        let log = Log()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let writer = CoalescingWriter(minInterval: 0) { _, value in
            log.append(value)
            if value == 0.1 { started.signal(); release.wait() }
            return true
        }
        writer.submit(0.1, for: 1, generation: 1)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        for (index, value) in [0.2, 0.3, 0.4].enumerated() {
            writer.submit(value, for: 1, generation: index + 2)
        }
        release.signal()
        let done = expectation(description: "drained")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(log.all, [0.1, 0.4])
    }

    func testCancelPendingDropsQueuedWrites() {
        let log = Log()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let writer = CoalescingWriter(minInterval: 0) { _, value in
            log.append(value)
            if value == 0.1 { started.signal(); release.wait() }
            return true
        }
        writer.submit(0.1, for: 1, generation: 1)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        writer.submit(0.9, for: 1, generation: 2)
        writer.cancelPending(for: 1)
        release.signal()
        let done = expectation(description: "drained")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(log.all, [0.1], "a write in progress completes; the queued one is dropped")
    }

    @MainActor
    func testFailureReportsItsGeneration() {
        let writer = CoalescingWriter(minInterval: 0) { _, _ in false }
        let reported = expectation(description: "failure")
        writer.onFailure = { display, generation in
            XCTAssertEqual(display, 7)
            XCTAssertEqual(generation, 42)
            reported.fulfill()
        }
        writer.submit(0.5, for: 7, generation: 42)
        wait(for: [reported], timeout: 2)
    }
}

final class KeyDecodingTests: XCTestCase {
    private func data1(key: Int, state: Int, repeat isRepeat: Bool = false) -> Int {
        (key << 16) | (state << 8) | (isRepeat ? 1 : 0)
    }

    func testBrightnessUpDown() {
        let up = BrightnessKeyTap.decode(data1: data1(key: 2, state: 0x0A))
        XCTAssertEqual(up.direction, .up)
        XCTAssertEqual(up.phase, .down)
        let down = BrightnessKeyTap.decode(data1: data1(key: 3, state: 0x0B))
        XCTAssertEqual(down.direction, .down)
        XCTAssertEqual(down.phase, .up)
    }

    func testRepeatFlag() {
        XCTAssertTrue(BrightnessKeyTap.decode(data1: data1(key: 2, state: 0x0A, repeat: true)).isRepeat)
    }

    func testOtherMediaKeysAreNotBrightness() {
        // NX_KEYTYPE_SOUND_UP = 0, NX_KEYTYPE_PLAY = 16: must be returned to macOS.
        XCTAssertNil(BrightnessKeyTap.decode(data1: data1(key: 0, state: 0x0A)).direction)
        XCTAssertNil(BrightnessKeyTap.decode(data1: data1(key: 16, state: 0x0A)).direction)
    }

    func testUnknownStateIsOther() {
        XCTAssertEqual(BrightnessKeyTap.decode(data1: data1(key: 2, state: 0x01)).phase, .other)
    }
}
