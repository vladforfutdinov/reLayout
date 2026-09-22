import XCTest
@testable import ReLayoutCore

// The auto mode's typed-word run: what it buffers, when it ends, and which
// corrections the short-word rule lets through. Shared by macOS and Windows.
final class AutoRunTests: XCTestCase {

    private let noCyr: (Character) -> Bool = { _ in false }

    private func type(_ text: String, into run: inout AutoRun,
                      mapsToCyrillic: (Character) -> Bool = { _ in false }) -> [AutoRun.Event] {
        text.map { run.feed(String($0), mapsToCyrillic: mapsToCyrillic) }.filter { $0 != .none }
    }

    func testSpaceEndsAWordAndKeepsThePreviousOne() {
        var run = AutoRun()
        XCTAssertEqual(type("ghbdtn ", into: &run), [.boundary(word: "ghbdtn", trail: "")])
        XCTAssertEqual(run.word, "")
    }

    func testHotkeyTargetSurvivesSpacesUntilTheNextKey() {
        var run = AutoRun()
        _ = type("ghbdtn", into: &run)
        XCTAssertTrue(run.hotkeyTarget == ("ghbdtn", 0))
        _ = type("?  ", into: &run)
        XCTAssertTrue(run.hotkeyTarget == ("ghbdtn?", 2))
        _ = type("v", into: &run)
        XCTAssertTrue(run.hotkeyTarget == ("v", 0))
        _ = type(" \t", into: &run)
        XCTAssertTrue(run.hotkeyTarget == ("", 0))
    }

    func testBackspacingTheSpacesRejoinsTheWord() {
        var run = AutoRun()
        _ = type("ghbdtn  ", into: &run)
        run.backspace(wide: false)
        XCTAssertTrue(run.hotkeyTarget == ("ghbdtn", 1))
        run.backspace(wide: false)
        XCTAssertEqual(run.word, "ghbdtn")
        XCTAssertNil(run.previous)
    }

    func testAFixedWordIsNoLongerTheHotkeyTarget() {
        var run = AutoRun()
        _ = type("ghbdtn ", into: &run)
        XCTAssertNotNil(run.plan(raw: "ghbdtn", out: "привет", cyrillic: true))
        XCTAssertTrue(run.hotkeyTarget == ("", 0))
    }

    func testPunctuationTrailsTheWord() {
        var run = AutoRun()
        XCTAssertEqual(type("ltkfq? ", into: &run), [.boundary(word: "ltkfq", trail: "?")])
    }

    func testALetterAfterTheTrailStartsANewRun() {
        var run = AutoRun()
        _ = type("a?b", into: &run)
        XCTAssertEqual(run.word, "b")
        XCTAssertEqual(run.trail, "")
    }

    func testMappedPunctuationIsWordMaterial() {
        var run = AutoRun()
        let comma: (Character) -> Bool = { $0 == "," }
        XCTAssertEqual(type(",skj ", into: &run, mapsToCyrillic: comma), [.boundary(word: ",skj", trail: "")])
    }

    func testDigitEndsTheRun() {
        var run = AutoRun()
        _ = type("abc1", into: &run)
        XCTAssertEqual(run.word, "")
    }

    func testAKeyThatTypesNothingKeepsTheRun() {
        var run = AutoRun()
        _ = type("ghj", into: &run)
        XCTAssertEqual(run.feed("", mapsToCyrillic: noCyr), .none)
        XCTAssertEqual(run.word, "ghj")
    }

    func testReturnEndsTheRunAndDropsThePreviousWord() {
        var run = AutoRun()
        _ = run.plan(raw: "d", out: "в", cyrillic: true)
        XCTAssertEqual(type("ghbdtn\r", into: &run), [.enter(word: "ghbdtn", trail: "")])
        XCTAssertNil(run.previous)
    }

    func testBackspaceEditsTheWord() {
        var run = AutoRun()
        _ = type("ghbx", into: &run)
        run.backspace(wide: false)
        XCTAssertEqual(run.word, "ghb")
        _ = type("?", into: &run)
        run.backspace(wide: false)
        XCTAssertEqual(run.trail, "")
        XCTAssertEqual(run.word, "ghb")
    }

