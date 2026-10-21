import XCTest
@testable import ReLayoutCore

// Auto mode's word-boundary step (Core/Boundary.swift), with a decision stub in
// place of the trigram models.
final class BoundaryTests: XCTestCase {

    struct L: AutoLayout {
        var charToStroke: [String: KeyStroke]
        var strokeToChar: [KeyStroke: String]
        var isCyrillic: Bool
        var languageCode: String?
    }

    private func layouts() -> (latin: L, cyr: L) {
        let rows: [(UInt16, String, String)] = [
            (1, "g", "п"), (2, "h", "р"), (3, "b", "и"), (4, "d", "в"), (5, "t", "е"), (6, "n", "т"),
            (7, "o", "щ"), (8, "f", "а"), (9, "y", "н"), (10, "e", "у"),
        ]
        var lc = [String: KeyStroke](), ls = [KeyStroke: String](), cc = [String: KeyStroke](), cs = [KeyStroke: String]()
        for (k, a, b) in rows {
            let st = KeyStroke(keyCode: k, mods: 0)
            lc[a] = st; ls[st] = a; cc[b] = st; cs[st] = b
        }
        return (L(charToStroke: lc, strokeToChar: ls, isCyrillic: false, languageCode: "en"),
                L(charToStroke: cc, strokeToChar: cs, isCyrillic: true, languageCode: "ru"))
    }

    private struct State {
        var run = AutoRun(), edits = EditLearning<L>(), learned = LearnedWords(), chain: L?
    }

    /// Converts the words in `wrong` to the Cyrillic layout; leaves the rest.
    private func step(_ word: String, _ s: inout State, wrong: Set<String>, excluded: Bool = false)
        -> (action: BoundaryAction<L>, lessons: [EditLesson]) {
        let (latin, cyr) = layouts()
        return evaluateBoundary(word: word, trail: "", cur: latin, enabled: [latin, cyr],
                                run: &s.run, edits: &s.edits, learned: &s.learned, chainTarget: &s.chain,
                                excluded: { excluded }, decide: { w, verdict in
            guard verdict(learnedKey(w)) != .keep, wrong.contains(w) || verdict(learnedKey(w)) == .convert
            else { return nil }
            return (cyr, transliterate(w, from: latin, to: cyr), false, false)
        })
    }

    private func fixText(_ a: BoundaryAction<L>) -> String? {
        if case .fix(let f, _) = a { return f.text }
        return nil
    }

    func testAWrongWordIsFixed() {
        var s = State()
        XCTAssertEqual(fixText(step("ghbdtn", &s, wrong: ["ghbdtn"]).action), "привет")
    }

    func testARightWordAndAnExcludedPlaceAreLeft() {
        var s = State()
        XCTAssertNil(fixText(step("hello", &s, wrong: []).action))
        XCTAssertNil(fixText(step("ghbdtn", &s, wrong: ["ghbdtn"], excluded: true).action))
    }

    func testAShortWordWaitsThenJoinsTheNextLongOne() {
        var s = State()
        XCTAssertNil(fixText(step("d", &s, wrong: ["d", "ghbdtn"]).action))
        XCTAssertEqual(fixText(step("ghbdtn", &s, wrong: ["d", "ghbdtn"]).action), "в привет")
    }

    func testAShortRightWordAfterAChainWordBridges() {
        // "nf ot [fktgf": "ot" reads as English but rides along with the chain.
        var s = State()
        _ = step("ghbdtn", &s, wrong: ["ghbdtn", "fynty"])          // chain word, committed
        XCTAssertNil(fixText(step("on", &s, wrong: ["ghbdtn", "fynty"]).action))   // bridged, not fixed alone
        XCTAssertEqual(fixText(step("fynty", &s, wrong: ["ghbdtn", "fynty"]).action), "щт антен")
    }

    func testRetypingAFixedWordAfterAnEditTeachesKeep() {
        var s = State()
        _ = step("ghbdtn", &s, wrong: ["ghbdtn"])
        s.edits.edit()   // the user erased the fix
        let r = step("ghbdtn", &s, wrong: ["ghbdtn"])
        XCTAssertEqual(r.lessons, [.keep("ghbdtn")])
        XCTAssertNil(fixText(r.action))
        XCTAssertEqual(s.learned.verdict("ghbdtn"), .keep)
    }

    func testRightTextWrongLayoutOnlySwitches() {
        // A decision whose output equals the word: switch the layout, retype nothing.
        let (latin, cyr) = layouts()
        var s = State()
        let r = evaluateBoundary(word: "hello", trail: "", cur: latin, enabled: [latin, cyr],
                                 run: &s.run, edits: &s.edits, learned: &s.learned, chainTarget: &s.chain,
                                 excluded: { false }, decide: { w, _ in (cyr, w, false, false) })
        guard case .switchLayout(let t) = r.action else { return XCTFail("expected a switch") }
        XCTAssertTrue(t.isCyrillic)
    }
}
