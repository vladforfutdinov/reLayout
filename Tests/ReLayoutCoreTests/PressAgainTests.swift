import XCTest
@testable import ReLayoutCore

// The press-again record (Core/PressAgain.swift).
final class PressAgainTests: XCTestCase {

    private typealias P = PressAgain<String, String>

    func testThreeLayoutsCycleThenUndo() {
        // "ghbdsn": uk "привіт", then ru "привыт", then back.
        var p = P()
        p.record(Conversion(original: "ghbdsn", typed: "привіт", src: "en",
                            alternatives: [("привыт", "ru")]), since: p.mark)
        guard case .retarget(let erase, let type, let dst, let then)? = p.next() else { return XCTFail("retarget") }
        XCTAssertEqual(erase, 6); XCTAssertEqual(type, "привыт"); XCTAssertEqual(dst, "ru")
        XCTAssertNil(p.next())   // taken
        p.record(then, since: p.mark)
        guard case .undo(let c)? = p.next() else { return XCTFail("undo") }
        XCTAssertEqual(c.original, "ghbdsn"); XCTAssertEqual(c.typed, "привыт"); XCTAssertEqual(c.src, "en")
    }

    func testARetargetKeepsTheSpacesAfterTheWord() {
        var p = P()
        p.record(Conversion(original: "ghbdsn  ", typed: "привіт  ", src: "en",
                            alternatives: [("привыт", "ru")], suffix: "  "), since: p.mark)
        guard case .retarget(let erase, let type, _, _)? = p.next() else { return XCTFail("retarget") }
        XCTAssertEqual(erase, 8); XCTAssertEqual(type, "привыт  ")
    }

    func testAKeyOrClickDuringAConversionKeepsItFromBeingRecorded() {
        var p = P()
        let mark = p.mark
        p.forget()   // a click while the retype was typing
        p.record(Conversion(original: "a", typed: "ф", src: "en"), since: mark)
        XCTAssertNil(p.next())
    }

    func testDropEndsTheRecordButNotAConversionUnderWay() {
        // The key that starts an auto-correction ends the old record; the correction
        // it starts is still recorded.
        var p = P()
        p.record(Conversion(original: "a", typed: "ф", src: "en"), since: p.mark)
        let mark = p.mark
        p.drop()
        XCTAssertNil(p.next())
        p.record(Conversion(original: "b", typed: "и", src: "en"), since: mark)
        guard case .undo(let c)? = p.next() else { return XCTFail("recorded") }
        XCTAssertEqual(c.original, "b")
    }
}
