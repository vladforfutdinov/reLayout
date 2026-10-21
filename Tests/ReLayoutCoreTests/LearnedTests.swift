import XCTest
@testable import ReLayoutCore

// The learned-verdict rules both apps apply (Core/Learned.swift).
final class LearnedTests: XCTestCase {

    func testAMissCountedEnoughTimesBecomesAConversion() {
        var l = LearnedWords(keep: ["ghbdtn"])
        for i in 1..<autoLearnRepeats {
            XCTAssertEqual(l.count(misses: ["ghbdtn"], replaced: "ghbdtn", out: "привет"), [])
            XCTAssertEqual(l.counts["ghbdtn"], i)
        }
        XCTAssertFalse(l.keep.contains("ghbdtn"))   // a hotkey correction overrides a keep
        XCTAssertEqual(l.count(misses: ["ghbdtn"], replaced: "ghbdtn", out: "привет"), ["ghbdtn"])
        XCTAssertEqual(l.verdict("ghbdtn"), .convert)
        XCTAssertNil(l.counts["ghbdtn"])
        XCTAssertNil(l.candidates["ghbdtn"])
    }

    func testMissesPairWithTheirOwnOutputWord() {
        var l = LearnedWords()
        l.count(misses: ["rfr"], replaced: "ghbdtn rfr", out: "привет как")
        XCTAssertEqual(l.candidates["rfr"], "как")
    }

    func testUndoTakesBackACountOrAPromotion() {
        var l = LearnedWords(convert: ["a": "б"], counts: ["c": 2], candidates: ["c": "д"])
        l.unlearn(learned: ["a", "c"], autoWords: [])
        XCTAssertNil(l.verdict("a"))
        XCTAssertEqual(l.counts["c"], 1)
        l.unlearn(learned: ["c"], autoWords: [])
        XCTAssertNil(l.counts["c"])
        XCTAssertNil(l.candidates["c"])
    }

    func testUndoingAnAutoCorrectionKeepsTheWord() {
        var l = LearnedWords(convert: ["ghbdtn": "привет"])
        l.unlearn(learned: [], autoWords: ["ghbdtn", ""])
        XCTAssertEqual(l.verdict("ghbdtn"), .keep)
        XCTAssertFalse(l.keep.contains(""))
    }

    func testPromoteDemoteForget() {
        var l = LearnedWords(counts: ["x": 1], candidates: ["x": "ч"])
        l.promote("x", to: "ч")
        XCTAssertEqual(l, LearnedWords(convert: ["x": "ч"]))
        l.demote("x")
        XCTAssertEqual(l, LearnedWords(counts: ["x": 1], candidates: ["x": "ч"]))
        l.promote("x", to: "")
        XCTAssertEqual(l, LearnedWords(keep: ["x"]))
        l.demote("x")
        XCTAssertEqual(l.candidates["x"], "")   // a keep candidate
        l.forget(["x"])
        XCTAssertEqual(l, LearnedWords())
    }
}
