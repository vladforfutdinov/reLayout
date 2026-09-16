import XCTest
@testable import ReLayoutCore

// Engine over real macOS layout tables beyond ABC <-> ЙЦУКЕН. Rows are the
// UCKeyTranslate output of the four ANSI letter/digit rows (no dead keys), copied
// verbatim; "·" marks a key that types nothing.
final class LayoutPairTests: XCTestCase {

    struct Table: LayoutMaps {
        var charToStroke: [String: KeyStroke] = [:]
        var strokeToChar: [KeyStroke: String] = [:]
        var isCyrillic = false

        /// - Parameters: `base`/`shift` are " | "-joined physical rows; unicode scalars,
        ///   not Characters, so a Hebrew combining mark keeps its own key.
        init(_ base: String, shift: String = "") {
            for (mods, layer) in [(UInt32(2), shift), (UInt32(0), base)] where !layer.isEmpty {
                for (r, row) in layer.components(separatedBy: " | ").enumerated() {
                    for (c, u) in row.unicodeScalars.enumerated() where u != "·" {
                        let st = KeyStroke(keyCode: UInt16(r * 20 + c), mods: mods)
                        strokeToChar[st] = String(u)
                        charToStroke[String(u)] = st   // base written last: it wins
                    }
                }
            }
            isCyrillic = strokeToChar.values.contains { $0.unicodeScalars.first.map(isCyrLetter) ?? false }
        }
    }

    let abc = Table("`1234567890-= | qwertyuiop[]\\ | asdfghjkl;' | zxcvbnm,./",
                    shift: "~!@#$%^&*()_+ | QWERTYUIOP{}| | ASDFGHJKL:\" | ZXCVBNM<>?")
    let german = Table("<1234567890ß´ | qwertzuiopü+# | asdfghjklöä | yxcvbnm,.-",
                       shift: ">!\"§$%&/()=?` | QWERTZUIOPÜ*' | ASDFGHJKLÖÄ | YXCVBNM;:_")
    let french = Table("<&é\"'(§è!çà)- | azertyuiop^$` | qsdfghjklmù | wxcvbn,;:=",
                       shift: ">1234567890°_ | AZERTYUIOP¨*£ | QSDFGHJKLM% | WXCVBN?./+")
    let dvorak = Table("`1234567890[] | ',.pyfgcrl/=\\ | aoeuidhtns- | ;qjkxbmwvz")
    let czech = Table("\\+ěščřžýáíé=' | qwertyuiopú)¨ | asdfghjklů§ | zxcvbnm,.-")
    let polish = Table("<1234567890ż[ | qwertzuiopó(; | asdfghjklłą | yxcvbnm.,-")
    let turkish = Table("<1234567890*- | qwertyuıopğü, | asdfghjklşi | zxcvbnmöç.")
    let russianMac = Table("]1234567890-= | йцукенгшщзхъё | фывапролджэ | ячсмитьбю/",
                           shift: "[!\"№%:,.;()_+ | ЙЦУКЕНГШЩЗХЪЁ | ФЫВАПРОЛДЖЭ | ЯЧСМИТЬБЮ?")
    let russianPC = Table("ё1234567890-= | йцукенгшщзхъ\\ | фывапролджэ | ячсмитьбю.",
                          shift: "Ë!\"№;%:?*()_+ | ЙЦУКЕНГШЩЗХЪ/ | ФЫВАПРОЛДЖЭ | ЯЧСМИТЬБЮ,")
    let ukrainianPC = Table("ґ1234567890-= | йцукенгшщзхїʼ | фівапролджє | ячсмитьбю.",
                            shift: "Ґ!\"№;%:?*()_+ | ЙЦУКЕНГШЩЗХЇ₴ | ФІВАПРОЛДЖЄ | ЯЧСМИТЬБЮ,")
    let belarusian = Table("“1234567890-= | йцукенгшўзх'ё | фывапролджэ | ячсмітьбю/")
    let kazakh = Table("[\"әіңғ,.үұқөһ | йцукенгшщзхъё | фывапролджэ | ячсмитьбю/")
    let serbianLatin = Table("<1234567890/+ | qwertyuiopšđž | asdfghjklčć | zxcvbnm,.-")
    let serbian = Table("<1234567890’+ | љњертзуиопшђж | асдфгхјклчћ | ѕџцвбнм,.-")
    let georgian = Table("„1234567890-= | ქწერტყუიოპ[]\\ | ასდფგჰჯკლ;' | ზხცვბნმ,./")
    let greek = Table("`1234567890-= | ;ςερτυθιοπ[]\\ | ασδφγηξκλ΄' | ζχψωβνμ,./")
    let hebrew = Table(";1234567890-= | /׳קראטוןםפ][ֿ | שדגכעיחלךף, | זסבהנמצתץ.")
    let arabic = Table("ـ١٢٣٤٥٦٧٨٩٠-= | ضصثقفغعهخحجة\\ | شسيبلاتنمك؛ | ظطذدزرو،./")

