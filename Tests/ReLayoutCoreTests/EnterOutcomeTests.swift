import XCTest
@testable import ReLayoutCore

// Snapshots modeled on real AX reads (TextEdit, Notes, Telegram) of "test" + Return.
final class EnterOutcomeTests: XCTestCase {

    func snap(_ count: Int, _ caret: Int, _ tail: String, sel: Int = 0) -> FieldSnapshot {
        FieldSnapshot(count: count, caret: caret, selected: sel, tail: tail)
    }

    func testNewlineWithSystemCapitalization() {
        XCTAssertEqual(enterOutcome(before: snap(4, 4, "test"), after: snap(5, 5, "Test\n"), word: "test"), .newline)
    }

    func testShiftReturnNewlineInChat() {
        XCTAssertEqual(enterOutcome(before: snap(5, 5, "ttest"), after: snap(6, 6, "ttest\n"), word: "ttest"), .newline)
    }

    func testCarriageReturnCountsAsNewline() {
        XCTAssertEqual(enterOutcome(before: snap(4, 4, "test"), after: snap(5, 5, "test\r"), word: "test"), .newline)
    }

    func testNewlineInsideText() {
        XCTAssertEqual(enterOutcome(before: snap(30, 12, "notes: ghbdtn"), after: snap(31, 13, "notes: ghbdtn\n"),
                                    word: "ghbdtn"), .newline)
    }

    func testWordWithPunctuationTrail() {
        XCTAssertEqual(enterOutcome(before: snap(7, 7, "ghbdtn?"), after: snap(8, 8, "Ghbdtn?\n"), word: "ghbdtn?"),
                       .newline)
    }

    func testSubmitEmptiesField() {
        XCTAssertEqual(enterOutcome(before: snap(4, 4, "test"), after: snap(0, 0, ""), word: "test"), .submitted)
    }

    func testNotChangedYet() {
        XCTAssertEqual(enterOutcome(before: snap(4, 4, "test"), after: snap(4, 4, "test"), word: "test"), .unknown)
    }

    func testAutoIndentOrListMarkerIsUnknown() {
        XCTAssertEqual(enterOutcome(before: snap(4, 4, "test"), after: snap(7, 7, "test\n  "), word: "test"), .unknown)
        XCTAssertEqual(enterOutcome(before: snap(4, 4, "test"), after: snap(5, 5, "test "), word: "test"), .unknown)
    }

    func testAutocorrectReplacedWordIsUnknown() {
        XCTAssertEqual(enterOutcome(before: snap(4, 4, "tset"), after: snap(5, 5, "test\n"), word: "tset"), .unknown)
    }

    func testSelectionBeforeReturnIsUnknown() {
        XCTAssertEqual(enterOutcome(before: snap(8, 4, "test", sel: 4), after: snap(5, 5, "test\n"), word: "test"),
                       .unknown)
    }

    func testWordNotAtCaretIsUnknown() {
        XCTAssertEqual(enterOutcome(before: snap(6, 6, "test x"), after: snap(7, 7, "test x\n"), word: "test"), .unknown)
    }

    func testCaretJumpedIsUnknown() {
        XCTAssertEqual(enterOutcome(before: snap(4, 4, "test"), after: snap(5, 1, "\n"), word: "test"), .unknown)
    }

    func testFieldKeptTextAfterSendIsUnknown() {
        XCTAssertEqual(enterOutcome(before: snap(4, 4, "test"), after: snap(4, 0, ""), word: "test"), .unknown)
    }

    func testEmptyWordIsUnknown() {
        XCTAssertEqual(enterOutcome(before: snap(0, 0, ""), after: snap(1, 1, "\n"), word: ""), .unknown)
    }

    func testWindowShorterThanWordIsUnknown() {
        XCTAssertEqual(enterOutcome(before: snap(10, 10, "dtn"), after: snap(11, 11, "dtn\n"), word: "ghbdtn"), .unknown)
    }
}
