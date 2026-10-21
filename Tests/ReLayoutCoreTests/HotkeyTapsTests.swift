import XCTest
@testable import ReLayoutCore

// Hotkey press counting and modifier-only taps (Core/HotkeyTaps.swift).
final class HotkeyTapsTests: XCTestCase {

    func testASingleTapHotkeyFiresAtOnce() {
        var s = TapSequence()
        XCTAssertTrue(s.activate(at: 0, taps: 1))
    }

    func testADoubleTapFiresOnTheSecondPressWithinTheWindow() {
        var s = TapSequence(window: 0.5)
        XCTAssertFalse(s.activate(at: 0, taps: 2))
        XCTAssertTrue(s.activate(at: 0.4, taps: 2))
        XCTAssertFalse(s.activate(at: 0.6, taps: 2))   // a new sequence starts
        XCTAssertFalse(s.activate(at: 1.3, taps: 2))   // too slow: starts over
        XCTAssertTrue(s.activate(at: 1.5, taps: 2))
    }

    func testATripleTapNeedsAllThree() {
        var s = TapSequence(window: 0.5)
        XCTAssertFalse(s.activate(at: 0, taps: 3))
        XCTAssertFalse(s.activate(at: 0.3, taps: 3))
        XCTAssertTrue(s.activate(at: 0.6, taps: 3))
    }

    private let option = 58, shift = 56, control = 59

    func testACleanModifierTapFires() {
        var t = ModifierTap<Int>(maxHold: 0.6)
        XCTAssertFalse(t.changed(held: [option], chord: [option], at: 0))
        XCTAssertTrue(t.changed(held: [], chord: [option], at: 0.2))
    }

    func testAHeldTooLongIsNoTap() {
        var t = ModifierTap<Int>(maxHold: 0.6)
        _ = t.changed(held: [option], chord: [option], at: 0)
        XCTAssertFalse(t.changed(held: [], chord: [option], at: 0.7))
    }

    func testAKeyDuringTheHoldIsNoTap() {
        // Option+e types é: not the hotkey.
        var t = ModifierTap<Int>()
        _ = t.changed(held: [option], chord: [option], at: 0)
        t.interrupt()
        XCTAssertFalse(t.changed(held: [], chord: [option], at: 0.2))
        // The next clean press works again.
        _ = t.changed(held: [option], chord: [option], at: 1)
        XCTAssertTrue(t.changed(held: [], chord: [option], at: 1.1))
    }

    func testAnExtraModifierPoisonsThePress() {
        // Option+Shift, Shift released first, then Option: no tap of Option.
        var t = ModifierTap<Int>()
        _ = t.changed(held: [option], chord: [option], at: 0)
        _ = t.changed(held: [option, shift], chord: [option], at: 0.1)
        _ = t.changed(held: [option], chord: [option], at: 0.2)
        XCTAssertFalse(t.changed(held: [], chord: [option], at: 0.3))
    }

    func testAChordFiresOnlyWhenAllOfItWasHeld() {
        var t = ModifierTap<Int>()
        _ = t.changed(held: [control], chord: [control, shift], at: 0)
        XCTAssertFalse(t.changed(held: [], chord: [control, shift], at: 0.1))   // Ctrl alone
        _ = t.changed(held: [control], chord: [control, shift], at: 1)
        _ = t.changed(held: [control, shift], chord: [control, shift], at: 1.1)
        _ = t.changed(held: [shift], chord: [control, shift], at: 1.2)            // released one by one
        XCTAssertTrue(t.changed(held: [], chord: [control, shift], at: 1.3))
    }
}
