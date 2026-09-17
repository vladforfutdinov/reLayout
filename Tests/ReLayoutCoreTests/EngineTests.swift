import XCTest
@testable import ReLayoutCore

// Cross-platform tests for the shared conversion engine. Hermetic: fixtures, no
// system keyboard. Runs on macOS and Windows CI.
final class EngineTests: XCTestCase {

    struct FakeLayout: AutoLayout {
        var charToStroke: [String: KeyStroke]
        var strokeToChar: [KeyStroke: String]
        var isCyrillic: Bool
        var languageCode: String?
    }

    // Latin and Ukrainian-Cyrillic layouts sharing the same physical keys; the ß/æ
    // rows live on an Option/AltGr layer (mods != 0) to exercise the modifier path
    // (an Option-layer char mapping to a Cyrillic letter, like the real ß/æ overlap),
    // and the ','/'.' rows exercise punctuation that is a letter on the Cyrillic side
    // (б/ю on ЙЦУКЕН).
    func makeLayouts() -> (latin: FakeLayout, cyr: FakeLayout) {
        let rows: [(UInt16, UInt32, String, String)] = [
            (10, 0, "g", "п"), (11, 0, "h", "р"), (12, 0, "b", "и"), (13, 0, "d", "в"),
            (14, 0, "t", "е"), (15, 0, "n", "т"), (16, 0, "e", "у"), (17, 0, "l", "д"),
            (18, 0, "o", "щ"), (19, 0, "q", "й"), (20, 0, "s", "і"), (21, 0, "k", "л"),
            (22, 0, "a", "ф"), (23, 0, "i", "ш"),
            (100, 1, "ß", "є"), (101, 1, "æ", "ї"),
            (43, 0, ",", "б"), (47, 0, ".", "ю"), (33, 0, "[", "х"),
            (42, 0, "\\", "\u{02BC}"),   // Ukrainian apostrophe: no key of its own on Latin
        ]
        var lC2S = [String: KeyStroke](), lS2C = [KeyStroke: String]()
        var cC2S = [String: KeyStroke](), cS2C = [KeyStroke: String]()
        for (kc, m, lat, cyr) in rows {
            let st = KeyStroke(keyCode: kc, mods: m)
            lC2S[lat] = st; lS2C[st] = lat
            cC2S[cyr] = st; cS2C[st] = cyr
        }
        return (FakeLayout(charToStroke: lC2S, strokeToChar: lS2C, isCyrillic: false, languageCode: "en"),
                FakeLayout(charToStroke: cC2S, strokeToChar: cS2C, isCyrillic: true, languageCode: "uk"))
    }

    func testTransliterate() {
        let (latin, cyr) = makeLayouts()
        XCTAssertEqual(transliterate("ghbdsn", from: latin, to: cyr), "привіт")
        XCTAssertEqual(transliterate("привіт", from: cyr, to: latin), "ghbdsn")
        XCTAssertEqual(transliterate("g!g", from: latin, to: cyr), "п!п")
        XCTAssertEqual(transliterate("ßæ", from: latin, to: cyr), "єї")
    }

    func testConvertWrongLatinSource() {
        let (latin, cyr) = makeLayouts()
        XCTAssertEqual(convertWrong("ghbdsn", src: latin, dst: cyr), "привіт")
        XCTAssertEqual(convertWrong("я сказав ghbdsn", src: latin, dst: cyr), "я сказав привіт")
        XCTAssertEqual(convertWrong("я написав ßæ", src: latin, dst: cyr), "я написав єї")
        XCTAssertNil(convertWrong("привіт світ", src: latin, dst: cyr))
    }

    func testConvertWrongCyrillicSource() {
        let (latin, cyr) = makeLayouts()
        XCTAssertEqual(convertWrong("руддщ", src: cyr, dst: latin), "hello")
        XCTAssertEqual(convertWrong("I said привіт", src: cyr, dst: latin), "I said ghbdsn")
        XCTAssertNil(convertWrong("hello world", src: cyr, dst: latin))
    }

