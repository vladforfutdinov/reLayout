import XCTest
@testable import ReLayoutCore

// The asynchronous password-field check (Core/FieldCheck.swift).
final class FieldCheckTests: XCTestCase {

    func testAnAnswerUnblocks() {
        var c = FieldCheck()
        let q = c.needed()
        XCTAssertNotNil(q)
        XCTAssertTrue(c.blocks)          // pending: nothing is corrected
        XCTAssertFalse(c.dropsKeys)      // but keys are kept
        XCTAssertNil(c.answered(false, for: q!))
        XCTAssertFalse(c.blocks)
    }

    func testAStaleAnswerAsksAgain() {
        // Word in field A asks; the user moves to field B and starts a word before
        // A's answer lands: that answer must not clear B.
        var c = FieldCheck()
        let a = c.needed()!
        XCTAssertNil(c.needed())                 // one on its way already
        let again = c.answered(false, for: a)    // A's "no" is stale
        XCTAssertNotNil(again)
        XCTAssertTrue(c.blocks)
        XCTAssertNil(c.answered(true, for: again!))
        XCTAssertTrue(c.blocks); XCTAssertTrue(c.dropsKeys)
    }

    func testASynchronousReadMakesTheOneInFlightStale() {
        var c = FieldCheck()
        let q = c.needed()!
        c.set(true)
        XCTAssertNotNil(c.answered(false, for: q))   // not trusted
        XCTAssertTrue(c.value)
    }

    func testInvalidateFailsClosed() {
        var c = FieldCheck()
        _ = c.answered(false, for: c.needed()!)
        c.invalidate()   // a replayed Tab: focus may have moved
        XCTAssertTrue(c.blocks)
        XCTAssertNotNil(c.needed())   // the next word asks
    }

    func testAnUnsentQuestionCanBeAskedAgain() {
        var c = FieldCheck()
        _ = c.needed()
        c.unsent()
        XCTAssertNotNil(c.needed())
    }
}
