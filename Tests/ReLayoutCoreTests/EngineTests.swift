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

    // Latin and Cyrillic layouts sharing the same physical keys; last two rows on
    // an Option/AltGr layer (mods != 0) mirror the real ß/æ <-> ы/э case.
    func makeLayouts() -> (latin: FakeLayout, cyr: FakeLayout) {
        let rows: [(UInt16, UInt32, String, String)] = [
            (10, 0, "g", "п"), (11, 0, "h", "р"), (12, 0, "b", "и"), (13, 0, "d", "в"),
            (14, 0, "t", "е"), (15, 0, "n", "т"), (16, 0, "e", "у"), (17, 0, "l", "д"),
            (18, 0, "o", "щ"), (19, 0, "q", "й"), (20, 0, "s", "с"), (21, 0, "k", "л"),
            (22, 0, "a", "ф"), (23, 0, "i", "ш"),
            (100, 1, "ß", "ы"), (101, 1, "æ", "э"),
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
        XCTAssertEqual(transliterate("ghbdtn", from: latin, to: cyr), "привет")
        XCTAssertEqual(transliterate("привет", from: cyr, to: latin), "ghbdtn")
        XCTAssertEqual(transliterate("g!g", from: latin, to: cyr), "п!п")
        XCTAssertEqual(transliterate("ßæ", from: latin, to: cyr), "ыэ")
    }

    func testConvertWrongLatinSource() {
        let (latin, cyr) = makeLayouts()
        XCTAssertEqual(convertWrong("ghbdtn", src: latin, dst: cyr), "привет")
        XCTAssertEqual(convertWrong("я сказал ghbdtn", src: latin, dst: cyr), "я сказал привет")
        XCTAssertEqual(convertWrong("я написал ßæ", src: latin, dst: cyr), "я написал ыэ")
        XCTAssertNil(convertWrong("привет мир", src: latin, dst: cyr))
    }

    func testConvertWrongCyrillicSource() {
        let (latin, cyr) = makeLayouts()
        XCTAssertEqual(convertWrong("руддщ", src: cyr, dst: latin), "hello")
        XCTAssertEqual(convertWrong("I said привет", src: cyr, dst: latin), "I said ghbdtn")
        XCTAssertNil(convertWrong("hello world", src: cyr, dst: latin))
    }

    func testWhitespacePreserved() {
        let (latin, cyr) = makeLayouts()
        XCTAssertEqual(convertWrong("ghbdtn\t\nghbdtn", src: latin, dst: cyr), "привет\t\nпривет")
        XCTAssertEqual(convertWrong("  ghbdtn  ", src: latin, dst: cyr), "  привет  ")
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
}