    func testConvertWrongPunctuationAsLetters() {
        let (latin, cyr) = makeLayouts()
        // ',' is б on the Cyrillic side: a leading comma converts with the word.
        XCTAssertEqual(convertWrong(",tkb", src: latin, dst: cyr), "бели")
        // The reported shape: leading mapped punctuation + an Option-layer letter.
        XCTAssertEqual(convertWrong(",ßkb", src: latin, dst: cyr), "бєли")
    }

    func testConvertScriptRuns() {
        let (latin, cyr) = makeLayouts()
        // Mid-word layout switch: "при" typed on Latin, then the layout switched.
        XCTAssertEqual(convertScriptRuns("ghbвіт", src: latin, dst: cyr), "привіт")
        // The other reading of the same word: fix the post-switch run instead.
        XCTAssertEqual(convertScriptRuns("ghbвіт", src: cyr, dst: latin), "ghbdsn")
        // Non-src-script chars (incl. punctuation and digits) stay verbatim.
        XCTAssertEqual(convertScriptRuns("gh-b1", src: latin, dst: cyr), "пр-и1")
        XCTAssertNil(convertScriptRuns("привіт", src: latin, dst: cyr))
    }

    func testConvertWrongMixedToken() {
        let (latin, cyr) = makeLayouts()
        // Mid-word switch: only the src-script run converts, the other half stays.
        XCTAssertEqual(convertWrong("ghbвіт", src: latin, dst: cyr), "привіт")
        XCTAssertEqual(convertWrong("ghbвіт", src: cyr, dst: latin), "ghbdsn")
        XCTAssertEqual(convertWrong("я сказав ghbвіт", src: latin, dst: cyr), "я сказав привіт")
    }

    func testAutoWordCore() {
        let (latin, cyr) = makeLayouts()
        // Leading mapped punctuation strips into the core; the word itself qualifies.
        XCTAssertEqual(autoWordCore(",ghb", src: latin, dst: cyr), "ghb")
        XCTAssertEqual(autoWordCore(",ßhb", src: latin, dst: cyr), "ßhb")
        // Interior mapped punctuation stays in the core.
        XCTAssertEqual(autoWordCore("g,hb", src: latin, dst: cyr), "g,hb")
        // Letters-only word passes through whole.
        XCTAssertEqual(autoWordCore("ghb", src: latin, dst: cyr), "ghb")
        // Trailing mapped chars are word material too; the core drops them.
        XCTAssertEqual(autoWordCore("ghb,", src: latin, dst: cyr), "ghb")
        XCTAssertEqual(autoWordCore("g,h[", src: latin, dst: cyr), "g,h")
        // Fewer than two letters -> nil (floor-difference false fires).
        XCTAssertNil(autoWordCore(",.g", src: latin, dst: cyr))
        XCTAssertNil(autoWordCore(",,,", src: latin, dst: cyr))
        // A char that neither is a letter nor maps to a Cyrillic letter -> nil.
        XCTAssertNil(autoWordCore("g!b", src: latin, dst: cyr))
        XCTAssertNil(autoWordCore("g1b", src: latin, dst: cyr))
        // Cyrillic source: punctuation maps to Latin, never to Cyrillic -> nil.
        XCTAssertNil(autoWordCore(",пр", src: cyr, dst: latin))
    }

    func testWhitespacePreserved() {
        let (latin, cyr) = makeLayouts()
        XCTAssertEqual(convertWrong("ghbdsn\t\nghbdsn", src: latin, dst: cyr), "привіт\t\nпривіт")
        XCTAssertEqual(convertWrong("  ghbdsn  ", src: latin, dst: cyr), "  привіт  ")
    }

    func testScriptDetection() {
        XCTAssertTrue(isCyrLetter("п"))
        XCTAssertFalse(isCyrLetter("g"))
        XCTAssertTrue(hasCyr(Substring("abвc")))
        XCTAssertFalse(hasCyr(Substring("abc")))
        XCTAssertTrue(hasLatin(Substring("abc")))
        XCTAssertTrue(hasLatin(Substring("über")))
    }

