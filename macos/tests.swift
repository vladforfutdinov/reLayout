// Unit tests for reLayout's pure logic (conversion engine + hotkey display helpers).
//
// Built only under -DTESTING, where main.swift's GUI bootstrap is compiled out and
// this file supplies the entry point. Run via ./scripts/run-tests.sh. Hermetic: the
// transliteration engine is exercised with injected fixture layouts (FakeLayout),
// so no installed keyboard layout is required.

import Cocoa
import Carbon.HIToolbox

// MARK: - harness

var passed = 0
var failed = 0

func check(_ cond: Bool, _ msg: String) {
    if cond { passed += 1 } else { failed += 1; print("  FAIL: \(msg)") }
}

func eq<T: Equatable>(_ got: T, _ want: T, _ msg: String) {
    check(got == want, "\(msg) — got \(String(reflecting: got)), want \(String(reflecting: want))")
}

// MARK: - fixture layouts

struct FakeLayout: LayoutMaps {
    var charToStroke: [String: KeyStroke]
    var strokeToChar: [KeyStroke: String]
    var isCyrillic: Bool
}

// A Latin layout and a Cyrillic layout sharing the same physical keys, so a key
// that types `g` in Latin types `п` in Cyrillic, etc. The last two rows live on an
// Option layer (mods != 0) to mirror the real ß/æ <-> ы/э case.
func makeLayouts() -> (latin: FakeLayout, cyr: FakeLayout) {
    // (keyCode, mods, latinChar, cyrChar)
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

// MARK: - tests

func testTransliterate() {
    let (latin, cyr) = makeLayouts()
    eq(transliterate("ghbdtn", from: latin, to: cyr), "привет", "translit latin->cyr full word")
    eq(transliterate("привет", from: cyr, to: latin), "ghbdtn", "translit cyr->latin full word")
    // Unmapped chars pass through verbatim.
    eq(transliterate("g!g", from: latin, to: cyr), "п!п", "translit keeps unmapped chars")
    eq(transliterate("ßæ", from: latin, to: cyr), "ыэ", "translit option layer ß/æ -> ы/э")
}

func testConvertWrongLatinSource() {
    let (latin, cyr) = makeLayouts()
    // Latin "wrong" word converts; Cyrillic words pass through untouched.
    eq(convertWrong("ghbdtn", src: latin, dst: cyr), "привет", "convert latin word")
    eq(convertWrong("я сказал ghbdtn", src: latin, dst: cyr), "я сказал привет",
       "convert only the latin word, keep cyrillic words")
    eq(convertWrong("я написал ßæ", src: latin, dst: cyr), "я написал ыэ",
       "convert option-layer latin word")
    // Already-correct (all-Cyrillic) text -> no change -> nil.
    check(convertWrong("привет мир", src: latin, dst: cyr) == nil,
          "latin-src: all-cyrillic input returns nil")
}

func testConvertWrongCyrillicSource() {
    let (latin, cyr) = makeLayouts()
    eq(convertWrong("руддщ", src: cyr, dst: latin), "hello", "convert cyr word -> latin")
    eq(convertWrong("I said привет", src: cyr, dst: latin), "I said ghbdtn",
       "cyr-src: convert only the cyrillic word, keep latin words")
    check(convertWrong("hello world", src: cyr, dst: latin) == nil,
          "cyr-src: all-latin input returns nil")
}

func testConvertWrongWhitespace() {
    let (latin, cyr) = makeLayouts()
    // Whitespace runs (incl. multiple spaces / tabs / newlines) preserved exactly.
    eq(convertWrong("ghbdtn\t\nghbdtn", src: latin, dst: cyr), "привет\t\nпривет",
       "whitespace runs preserved")
    eq(convertWrong("  ghbdtn  ", src: latin, dst: cyr), "  привет  ",
       "leading/trailing spaces preserved")
}

func testFourCharCode() {
    // R=0x52 L=0x4C A=0x41 Y=0x59
    eq(fourCharCode("RLAY"), FourCharCode(0x524C4159), "fourCharCode RLAY")
    // More than 4 bytes -> first 4 only.
    eq(fourCharCode("RLAYX"), FourCharCode(0x524C4159), "fourCharCode truncates to 4")
}

func testKeyName() {
    eq(keyName(UInt16(kVK_Space), nil), "Space", "keyName space")
    eq(keyName(UInt16(kVK_Return), nil), "↩", "keyName return")
    eq(keyName(UInt16(kVK_Escape), nil), "⎋", "keyName escape")
    eq(keyName(UInt16(kVK_F5), nil), "F5", "keyName F5")
    eq(keyName(UInt16(kVK_LeftArrow), nil), "←", "keyName left arrow")
    eq(keyName(UInt16(kVK_ANSI_A), "a"), "A", "keyName letter uppercased from chars")
}

func testComboDisplay() {
    let mods: NSEvent.ModifierFlags = [.command, .shift]
    eq(comboDisplay(UInt16(kVK_ANSI_A), mods, "a"), "⇧⌘A", "comboDisplay shift+cmd+A")
    let all: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    eq(comboDisplay(UInt16(kVK_ANSI_R), all, "r"), "⌃⌥⇧⌘R", "comboDisplay all modifiers order")
}

func testModKeyLabelAndChord() {
    eq(modKeyLabel(UInt16(kVK_Option)), "left ⌥", "modKeyLabel left option")
    eq(modKeyLabel(UInt16(kVK_RightControl)), "right ⌃", "modKeyLabel right control")
    eq(chordDisplay([UInt16(kVK_Option)]), "left ⌥", "chordDisplay single")
}

func testCarbonModsFrom() {
    eq(carbonModsFrom([.command]), UInt32(cmdKey), "carbonModsFrom command")
    eq(carbonModsFrom([.option]), UInt32(optionKey), "carbonModsFrom option")
    eq(carbonModsFrom([.command, .shift]), UInt32(cmdKey | shiftKey), "carbonModsFrom cmd+shift")
}

func testPressedModKeys() {
    // Device-dependent flag bits (left vs right).
    eq(pressedModKeys(NSEvent.ModifierFlags(rawValue: 0x00000020)), [UInt16(kVK_Option)],
       "pressedModKeys left option bit")
    eq(pressedModKeys(NSEvent.ModifierFlags(rawValue: 0x00000040)), [UInt16(kVK_RightOption)],
       "pressedModKeys right option bit")
    eq(pressedModKeys(NSEvent.ModifierFlags(rawValue: 0x00000001)), [UInt16(kVK_Control)],
       "pressedModKeys left control bit")
    eq(pressedModKeys(NSEvent.ModifierFlags(rawValue: 0)), [], "pressedModKeys none")
}

// MARK: - entry

#if TESTING
@main
struct ReLayoutTests {
    static func main() {
        testTransliterate()
        testConvertWrongLatinSource()
        testConvertWrongCyrillicSource()
        testConvertWrongWhitespace()
        testFourCharCode()
        testKeyName()
        testComboDisplay()
        testModKeyLabelAndChord()
        testCarbonModsFrom()
        testPressedModKeys()

        print("\n\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
#endif