    // MARK: Latin <-> Latin

    func testQwertyToQwertzUmlautsAndYZSwap() {
        XCTAssertEqual(convertWrong("Gr[-e", src: abc, dst: german), "Grüße")
        XCTAssertEqual(convertWrong("Y[rich", src: abc, dst: german), "Zürich")
        XCTAssertEqual(convertWrong("Grüße", src: german, dst: abc), "Gr[-e")
    }

    func testAzertyTypedWithQwertyHabits() {
        // m/a/z pressed where QWERTY has them: AZERTY prints ",", "q", "w".
        XCTAssertEqual(convertWrong(",qwe", src: french, dst: abc), "maze")
        XCTAssertEqual(transliterate("1", from: abc, to: french), "&")
    }

    func testDvorakPunctuationIsWordMaterial() {
        XCTAssertEqual(convertWrong("d.nnr", src: dvorak, dst: abc), "hello")
        XCTAssertEqual(convertWrong("jdpps", src: abc, dst: dvorak), "hello")
    }

    func testDigitRowLettersCzech() {
        XCTAssertEqual(convertWrong("p59li3", src: abc, dst: czech), "příliš")
    }

    func testPolishLettersOnPunctuationKeys() {
        XCTAssertEqual(convertWrong(";'ka", src: abc, dst: polish), "łąka")
    }

    func testTurkishDotlessI() {
        XCTAssertEqual(convertWrong("kiz", src: abc, dst: turkish), "kız")
        XCTAssertEqual(convertWrong("k'z", src: abc, dst: turkish), "kiz")
    }

    // MARK: Cyrillic

    func testCommaKeyDiffersBetweenMacAndPCRussian() {
        XCTAssertEqual(transliterate("ghbdtn?", from: abc, to: russianPC), "привет,")
        XCTAssertEqual(transliterate("ghbdtn?", from: abc, to: russianMac), "привет?")
        XCTAssertEqual(transliterate("ghbdtn^", from: abc, to: russianMac), "привет,")
    }

    func testRussianToUkrainianSameScript() {
        XCTAssertEqual(convertWrong("ыграшка", src: russianPC, dst: ukrainianPC), "іграшка")
        XCTAssertEqual(convertWrong("ъжак", src: russianPC, dst: ukrainianPC), "їжак")
    }

    func testBelarusianShortU() {
        XCTAssertEqual(convertWrong("ghfolf", src: abc, dst: belarusian), "праўда")
        XCTAssertEqual(convertWrong("czv]z", src: abc, dst: belarusian), "сям'я")
    }

    func testKazakhDigitRowLetters() {
        XCTAssertEqual(convertWrong("c2ktv", src: abc, dst: kazakh), "сәлем")
        XCTAssertTrue(mapsToWordChar("2", src: abc, dst: kazakh, connectors: false))
    }

    func testSerbianLatinToCyrillic() {
        XCTAssertEqual(convertWrong("ydravo", src: serbianLatin, dst: serbian), "здраво")
        XCTAssertEqual(convertWrong("љубав", src: serbian, dst: serbianLatin), "qubav")
    }

    // MARK: Latin -> other scripts

    func testLatinToGeorgian() {
        XCTAssertEqual(convertWrong("gamarjoba", src: abc, dst: georgian), "გამარჯობა")
    }

    func testLatinToGreekFinalSigma() {
        XCTAssertEqual(convertWrong("kalhmera", src: abc, dst: greek), "καλημερα")
        XCTAssertEqual(convertWrong("logow", src: abc, dst: greek), "λογος")
    }

    func testLatinToHebrewFinalMem() {
        XCTAssertEqual(convertWrong("akuo", src: abc, dst: hebrew), "שלום")
    }

    func testLatinToArabic() {
        XCTAssertEqual(convertWrong("lnpfh", src: abc, dst: arabic), "مرحبا")
    }
}
