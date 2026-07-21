import XCTest
@testable import ReLayoutCore

// Cross-platform tests for the shared conversion engine. Hermetic: fixtures, no
// system keyboard. Runs on macOS and Windows CI.
final class EngineTests: XCTestCase {

    struct FakeLayout: LayoutMaps {
        var charToStroke: [String: KeyStroke]
        var strokeToChar: [KeyStroke: String]
        var isCyrillic: Bool
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
            (43, 0, ",", "б"), (47, 0, ".", "ю"),
        ]
        var lC2S = [String: KeyStroke](), lS2C = [KeyStroke: String]()
        var cC2S = [String: KeyStroke](), cS2C = [KeyStroke: String]()
        for (kc, m, lat, cyr) in rows {
            let st = KeyStroke(keyCode: kc, mods: m)
            lC2S[lat] = st; lS2C[st] = lat
            cC2S[cyr] = st; cS2C[st] = cyr
        }
        return (FakeLayout(charToStroke: lC2S, strokeToChar: lS2C, isCyrillic: false),
                FakeLayout(charToStroke: cC2S, strokeToChar: cS2C, isCyrillic: true))
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

    func testAutoWordCore() {
        let (latin, cyr) = makeLayouts()
        // Leading mapped punctuation strips into the core; the word itself qualifies.
        XCTAssertEqual(autoWordCore(",ghb", src: latin, dst: cyr), "ghb")
        XCTAssertEqual(autoWordCore(",ßhb", src: latin, dst: cyr), "ßhb")
        // Interior mapped punctuation stays in the core.
        XCTAssertEqual(autoWordCore("g,hb", src: latin, dst: cyr), "g,hb")
        // Letters-only word passes through whole.
        XCTAssertEqual(autoWordCore("ghb", src: latin, dst: cyr), "ghb")
        // Trailing mapped char is ambiguous (real punctuation vs б/ю) -> nil.
        XCTAssertNil(autoWordCore("ghb,", src: latin, dst: cyr))
        XCTAssertNil(autoWordCore("gh.", src: latin, dst: cyr))
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

    // MARK: - lastWrongWindow (implicit caret-line grab)

    // Window as (tail text, wrong script) for assertion brevity.
    private func window(_ s: String) -> (tail: String, cyr: Bool)? {
        guard let (start, wrongCyr) = lastWrongWindow(s) else { return nil }
        return (String(s[start...]), wrongCyr)
    }

    func testLineWindowMixedLine() {
        // The bug case: correct cyr word + wrong-layout tail; only the tail windows.
        let w = window("привіт ghbdsn")
        XCTAssertEqual(w?.tail, " ghbdsn")
        XCTAssertEqual(w?.cyr, false)
        // Mirrored scripts.
        let v = window("hello ghbdsn привіт")
        XCTAssertEqual(v?.tail, " привіт")
        XCTAssertEqual(v?.cyr, true)
    }

    func testLineWindowWholeLineOneScript() {
        // No other-script letter -> whole line, and no mid-word trim of the head.
        XCTAssertEqual(window("ghbdsn rfr")?.tail, "ghbdsn rfr")
        let w = window("привіт світ")
        XCTAssertEqual(w?.tail, "привіт світ")
        XCTAssertEqual(w?.cyr, true)
    }

    func testLineWindowMixedTokenTrimmedAway() {
        // Stop letter mid-token: the remainder is the stop word's tail -> nothing left.
        XCTAssertNil(window("привітghbdsn"))
    }

    func testLineWindowNeutralsSkipped() {
        // Digits/punctuation are neutral: walked over, kept in the window.
        XCTAssertEqual(window("привіт 123 ghbdsn")?.tail, " 123 ghbdsn")
        XCTAssertEqual(window("привіт ghbdsn!!")?.tail, " ghbdsn!!")
    }

    func testLineWindowMultipleWrongWords() {
        XCTAssertEqual(window("привіт rfr ltkf")?.tail, " rfr ltkf")
    }

    func testLineWindowCJK() {
        // A CJK letter is "another script": stops the walk…
        XCTAssertEqual(window("今日は ghbdsn")?.tail, " ghbdsn")
        // …but can't anchor the wrong script when it ends the line.
        XCTAssertNil(window("ghbdsn 今日は"))
    }

    func testLineWindowNothingToAnchor() {
        XCTAssertNil(window(""))
        XCTAssertNil(window("   "))
        XCTAssertNil(window("123 !!"))
    }

    func testLineWindowConvertsOnlyTail() {
        // End-to-end over the fixtures: prefix verbatim + converted window.
        let (latin, cyr) = makeLayouts()
        let text = "привіт ghbdsn"
        guard let (start, wrongCyr) = lastWrongWindow(text) else {
            return XCTFail("expected a window")
        }
        XCTAssertFalse(wrongCyr)
        let out = convertWrong(String(text[start...]), src: latin, dst: cyr)
        XCTAssertEqual(String(text[..<start]) + (out ?? ""), "привіт привіт")
    }
}