    func testTokenizePreservesRuns() {
        XCTAssertEqual(tokenize("a  b\tc").map(String.init), ["a", "  ", "b", "\t", "c"])
    }

    func testDominantScript() {
        XCTAssertEqual(dominantScript("ghbdsn"), false)              // all Latin
        XCTAssertEqual(dominantScript("привіт"), true)               // all Cyrillic
        XCTAssertEqual(dominantScript("ghbdsn ghbdsn слово"), false) // Latin majority
        XCTAssertEqual(dominantScript("привіт привіт hello"), true)  // Cyrillic majority
        XCTAssertNil(dominantScript("ghbdsn слово"))                 // 1:1 tie
        XCTAssertNil(dominantScript("123 !!!"))                      // no letters
        XCTAssertNil(dominantScript("   "))
    }

    func testTrigramModel() {
        let m = TrigramModel(text: """
        # tiny model
        floor -10
        ^^a -1
        ^ab -1
        abc -1
        bc$ -1
        """)!
        // "abc" -> ^^abc$ -> ^^a ^ab abc bc$, all -1 -> mean -1
        XCTAssertEqual(m.score("abc"), -1, accuracy: 0.0001)
        // all-unseen trigrams -> floor
        XCTAssertEqual(m.score("xyz"), -10, accuracy: 0.0001)
        // a "real" word scores higher than junk
        XCTAssertGreaterThan(m.score("abc"), m.score("xyz"))
        XCTAssertNil(TrigramModel(text: "no floor here\nabc -1"))   // missing floor
    }

    func testTextHasScript() {
        XCTAssertTrue(textHasScript("ghbdsn слово", cyrillic: true))
        XCTAssertTrue(textHasScript("ghbdsn слово", cyrillic: false))
        XCTAssertFalse(textHasScript("ghbdsn", cyrillic: true))      // no Cyrillic
        XCTAssertFalse(textHasScript("привіт", cyrillic: false))     // no Latin
        XCTAssertFalse(textHasScript("123", cyrillic: true))
    }

    // MARK: - caretWord (implicit caret-line grab)

    private func word(_ s: String) -> String? {
        caretWord(s).map { String(s[$0...]) }
    }

    func testCaretWordLastWordOnly() {
        XCTAssertEqual(word("привіт ghbdsn"), "ghbdsn")
        XCTAssertEqual(word("hello ghbdsn привіт"), "привіт")
        XCTAssertEqual(word("ghbdsn"), "ghbdsn")
    }

    func testCaretWordKeepsMidWordPunctuation() {
        // Hyphens, dots, apostrophes are word material — a word is a run of
        // non-whitespace.
        XCTAssertEqual(word("щось rjt-xnj"), "rjt-xnj")
        XCTAssertEqual(word("пиши e-mail"), "e-mail")
        XCTAssertEqual(word("це d'jhl"), "d'jhl")
        XCTAssertEqual(word("тест ghbdsn!!"), "ghbdsn!!")
    }

    func testCaretWordTrailingWhitespaceKept() {
        // Trailing whitespace belongs to the window (retyped verbatim).
        XCTAssertEqual(word("привіт ghbdsn "), "ghbdsn ")
        XCTAssertEqual(word("привіт ghbdsn\t"), "ghbdsn\t")
    }

    func testCaretWordNothingToGrab() {
        XCTAssertNil(word(""))
        XCTAssertNil(word("   "))
    }

    func testHyphenScoredPerPart() {
        // Every trigram spanning a hyphen is unseen, so a whole-word score is
        // floor-dominated; parts are scored separately and length-weighted.
        let m = TrigramModel(floor: -16, table: ["^^a": -1, "^ab": -1, "abc": -1, "bc$": -1,
                                                 "^^d": -1, "^de": -1, "de$": -1])
        XCTAssertEqual(m.score("abc"), -1, accuracy: 0.001)
        XCTAssertEqual(m.score("abc-de"), -1, accuracy: 0.001)   // not dragged to the floor
        XCTAssertEqual(m.score("-"), -16, accuracy: 0.001)       // nothing but a connector
    }

