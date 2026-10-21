// Unit tests for the macOS app's own logic (hotkey model and display helpers, trace
// redaction). The engine is tested in Tests/ReLayoutCoreTests (`swift test`).
//
// Built only under -DTESTING, where main.swift's GUI bootstrap is compiled out and
// this file supplies the entry point. Run via ./scripts/run-tests.sh.

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

// MARK: - tests

func testDbgRedact() {
    eq(dbgRedact(#"feed "п" buf="Пароль1!" app=com.apple.Terminal"#),
       #"feed "я" buf="яяяяяя0·" app=com.apple.Terminal"#, "redact: letters/digits/symbols masked, rest kept")
    eq(dbgRedact(#"type: "ab c\r" "\u{1C}" "x\"y""#), #"type: "aa a\r" "\u{1C}" "a\"a""#, "redact: spaces and escapes kept")
    eq(dbgRedact(#"learned: ["ghb"]"#), #"learned: ["aaa"]"#, "redact: arrays")
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

func testHotkeyClashes() {
    let optTap = Hotkey(mode: .modTap, chord: [UInt16(kVK_Option)], display: "left ⌥")
    var optDouble = optTap; optDouble.taps = 2
    let rightOpt = Hotkey(mode: .modTap, chord: [UInt16(kVK_RightOption)], display: "right ⌥")
    let shiftTap = Hotkey(mode: .modTap, chord: [UInt16(kVK_Shift)], display: "left ⇧")
    let combo = Hotkey(mode: .carbon, code: UInt32(kVK_ANSI_R), mods: UInt32(controlKey | optionKey), display: "⌃⌥R")
    var comboShift = combo; comboShift.mods |= UInt32(shiftKey)
    check(optTap.clashes(with: optDouble), "same chord, different tap count clashes")
    check(optTap.clashes(with: rightOpt), "left/right of one modifier clash")
    check(!optTap.clashes(with: shiftTap), "different chords don't clash")
    check(combo.clashes(with: combo), "same combo clashes")
    check(!combo.clashes(with: comboShift), "combo with an extra modifier doesn't clash")
    check(!combo.clashes(with: optTap), "combo vs modifier tap don't clash")
}

func testHotkeyIsCombo() {
    let combo = Hotkey(mode: .carbon, code: UInt32(kVK_ANSI_T), mods: UInt32(controlKey | optionKey), display: "⌃⌥T")
    check(combo.isCombo(code: Int64(kVK_ANSI_T), flags: [.maskControl, .maskAlternate]), "isCombo exact")
    check(combo.isCombo(code: Int64(kVK_ANSI_T), flags: [.maskControl, .maskAlternate, .maskAlphaShift]),
          "isCombo ignores caps lock")
    check(!combo.isCombo(code: Int64(kVK_ANSI_T), flags: [.maskControl]), "isCombo missing modifier")
    check(!combo.isCombo(code: Int64(kVK_ANSI_R), flags: [.maskControl, .maskAlternate]), "isCombo other key")
    let tap = Hotkey(mode: .modTap, chord: [UInt16(kVK_Option)], display: "left ⌥")
    check(!tap.isCombo(code: 0, flags: [.maskAlternate]), "modifier tap is never a combo")
}

func testHotkeyPersistence() {
    let suite = "relayout.tests.hotkey"
    guard let d = UserDefaults(suiteName: suite) else { check(false, "test defaults suite"); return }
    defer { d.removePersistentDomain(forName: suite) }
    eq(Hotkey.load(d, prefix: "autoHk"), nil, "nothing stored -> nil")
    let hk = Hotkey(mode: .modTap, chord: [UInt16(kVK_Shift)], taps: 2, display: "left ⇧ ×2")
    hk.save(d, prefix: "autoHk")
    eq(Hotkey.load(d, prefix: "autoHk"), hk, "round trip")
    eq(Hotkey.load(d, prefix: "hk"), nil, "prefixes are separate")
    eq(d.integer(forKey: "autoHkTaps"), 2, "key names are prefix + field")
    Hotkey.remove(d, prefix: "autoHk")
    eq(Hotkey.load(d, prefix: "autoHk"), nil, "removed -> nil")
}

// MARK: - entry

#if TESTING
@main
struct ReLayoutTests {
    static func main() {
        testFourCharCode()
        testKeyName()
        testComboDisplay()
        testModKeyLabelAndChord()
        testCarbonModsFrom()
        testPressedModKeys()
        testHotkeyClashes()
        testHotkeyIsCombo()
        testHotkeyPersistence()
        testDbgRedact()

        print("\n\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
#endif
