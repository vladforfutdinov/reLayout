import XCTest
@testable import ReLayoutCore

// The keystroke gate around a correction (Core/KeyGate.swift), including the
// watchdog no end-to-end run can reach without breaking the app on purpose.
final class KeyGateTests: XCTestCase {

    func testAnOpenGatePassesKeys() {
        var g = KeyGate<String>()
        guard case .pass = g.key("a", at: 0) else { return XCTFail("open gate must pass") }
        XCTAssertTrue(g.held.isEmpty)
    }

    func testKeysAreHeldAndReplayedInOrder() {
        var g = KeyGate<String>()
        g.close(at: 10)
        for (k, t) in [("r", 10.1), ("f", 10.2), ("r", 10.3)] {
            guard case .hold = g.key(k, at: t) else { return XCTFail("\(k) must be held") }
        }
        XCTAssertEqual([g.nextToReplay(at: 11), g.nextToReplay(at: 11), g.nextToReplay(at: 11)], ["r", "f", "r"])
        XCTAssertNil(g.nextToReplay(at: 11))
        XCTAssertTrue(g.isClosed)   // the caller opens it once nothing is left
    }

    func testAStuckCorrectionReleasesEverythingInOrder() {
        var g = KeyGate<String>(maxHold: 3)
        g.close(at: 0)
        _ = g.key("a", at: 1)
        _ = g.key("b", at: 2)
        guard case .release(let keys) = g.key("c", at: 3.5) else { return XCTFail("overdue must release") }
        XCTAssertEqual(keys, ["a", "b", "c"])   // nothing lost, nothing reordered
        XCTAssertFalse(g.isClosed)
        XCTAssertTrue(g.held.isEmpty)
        guard case .pass = g.key("d", at: 3.6) else { return XCTFail("the gate is open again") }
    }

    func testTheClockRestartsWithEachReplayedKey() {
        // A long replay is progress, not a stuck correction.
        var g = KeyGate<String>(maxHold: 3)
        g.close(at: 0)
        _ = g.key("a", at: 0.5)
        _ = g.key("b", at: 0.6)
        XCTAssertEqual(g.nextToReplay(at: 2.9), "a")
        guard case .hold = g.key("c", at: 5) else { return XCTFail("within 3 s of the last replayed key") }
    }

    func testANewCorrectionRestartsTheClock() {
        var g = KeyGate<String>(maxHold: 3)
        g.close(at: 0)
        g.close(at: 2.5)
        guard case .hold = g.key("a", at: 5) else { return XCTFail("counted from the newer correction") }
    }

    func testBackspaceUntypesAHeldKey() {
        var g = KeyGate<String>()
        g.close(at: 0)
        _ = g.key("a", at: 0.1)
        _ = g.key("b", at: 0.2)
        XCTAssertTrue(g.backspace(wide: false))
        XCTAssertEqual(g.held, ["a"])
        XCTAssertFalse(g.backspace(wide: true))   // a wide delete goes on to the app
        XCTAssertTrue(g.held.isEmpty)
        XCTAssertFalse(g.backspace(wide: false))  // nothing held: the app gets it
    }
}