    func testWordConnector() {
        XCTAssertTrue(isWordConnector("-"))
        XCTAssertTrue(isWordConnector("\u{02BC}"))
        XCTAssertFalse(isWordConnector("'"))   // э on ЙЦУКЕН — real word material
        XCTAssertFalse(isWordConnector("a"))
    }

    func testMapsToConnector() {
        let (latin, cyr) = makeLayouts()
        // "мʼяко" is typed "v\\zrj": the backslash is the apostrophe key, word
        // material — not punctuation that ends the word.
        XCTAssertTrue(mapsToConnector("\\", src: latin, dst: cyr))
        XCTAssertFalse(mapsToConnector(",", src: latin, dst: cyr))   // maps to б, a letter
        XCTAssertFalse(mapsToConnector("g", src: latin, dst: cyr))
        XCTAssertTrue(mapsToWordChar("d\\", src: latin, dst: cyr, connectors: true))
        XCTAssertTrue(autoWordCore("gh\\bd", src: latin, dst: cyr) == "gh\\bd")
    }

    func testCaretWordConvertsOnlyThatWord() {
        let (latin, cyr) = makeLayouts()
        let text = "привіт ghbdsn"
        guard let start = caretWord(text) else { return XCTFail("expected a word") }
        XCTAssertEqual(convertWrong(String(text[start...]), src: latin, dst: cyr), "привіт")
        XCTAssertEqual(String(text[..<start]), "привіт ")   // head untouched
    }

    // MARK: - decideAutoTarget (auto-mode decision)

    // A model that knows exactly the given words: their trigrams score -1, anything
    // else falls to the floor. Enough to exercise the gates, which compare scores.
    private func model(knowing words: [String]) -> TrigramModel {
        var lines = ["floor -5.0"]
        for w in words {
            let chars = Array("^^" + w.lowercased() + "$")
            for i in 2..<chars.count { lines.append("\(String(chars[(i - 2)...i])) -1.0") }
        }
        return TrigramModel(text: lines.joined(separator: "\n"))!
    }

    private func decide(_ w: String, cyrKnows: [String], latinKnows: [String]) -> (target: String, out: String)? {
        let (latin, cyr) = makeLayouts()
        let models = ["en": model(knowing: latinKnows), "uk": model(knowing: cyrKnows)]
        return decideAutoTarget(w, cur: latin, enabled: [latin, cyr], model: { models[$0] })
            .map { (target: $0.target.isCyrillic ? "uk" : "en", out: $0.out) }
    }

    func testAutoDecideFiresOnWrongLayoutWord() {
        let r = decide("ghbdtn", cyrKnows: ["привет"], latinKnows: ["hello"])
        XCTAssertEqual(r?.out, "привет")
        XCTAssertEqual(r?.target, "uk")
    }

    func testAutoDecideLeavesPlausibleWord() {
        XCTAssertNil(decide("hello", cyrKnows: ["привет"], latinKnows: ["hello"]))
    }

    func testAutoDecideNeedsTheTargetToBeBetter() {
        // Junk both ways: neither side knows the word, so no target clears the margin.
        XCTAssertNil(decide("ghbdtn", cyrKnows: [], latinKnows: []))
    }

    func testAutoDecideNeedsALayoutOfTheOtherScript() {
        let (latin, _) = makeLayouts()
        let models = ["en": model(knowing: ["hello"])]
        XCTAssertNil(decideAutoTarget("ghbdtn", cur: latin, enabled: [latin], model: { models[$0] }))
    }

    func testAutoDecideWithoutAModelDoesNothing() {
        let (latin, cyr) = makeLayouts()
        XCTAssertNil(decideAutoTarget("ghbdtn", cur: latin, enabled: [latin, cyr], model: { _ in nil }))
    }
}