    func testWideBackspaceEndsTheRun() {
        var run = AutoRun()
        _ = type("ghb", into: &run)
        run.backspace(wide: true)
        XCTAssertEqual(run.word, "")
    }

    func testLongWordIsFixedAlone() {
        var run = AutoRun()
        XCTAssertEqual(run.plan(raw: "ghbdtn", out: "привет", cyrillic: true),
                       AutoRun.Fix(erase: 6, text: "привет", original: "ghbdtn"))
    }

    func testShortWordWaitsThenJoinsTheNextLongOne() {
        var run = AutoRun()
        XCTAssertNil(run.plan(raw: "d", out: "в", cyrillic: true))
        XCTAssertEqual(run.plan(raw: "ljhjut", out: "дороге", cyrillic: true),
                       AutoRun.Fix(erase: 8, text: "в дороге", original: "d ljhjut"))   // "d " + "ljhjut"
    }

    func testShortWordAfterACommittedOneIsFixed() {
        var run = AutoRun()
        _ = run.plan(raw: "ghbdtn", out: "привет", cyrillic: true)
        XCTAssertEqual(run.plan(raw: "yf", out: "на", cyrillic: true), AutoRun.Fix(erase: 2, text: "на", original: "yf"))
    }

    func testShortWordOfTheOtherScriptIsNotSwallowed() {
        var run = AutoRun()
        XCTAssertNil(run.plan(raw: "d", out: "в", cyrillic: true))
        XCTAssertEqual(run.plan(raw: "ghbdtn", out: "hello", cyrillic: false),
                       AutoRun.Fix(erase: 6, text: "hello", original: "ghbdtn"))
    }

    func testTrailingMappedCharDoesNotCountTowardsTrust() {
        XCTAssertEqual(wordBody("vs."), 2)
        var run = AutoRun()
        XCTAssertNil(run.plan(raw: "vs.", out: "мію", cyrillic: true))
    }

    func testSettledFieldNeedsThreeEqualReads() {
        let before = FieldSnapshot(count: 6, caret: 6, tail: "ghbdtn")
        let after = FieldSnapshot(count: 7, caret: 7, tail: "ghbdtn\n")
        var reads = [before, after, after, after, after][...]
        let settled = awaitSettledField(before: before, read: { reads.popFirst() }, wait: { _ in })
        XCTAssertEqual(settled, after)
    }

    func testFieldThatNeverChangesDoesNotSettle() {
        let before = FieldSnapshot(count: 6, caret: 6, tail: "ghbdtn")
        XCTAssertNil(awaitSettledField(before: before, read: { before }, wait: { _ in }))
    }

    func testNewDefaultExclusionsReachASavedList() {
        let merged = mergeExclusions(saved: ["terminal"], defaults: ["terminal", "editor", "vm"],
                                     seen: ["terminal", "editor"])
        // "editor" was seen and removed by the user; only the new "vm" is added.
        XCTAssertEqual(merged, ["terminal", "vm"])
    }

    func testMergeAddsNothingTwice() {
        XCTAssertEqual(mergeExclusions(saved: ["vm"], defaults: ["vm"], seen: []), ["vm"])
    }

    func testNewerVersion() {
        XCTAssertTrue(isNewerVersion("v1.3.0", than: "1.2.27"))
        XCTAssertTrue(isNewerVersion("v1.2.28", than: "1.2.27"))
        XCTAssertTrue(isNewerVersion("v1.3", than: "1.2.27"))
        XCTAssertFalse(isNewerVersion("v1.2.27", than: "1.2.27"))
        XCTAssertFalse(isNewerVersion("v1.2.9", than: "1.2.27"))      // numeric, not string order
        XCTAssertFalse(isNewerVersion("v2.0.0-beta", than: "1.2.27"))  // pre-release: never offered
        XCTAssertFalse(isNewerVersion("v9.9.9", than: "0.0.0-dev"))    // dev build: never checks
    }
}
