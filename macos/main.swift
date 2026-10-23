import Cocoa
import Carbon.HIToolbox
import ServiceManagement
import UniformTypeIdentifiers
#if SPARKLE
import Sparkle   // only linked in release builds (build.sh WITH_SPARKLE=1)
#endif

// MARK: - Helpers

// GitHub owner/repo this build points at (About link). Injected into the bundle
// by build.sh from RELAYOUT_REPO_SLUG so forks rebrand without editing sources.
// Empty (identity-less local build) hides the link in Settings.
let repoSlug = (Bundle.main.infoDictionary?["RLRepoSlug"] as? String) ?? ""

// Localized UI string. Keys live in <lang>.lproj/Localizable.strings (copied
// into the app bundle by build.sh). Missing key -> the key itself is returned.
//
// Loc.bundle is the active localization. Default = .main (follows the system
// language). A Settings override points it at a specific <lang>.lproj so the UI
// can switch language live, without relaunch.
enum Loc {
    // Supported UI languages, derived from the .lproj bundles shipped in
    // Resources (not hardcoded). Each is shown by its autonym — the language's
    // own name — sorted alphabetically so the order is stable across calls.
    static let languages: [(code: String, name: String)] = {
        // Bundle.localizations can list a code twice (Info.plist
        // CFBundleLocalizations + the on-disk .lproj), so dedupe.
        Array(Set(Bundle.main.localizations))
            .filter { $0 != "Base" }
            .map { code -> (code: String, name: String) in
                let loc = Locale(identifier: code)
                let raw = loc.localizedString(forIdentifier: code)
                    ?? loc.localizedString(forLanguageCode: code)
                    ?? code
                return (code, raw.prefix(1).localizedUppercase + raw.dropFirst())
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    private static let key = "language"   // UserDefaults; absent/"" = follow system
    private(set) static var bundle: Bundle = .main

    static var override: String? {
        let v = UserDefaults.standard.string(forKey: key)
        return (v?.isEmpty ?? true) ? nil : v
    }

    static func apply(_ code: String?) {
        if let code, !code.isEmpty {
            UserDefaults.standard.set(code, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        load()
    }

    static func load() {
        if let code = override,
           let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let b = Bundle(path: path) {
            bundle = b
        } else {
            bundle = .main
        }
    }
}

func L(_ key: String) -> String { Loc.bundle.localizedString(forKey: key, value: key, table: nil) }

// Debug trace to /tmp/relayout.log. Compiled out unless built with -DDEBUG:
// these lines include the user's selected text, which must never be written to
// disk in a release build. The empty release body is inlined away under -O.
// @autoclosure: in a release build the message is never built, so a trace whose
// argument costs something (a TIS call, an AX read) is free there.
#if DEBUG
private let dbgTime: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss.SSS"; return f
}()
#endif
func dbg(_ s: @autoclosure () -> String) {
#if DEBUG
    // Passwords never reach the trace: nothing is written while one is being typed.
    if IsSecureEventInputEnabled() || focusedIsSecureField() { return }
    let dbgPath = "/tmp/relayout.log"
    let data = Data((dbgTime.string(from: Date()) + " " + dbgRedact(s()) + "\n").utf8)
    if let h = FileHandle(forWritingAtPath: dbgPath) {
        h.seekToEndOfFile(); h.write(data); h.closeFile()
    } else {
        try? data.write(to: URL(fileURLWithPath: dbgPath))
    }
#endif
}

/// Masks every quoted string in a trace line (typed keys, words, selections):
/// letters become "a" (Latin) or "я" (Cyrillic), digits "0", other symbols "·";
/// spaces and escapes (`\r`, `\u{1C}`) stay. Text outside quotes is kept.
/// Monotonic clock in milliseconds, for trace timings.
func uptimeMs() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }

func dbgRedact(_ line: String) -> String {
    var out = "", quoted = false
    var it = line.makeIterator()
    while let c = it.next() {
        if c == "\"" { quoted.toggle(); out.append(c); continue }
        guard quoted else { out.append(c); continue }
        if c == "\\" {
            out.append(c)
            guard let e = it.next() else { break }
            out.append(e)
            if e == "u" { while let h = it.next() { out.append(h); if h == "}" { break } } }
        } else if c.isLetter {
            out.append(c.unicodeScalars.contains { (0x400...0x52F).contains($0.value) } ? "я" : "a")
        } else if c.isNumber {
            out.append("0")
        } else {
            out.append(c == " " ? " " : "·")
        }
    }
    return out
}

/// Key codes the trace may name: they type no text (Return, Tab, Space, Delete,
/// Esc, keypad Enter, navigation). Any other key is logged as "·".
let dbgKeyNames: Set<Int> = [36, 48, 49, 51, 53, 76, 115, 116, 117, 119, 121, 123, 124, 125, 126]

func focusedIsSecureField() -> Bool {
    let sys = AXUIElementCreateSystemWide()
    var el: CFTypeRef?
    guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &el) == .success,
          let el, CFGetTypeID(el) == AXUIElementGetTypeID() else { return false }
    var sub: CFTypeRef?
    return AXUIElementCopyAttributeValue(el as! AXUIElement, kAXSubroleAttribute as CFString, &sub) == .success
        && (sub as? String) == (kAXSecureTextFieldSubrole as String)
}

func fourCharCode(_ s: String) -> FourCharCode {
    var r: FourCharCode = 0
    for b in s.utf8.prefix(4) { r = (r << 8) + FourCharCode(b) }
    return r
}

// KeyStroke, LayoutMaps and the conversion engine (transliterate/convertWrong/
// tokenize/script detection) live in Core/Engine.swift — shared with the Windows
// port. macOS builds compile that file alongside this one (see build.sh).

// MARK: - Layout engine
//
// For one installed keyboard layout we build, via UCKeyTranslate over every
// (keyCode, modifier-combo), two maps:
//   strokeToChar : physical key+mods  -> produced character
//   charToStroke : produced character -> physical key+mods   (reverse)
//
// Transliteration is then: char --(source.charToStroke)--> stroke
//                               --(target.strokeToChar)--> char
// This is layout-driven, so the Option layer (ß/æ/… <-> ы/э/ъ/ё) resolves
// automatically — no hand-coded character tables.

final class Layout: AutoLayout {
    let id: String
    let source: TISInputSource
    private(set) var charToStroke: [String: KeyStroke] = [:]
    private(set) var strokeToChar: [KeyStroke: String] = [:]
    private(set) var isCyrillic = false

    var name: String {
        TISGetInputSourceProperty(source, kTISPropertyLocalizedName)
            .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? id
    }

    // BCP-47 language of this layout (e.g. "ru", "uk", "en"), for the auto-mode
    // trigram model lookup. nil if the source reports no language.
    var languageCode: String? {
        guard let p = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
              let langs = Unmanaged<CFArray>.fromOpaque(p).takeUnretainedValue() as? [String]
        else { return nil }
        return langs.first.map { String($0.prefix(2)) }   // "ru-RU" -> "ru"
    }

    init?(_ src: TISInputSource) {
        source = src
        guard let idPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return nil }
        id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
        guard let dataPtr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let cfData = Unmanaged<CFData>.fromOpaque(dataPtr).takeUnretainedValue()
        let data = cfData as Data

        let kbType = UInt32(LMGetKbdType())
        // none, shift, option, shift+option — in carbon-mods >> 8 form
        let modsList: [UInt32] = [
            0,
            UInt32(shiftKey) >> 8,
            UInt32(optionKey) >> 8,
            UInt32(shiftKey | optionKey) >> 8,
        ]
        let opts = OptionBits(1 << kUCKeyTranslateNoDeadKeysBit) // resolve dead keys to standalone glyph

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let layoutPtr = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            for kc in UInt16(0)..<UInt16(128) {
                // prefer simplest modifier first so plain keys win the reverse map
                for m in modsList {
                    var deadState: UInt32 = 0
                    var buf = [UniChar](repeating: 0, count: 8)
                    var len = 0
                    let st = UCKeyTranslate(layoutPtr, kc, UInt16(kUCKeyActionDown), m, kbType,
                                            opts, &deadState, buf.count, &len, &buf)
                    guard st == noErr, len > 0 else { continue }
                    let s = String(utf16CodeUnits: buf, count: len)
                    guard let f = s.unicodeScalars.first, f.value >= 0x20 else { continue } // skip control chars
                    let stroke = KeyStroke(keyCode: kc, mods: m)
                    if strokeToChar[stroke] == nil { strokeToChar[stroke] = s }
                    if charToStroke[s] == nil { charToStroke[s] = stroke }
                }
            }
        }
        if charToStroke.isEmpty { return nil }
        isCyrillic = strokeToChar.values.contains { $0.unicodeScalars.first.map(isCyrLetter) ?? false }
    }

    // Enabled keyboard layouts, in the system input-menu order
    // (TISCreateInputSourceList order matches AppleEnabledInputSources / the menu).
    //
    // Building each Layout runs UCKeyTranslate over 128 keys × 4 modifier combos,
    // so the result is cached and reused on every retype. The cache is dropped via
    // invalidateCache() when the enabled set changes (see AppController's
    // kTISNotifyEnabledKeyboardInputSourcesChanged observer). Main-thread only
    // (TIS APIs are), so no locking.
    private static var cachedEnabled: [Layout]?

    static func enabledList() -> [Layout] {
        if let cached = cachedEnabled { return cached }
        let built = buildEnabledList()
        cachedEnabled = built
        return built
    }

    static func invalidateCache() { cachedEnabled = nil }

    private static func buildEnabledList() -> [Layout] {
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
        guard let listPtr = TISCreateInputSourceList(filter, false)?.takeRetainedValue() else { return [] }
        var out: [Layout] = []
        for i in 0..<CFArrayGetCount(listPtr) {
            guard let raw = CFArrayGetValueAtIndex(listPtr, i) else { continue }
            let src = Unmanaged<TISInputSource>.fromOpaque(raw).takeUnretainedValue()
            if let l = Layout(src) { out.append(l) }
        }
        return out
    }
}

// MARK: - Hotkey model + helpers (file scope)

enum HKMode: Int { case carbon = 0, modTap = 1 }

/// A recorded hotkey: a Carbon combo (`code` + `mods`) or a modifier-tap chord,
/// firing after `taps` activations within the double-tap window.
struct Hotkey: Equatable {
    var mode: HKMode
    var code: UInt32 = 0          // carbon: virtual key
    var mods: UInt32 = 0          // carbon: Carbon modifier mask
    var chord: [UInt16] = []      // modTap: modifier virtual keys
    var taps = 1
    var display: String

    /// Same activation whatever the tap count: the single-tap one would fire on
    /// the other's first tap. Left/right modifiers count as one key.
    func clashes(with o: Hotkey) -> Bool {
        guard mode == o.mode else { return false }
        return mode == .carbon ? code == o.code && mods == o.mods
                               : Set(chord.map(canonicalMod)) == Set(o.chord.map(canonicalMod))
    }

    /// True when a keyDown with this key code and these flags is this combo.
    func isCombo(code c: Int64, flags: CGEventFlags) -> Bool {
        guard mode == .carbon, c == Int64(code) else { return false }
        var m: UInt32 = 0
        if flags.contains(.maskCommand)   { m |= UInt32(cmdKey) }
        if flags.contains(.maskAlternate) { m |= UInt32(optionKey) }
        if flags.contains(.maskControl)   { m |= UInt32(controlKey) }
        if flags.contains(.maskShift)     { m |= UInt32(shiftKey) }
        return m == mods
    }

    /// The hotkey stored under `prefix` (`hk` -> `hkType`, `hkCode`, …); nil when none is.
    static func load(_ d: UserDefaults, prefix p: String) -> Hotkey? {
        guard d.object(forKey: p + "Type") != nil else { return nil }
        return Hotkey(mode: HKMode(rawValue: d.integer(forKey: p + "Type")) ?? .carbon,
                      code: UInt32(d.integer(forKey: p + "Code")),
                      mods: UInt32(d.integer(forKey: p + "Mods")),
                      chord: (d.array(forKey: p + "Chord") as? [Int])?.map { UInt16($0) } ?? [],
                      taps: max(1, d.integer(forKey: p + "Taps")),   // 0 (absent) -> 1
                      display: d.string(forKey: p + "Display") ?? "")
    }

    func save(_ d: UserDefaults, prefix p: String) {
        d.set(mode.rawValue, forKey: p + "Type")
        d.set(Int(code), forKey: p + "Code")
        d.set(Int(mods), forKey: p + "Mods")
        d.set(chord.map { Int($0) }, forKey: p + "Chord")
        d.set(max(1, taps), forKey: p + "Taps")
        d.set(display, forKey: p + "Display")
    }

    static func remove(_ d: UserDefaults, prefix p: String) {
        for k in ["Type", "Code", "Mods", "Chord", "Taps", "Display"] { d.removeObject(forKey: p + k) }
    }
}

func carbonModsFrom(_ f: NSEvent.ModifierFlags) -> UInt32 {
    var m: UInt32 = 0
    if f.contains(.command) { m |= UInt32(cmdKey) }
    if f.contains(.option)  { m |= UInt32(optionKey) }
    if f.contains(.control) { m |= UInt32(controlKey) }
    if f.contains(.shift)   { m |= UInt32(shiftKey) }
    return m
}

func comboDisplay(_ code: UInt16, _ f: NSEvent.ModifierFlags, _ chars: String?) -> String {
    var s = ""
    if f.contains(.control) { s += "⌃" }
    if f.contains(.option)  { s += "⌥" }
    if f.contains(.shift)   { s += "⇧" }
    if f.contains(.command) { s += "⌘" }
    return s + keyName(code, chars)
}

func keyName(_ code: UInt16, _ chars: String?) -> String {
    switch Int(code) {
    case kVK_Space:  return "Space"
    case kVK_Return: return "↩"
    case kVK_Tab:    return "⇥"
    case kVK_Delete: return "⌫"
    case kVK_Escape: return "⎋"
    case kVK_F1: return "F1"; case kVK_F2: return "F2"; case kVK_F3: return "F3"
    case kVK_F4: return "F4"; case kVK_F5: return "F5"; case kVK_F6: return "F6"
    case kVK_F7: return "F7"; case kVK_F8: return "F8"; case kVK_F9: return "F9"
    case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
    case kVK_LeftArrow: return "←"; case kVK_RightArrow: return "→"
    case kVK_UpArrow: return "↑"; case kVK_DownArrow: return "↓"
    default:
        if let c = chars, !c.isEmpty, c != " " { return c.uppercased() }
        return "key\(code)"
    }
}

func modKeyLabel(_ kc: UInt16) -> String {
    let sym: String
    switch Int(kc) {
    case kVK_Option, kVK_RightOption:   sym = "⌥"
    case kVK_Control, kVK_RightControl: sym = "⌃"
    case kVK_Command, kVK_RightCommand: sym = "⌘"
    case kVK_Shift, kVK_RightShift:     sym = "⇧"
    default:                            sym = "?"
    }
    let right = [kVK_RightOption, kVK_RightControl, kVK_RightCommand, kVK_RightShift].contains(Int(kc))
    return "\(right ? "right" : "left") \(sym)"
}

func chordDisplay(_ set: Set<UInt16>) -> String {
    set.sorted().map(modKeyLabel).joined(separator: "+")
}

// Which modifier KEYS are down, distinguishing left/right via device-dependent bits.
// Modifier set from a CGEvent's flags. CGEventFlags carries only the
// device-INDEPENDENT masks (no left/right bits), so we map each group to its
// canonical (left) keyCode — left and right of a modifier are treated as the
// same hotkey, which is what users expect.
func modsFromCGFlags(_ f: CGEventFlags) -> Set<UInt16> {
    var s = Set<UInt16>()
    if f.contains(.maskControl)   { s.insert(UInt16(kVK_Control)) }
    if f.contains(.maskShift)     { s.insert(UInt16(kVK_Shift)) }
    if f.contains(.maskAlternate) { s.insert(UInt16(kVK_Option)) }
    if f.contains(.maskCommand)   { s.insert(UInt16(kVK_Command)) }
    return s
}

// Right-modifier keyCode -> its left equivalent (canonical), so a chord recorded
// on either side matches the flag-derived set above.
/// What a tapped key or click can do to the text (engine `KeyRole`).
func keyRole(_ type: CGEventType, _ event: CGEvent) -> KeyRole {
    guard type == .keyDown else { return .click }
    if event.flags.contains(.maskCommand) || event.flags.contains(.maskControl) { return .command }
    switch Int(event.getIntegerValueField(.keyboardEventKeycode)) {
    case kVK_Delete: return .backspace
    case kVK_ForwardDelete: return .forwardDelete
    case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
         kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown: return .caretMove
    case kVK_Escape, kVK_Help: return .other
    default: return .text
    }
}

func canonicalMod(_ kc: UInt16) -> UInt16 {
    switch Int(kc) {
    case kVK_RightCommand: return UInt16(kVK_Command)
    case kVK_RightShift:   return UInt16(kVK_Shift)
    case kVK_RightOption:  return UInt16(kVK_Option)
    case kVK_RightControl: return UInt16(kVK_Control)
    default:               return kc
    }
}

func pressedModKeys(_ f: NSEvent.ModifierFlags) -> Set<UInt16> {
    let raw = f.rawValue
    let map: [(UInt, Int)] = [
        (0x00000001, kVK_Control), (0x00002000, kVK_RightControl),
        (0x00000002, kVK_Shift),   (0x00000004, kVK_RightShift),
        (0x00000020, kVK_Option),  (0x00000040, kVK_RightOption),
        (0x00000008, kVK_Command), (0x00000010, kVK_RightCommand),
    ]
    var s = Set<UInt16>()
    for (bit, kc) in map where raw & bit != 0 { s.insert(UInt16(kc)) }
    return s
}

// macOS symbolic-hotkey conflict lookup. Returns owner name if taken.
func systemHotkeyConflict(keyCode: UInt16, cocoaMods: UInt) -> String? {
    guard let d = UserDefaults(suiteName: "com.apple.symbolichotkeys"),
          let map = d.dictionary(forKey: "AppleSymbolicHotKeys") else { return nil }
    let MASK: UInt = 0x10_0000 | 0x08_0000 | 0x04_0000 | 0x02_0000
    let want = cocoaMods & MASK
    for (idStr, raw) in map {
        guard let entry = raw as? [String: Any],
              (entry["enabled"] as? Bool) == true,
              let value = entry["value"] as? [String: Any],
              let params = value["parameters"] as? [Any], params.count >= 3,
              let kc = (params[1] as? NSNumber)?.intValue,
              let mm = (params[2] as? NSNumber)?.intValue, kc >= 0 else { continue }
        if kc == Int(keyCode), UInt(mm) & MASK == want { return symbolicHotkeyName(Int(idStr) ?? -1) }
    }
    return nil
}

func symbolicHotkeyName(_ id: Int) -> String {
    let names: [Int: String] = [
        7: "menu bar focus", 8: "Dock focus", 32: "Mission Control",
        33: "App windows", 36: "Show Desktop", 52: "Zoom toggle", 57: "Invert colors",
        60: "Select previous input source", 61: "Select next input source",
        64: "Spotlight", 65: "Finder search", 79: "Move left a space", 81: "Move right a space",
        28: "Screenshot → file", 29: "Screenshot → clipboard",
        30: "Area screenshot → file", 31: "Area screenshot → clipboard",
        184: "Screenshot options", 162: "Launchpad", 163: "Notification Center",
        175: "Notification Center", 222: "Dictation",
    ]
    return names[id] ?? "a macOS shortcut (#\(id))"
}

// MARK: - Shortcut recorder field (System-Settings-style, click to record)

final class ShortcutField: NSView {
    var display: String { didSet { needsDisplay = true } }
    var onCommit: ((Hotkey) -> Void)?
    // Called true when recording starts, false when it ends — lets the owner
    // suspend the live hotkey so it doesn't fire (and steal focus) while typing one.
    var onRecordingChanged: ((Bool) -> Void)?

    private var recording = false { didSet { needsDisplay = true } }
    private var monitor: Any?
    private var peak: Set<UInt16>?
    private var comboUsed = false
    private var committing = false       // suppress resign-triggered stop during commit churn

    // Current sequence being recorded: an activation repeated N times within the
    // window. A finalize-timer fires `seqWindow` after the last tap; that's when
    // the sequence is "finished" and committed. The field stays focused so the
    // user can immediately record a new sequence (which replaces this one).
    private let seqWindow = 0.45
    private var seqMode: HKMode?
    private var seqCode: UInt32 = 0
    private var seqMods: UInt32 = 0
    private var seqChord: [UInt16] = []
    private var seqBase = ""              // base display of the activation (no ×N)
    private var seqTaps = 0
    private var seqLastTime: TimeInterval = 0
    private var seqTimer: DispatchWorkItem?

    init(display: String, label: String) {
        self.display = display
        super.init(frame: NSRect(x: 0, y: 0, width: 150, height: 24))
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError("ShortcutField is code-only") }

    // VoiceOver: announce the current shortcut and let activation start recording.
    override func accessibilityValue() -> Any? { recording ? L("shortcut.recording") : display }
    override func accessibilityPerformPress() -> Bool { recording ? stop() : start(); return true }

    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }
    override var acceptsFirstResponder: Bool { true }

    // Finalize recording if focus leaves the field (e.g. user clicks another
    // control), so a chord recording doesn't keep capturing the keyboard.
    override func resignFirstResponder() -> Bool {
        if recording, !committing { stop() }
        return super.resignFirstResponder()
    }

    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.textBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = recording ? 2 : 1
        path.stroke()

        // While recording: show the captured sequence once there is one, else the
        // "Type shortcut…" placeholder.
        let placeholder = recording && seqMode == nil
        let text = recording ? (seqMode == nil ? L("shortcut.placeholder") : seqDisplay()) : display
        let color: NSColor = placeholder ? .secondaryLabelColor : .labelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: color,
        ]
        let sz = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2),
                                withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        recording ? stop() : start()
    }

    private func start() {
        recording = true
        peak = nil; comboUsed = false
        seqMode = nil; seqTaps = 0; seqBase = ""; seqTimer?.cancel(); seqTimer = nil
        onRecordingChanged?(true)   // pause the live hotkey while we capture a new one
        window?.makeFirstResponder(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] ev in
            guard let self else { return ev }
            if ev.type == .keyDown { return self.handleKeyDown(ev) }
            self.handleFlags(ev)
            return nil
        }
    }

    // Stop recording without saving (e.g. the Reset button applies its own value).
    func endRecording() { stop(finalize: false) }

    // finalize=true commits an in-progress sequence (click away / re-click).
    private func stop(finalize: Bool = true) {
        guard recording else { return }
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        seqTimer?.cancel(); seqTimer = nil
        if finalize, seqMode != nil { finalizeSequence(); return }   // it stops recording
        recording = false
        onRecordingChanged?(false)   // resume the live hotkey
    }

    private func handleKeyDown(_ ev: NSEvent) -> NSEvent? {
        // Let Esc through so the Settings window closes normally (its
        // cancelOperation). Closing resigns focus -> stop() finalizes the sequence.
        if ev.keyCode == UInt16(kVK_Escape) { return ev }
        comboUsed = true
        let mods = ev.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !mods.intersection([.command, .option, .control]).isEmpty else { return nil } // need a real modifier
        let disp = comboDisplay(ev.keyCode, mods, ev.charactersIgnoringModifiers)
        recordActivation(.carbon, UInt32(ev.keyCode), carbonModsFrom(mods), [], disp)
        return nil
    }

    private func handleFlags(_ ev: NSEvent) {
        let cur = pressedModKeys(ev.modifierFlags)
        if cur.isEmpty {
            if !comboUsed, let p = peak, !p.isEmpty {
                recordActivation(.modTap, 0, 0, Array(p), chordDisplay(p))
            }
            peak = nil; comboUsed = false
        } else if peak == nil || cur.count > (peak?.count ?? 0) {
            peak = cur
        }
    }

    private func seqDisplay() -> String { seqTaps > 1 ? "\(seqBase) ×\(seqTaps)" : seqBase }

    // An activation completed. Same activation again within the window extends the
    // sequence (×N); otherwise it starts a fresh one. (Re)arm the finalize timer —
    // when it fires (no more taps), the sequence is committed.
    private func recordActivation(_ mode: HKMode, _ code: UInt32, _ mods: UInt32, _ chord: [UInt16], _ base: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if base == seqBase, now - seqLastTime <= seqWindow {
            seqTaps += 1
        } else {
            seqMode = mode; seqCode = code; seqMods = mods; seqChord = chord; seqBase = base; seqTaps = 1
        }
        seqLastTime = now
        display = seqDisplay()
        seqTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finalizeSequence() }
        seqTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seqWindow, execute: work)
    }

    // The sequence is finished (window elapsed) -> save it and stop recording, so
    // both hotkeys and auto-correct resume at once (they are paused while recording).
    private func finalizeSequence() {
        guard let mode = seqMode else { return }
        seqTimer = nil
        let disp = seqDisplay()
        display = disp
        committing = true                 // onCommit relayouts the window / churns focus
        defer { committing = false }
        onCommit?(Hotkey(mode: mode, code: seqCode, mods: seqMods, chord: seqChord, taps: seqTaps, display: disp))
        stop(finalize: false)
    }
}

// Settings window that closes on Esc (macOS convention via cancelOperation).
final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }   // Esc

    // No main menu (agent app), so Cmd+W / Cmd+Q have no handler. Handle them here,
    // matching the physical keys (keyCode) so it works on any keyboard layout.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch Int(event.keyCode) {
        case kVK_ANSI_W: close(); return true
        case kVK_ANSI_Q: NSApp.terminate(nil); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}

// The app cell of the exceptions table: icon + name. Removal is the list's ⊖, like
// Login Items; the two flags are checkbox columns of their own.
final class ExcRowView: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [icon, label] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        label.lineBreakMode = .byTruncatingTail
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, icon img: NSImage) {
        label.stringValue = name
        icon.image = img
    }
}

// MARK: - App controller

final class AppController: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    static let shared = AppController()

    private var statusItem: NSStatusItem!
    private var hotKeyRefs: [HotkeySlot: EventHotKeyRef] = [:]
    private var handlerInstalled = false
    private var appearanceObservation: NSKeyValueObservation?   // refresh static icon on dark/light switch

#if SPARKLE
    // Sparkle auto-updater. startingUpdater:true begins scheduled checks against
    // SUFeedURL (Info.plist), verified with SUPublicEDKey.
    private var updater: SPUStandardUpdaterController?
#endif

    // Retype runs on a dedicated serial queue, NOT a Swift-Concurrency Task: the
    // work is blocking input synthesis (waitModifiersReleased / typeUnicode use
    // usleep, plus synchronous CGEvent posting) that must not occupy the
    // cooperative thread pool. The serial queue also guarantees one retype at a
    // time. TIS calls (convert / TISSelectInputSource) are bounced to the main
    // thread via DispatchQueue.main.sync because TIS asserts off-main on macOS 26;
    // this never deadlocks since the main thread never blocks waiting on `worker`.
    private let worker = DispatchQueue(label: "relayout.worker")

    // Two user-configurable hotkeys, persisted under their own UserDefaults prefix.
    // The raw value is the Carbon EventHotKeyID.id.
    private enum HotkeySlot: UInt32, CaseIterable {
        case retype = 1, autoToggle = 2
        var prefix: String { self == .retype ? "hk" : "autoHk" }
        var caption: String { L(self == .retype ? "settings.hotkey" : "settings.autoHotkey") }
    }
    private var hotkey = AppController.defaultHotkey
    private var autoHotkey: Hotkey?   // unset by default: nothing registered
    private func definition(_ slot: HotkeySlot) -> Hotkey? { slot == .retype ? hotkey : autoHotkey }

    // Last conversion, for press-again undo: the next hotkey press reverses it
    // (erases the typed text, restores the original, flips the input source
    // back) until any other key or click (`startUndoWatch`) — the caret may have
    // moved past it.
    // The press-again record (engine `PressAgain`), main thread only.
    private typealias Conv = Conversion<TISInputSource, Layout>
    // Pauses around synthetic input, in microseconds. `landPause`: typed text gets
    // to land in the app before the next step (a layout switch, a reselect); auto
    // mode waits less, where typing speed shows. `pollInterval`: one step of a wait
    // loop. `keyGap`: between posted keys, so slow apps drop none.
    private let landPause: useconds_t = 20_000
    private let autoLandPause: useconds_t = 10_000
    private let pollInterval: useconds_t = 20_000
    private let keyGap: useconds_t = 1500
    private var pressAgain = PressAgain<TISInputSource, Layout>()
    private var workMark = 0   // worker only: `pressAgain.mark` when the running correction began
    fileprivate func endUndoWindow() { pressAgain.forget() }
    // Worker.
    private func recordConversion(_ c: Conv) {
        DispatchQueue.main.sync { pressAgain.record(c, since: workMark) }
    }
    private var undoTap: CFMachPort?
    private var undoTapSource: CFRunLoopSource?

    // Any key or click of the user's ends press-again undo; our own combo hotkey
    // and synthetic keys do not. Runs whether or not auto-correct is on.
    private func startUndoWatch() {
        let mask = [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            .reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
        let cb: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<AppController>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = me.undoTap { CGEvent.tapEnable(tap: t, enable: true) }
            } else if event.getIntegerValueField(.eventSourceUserData) != AppController.synthMarker,
                      type != .keyDown || ![me.hotkey, me.autoHotkey].contains(where: {
                          $0?.isCombo(code: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags) == true }) {
                // A key may be the boundary that just began an auto-correction (the key tap
                // runs first): no epoch bump, or that correction could not be undone. Keys
                // typed during a correction end the window on replay (`autoFeed`).
                if type == .keyDown { me.pressAgain.drop() } else { me.endUndoWindow() }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let (tap, src) = installEventTap(mask, cb) else { return }
        undoTap = tap; undoTapSource = src
    }
    // When the Cmd+C probe last found nothing selected: a second synthetic Cmd+C
    // within a second would be DeepL's Cmd+C-Cmd+C trigger.
    private var lastEmptyProbe: Double = 0
    private var autoChainTarget: Layout?   // layout of the last auto candidate, for bridged words

    // modifier-tap runtime state
    fileprivate var keyTap: CFMachPort?       // CGEventTap that flags key presses during a hold
    // The last physical keyDown the auto tap fed, for the Globe double (below).
    private var lastFedKey: (code: Int64, time: Double) = (-1, 0)
    private var dbgRecentFed: [(code: Int64, time: Double)] = []
    private var keyTapSource: CFRunLoopSource?
    // Per hotkey (engine `HotkeyTaps`): the modifier-only tap being pressed, and the
    // count toward a multi-tap hotkey (`taps`; press-again counts a whole sequence once).
    private var modifierTaps: [HotkeySlot: ModifierTap<UInt16>] = [:]
    private var tapSequences: [HotkeySlot: TapSequence] = [:]

    // settings
    private var settingsWindow: NSWindow?
    private var recordingHotkey = false   // hotkey + auto-correct are paused only while the recorder field is capturing
    private var excWindow: NSWindow?    // auto-correct exceptions editor
    private weak var autoCb: NSButton?
    private weak var autoExcBtn: NSButton?
    private weak var autoEnterCb: NSButton?
    private weak var autoSimilarCb: NSButton?
    private weak var autoSpellCb: NSButton?
    private weak var learnedLabel: NSTextField?
    private weak var learnedViewBtn: NSButton?
    private var learnedWindow: NSWindow?
    private weak var learnedTable: NSTableView?
    private weak var autoInfo: NSImageView?
    private weak var excTable: NSTableView?
    private var lastActiveBundleID: String?   // last non-self frontmost app ("exclude current")
    // The app that gets the keys (self included): the per-app exceptions check it, the
    // key tap on every key, so it is cached (`refreshKeyApp`).
    private var frontBundleID: String? = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

    // Spotlight takes the keyboard without becoming frontmost, so NSWorkspace would
    // apply the exceptions of the app under it: ask AX for the app with keyboard
    // focus. An app that does not answer AX (Electron, until asked) falls back to
    // the frontmost one, or to Spotlight while its panel is on screen.
    private func refreshKeyApp() {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var v: CFTypeRef?
        var pid: pid_t = 0
        if AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &v)
            == .success, let v, CFGetTypeID(v) == AXUIElementGetTypeID(),
           AXUIElementGetPid(v as! AXUIElement, &pid) == .success,
           let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier {
            frontBundleID = bid
        } else if let wins = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]],
                  wins.contains(where: { ($0[kCGWindowOwnerName as String] as? String) == "Spotlight"
                                         && ($0[kCGWindowLayer as String] as? Int ?? 0) > 0 }) {
            frontBundleID = "com.apple.Spotlight"
        } else {
            frontBundleID = front
        }
    }
    private var shortcutFields: [HotkeySlot: ShortcutField] = [:]   // replaced when Settings is rebuilt
    private var conflictLabels: [HotkeySlot: NSTextField] = [:]
    private weak var loginCheckbox: NSButton?

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        UserDefaults.standard.set(0, forKey: "NSInitialToolTipDelay")   // app-wide: tooltips show at once
        Loc.load()   // apply saved language override before any UI is built
        pinOldDefaultHotkey()   // before anything this launch writes a preference
        mergeNewDefaultExclusions()
#if SPARKLE
        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
#endif
        promptAccessibilityIfNeeded()
        // Global for every AX call (default ~6 s): the key taps ask AX inline, and a hung
        // app would otherwise stall all input until macOS disables the tap.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.1)
        loadHotkey()
        installHotKeyHandler()
        applyHotkey()
        applyAutoMode()          // start the auto-correct monitor if enabled
        startUndoWatch()
        // Track the last non-self frontmost app so "Exclude current app" can target
        // it (once our Settings/Exceptions window is key, WE are frontmost).
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.frontBundleID = app?.bundleIdentifier
            if let app, let bid = app.bundleIdentifier, bid != Bundle.main.bundleIdentifier {
                self?.lastActiveBundleID = bid
            }
        }
        setupMenu()
        // mirror the system input-source indicator in the menu bar
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(inputSourceChanged),
                        name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
        // enabled-set change -> the cached layout list is stale; drop it and refresh
        dnc.addObserver(self, selector: #selector(enabledSourcesChanged),
                        name: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String), object: nil)
        // refresh the (static) menu-bar icon when the system switches dark/light
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateStatusIcon() }
        }
        updateStatusIcon()
        if Layout.enabledList().count < 2 { reportMissingLayouts() }
    }

    @objc private func inputSourceChanged() {
        DispatchQueue.main.async { self.updateStatusIcon() }
    }

    @objc private func enabledSourcesChanged() {
        DispatchQueue.main.async {
            Layout.invalidateCache()
            self.setupMenu()        // refresh the layout list shown in the menu
            self.updateStatusIcon()
            self.updateAutoAvailability()
        }
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        // Always the static "rL" wordmark. It's monochrome, so use it as a TEMPLATE
        // image: the system tints it to the menu-bar foreground colour (white on a
        // dark bar, black on a light bar), correct even when the bar's tint doesn't
        // match the app's Light/Dark appearance (e.g. wallpaper-driven).
        // Auto-correct on adds a dot in the empty top-right corner. A template keeps
        // only alpha, so the dot can't be green: it is the bar's foreground at
        // partial alpha, a lighter tone of the glyph.
        let src = NSImage(named: "for-light-text-1024") ?? NSApp.applicationIconImage ?? NSImage()
        let dot = autoMode && autoAvailable
        let glyph = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            src.draw(in: r)
            if dot {
                NSColor.black.withAlphaComponent(0.6).setFill()
                NSBezierPath(ovalIn: NSRect(x: r.maxX - 4.5, y: r.maxY - 4.5, width: 4.5, height: 4.5)).fill()
            }
            return true
        }
        glyph.isTemplate = true
        button.image = glyph
        button.imagePosition = .imageOnly
        button.title = ""
        button.setAccessibilityLabel("reLayout")
    }

    // MARK: menu

    private func setupMenu() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            updateStatusIcon()
        }
        let menu = NSMenu()
#if SPARKLE
        menu.addItem(NSMenuItem(title: L("menu.checkUpdates"), action: #selector(checkForUpdates), keyEquivalent: ""))
#endif
        menu.addItem(NSMenuItem(title: L("menu.settings"), action: #selector(openReLayoutSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("menu.quit"), action: #selector(quit), keyEquivalent: "q"))
        for it in menu.items where it.action != nil { it.target = self }
        statusItem.menu = menu
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // Auto-correct only tells scripts apart (Cyrillic vs Latin); with every enabled
    // layout in one script it never fires, so the checkbox is shown off and disabled.
    // The stored preference is kept for when a layout of the other script returns.
    private var autoAvailable: Bool {
        let enabled = Layout.enabledList()
        return enabled.contains { $0.isCyrillic } && enabled.contains { !$0.isCyrillic }
    }

    private func updateAutoAvailability() {
        let enabled = Layout.enabledList()
        let ok = autoAvailable
        autoCb?.isEnabled = ok
        autoCb?.state = ok && autoMode ? .on : .off
        // Disabled by the system (no such layouts, no dictionary): shown off. Disabled only
        // because auto-correct is off: shows its stored state. The preference is kept.
        for (cb, possible, pref) in [(autoEnterCb, ok, autoEnterNewline),
                                     (autoSimilarCb, ok && hasSimilarLayouts(enabled, model: trigram), autoSameScript),
                                     (autoSpellCb, ok && hasSpellDictionary(enabled), autoSpell)] {
            cb?.isEnabled = possible && autoMode
            cb?.state = possible && pref ? .on : .off
        }
        learnedLabel?.stringValue = String(format: L("settings.learned"), String(learnedConvert.count + learnedKeep.count))
        learnedViewBtn?.isEnabled = ok && autoMode
        autoInfo?.isHidden = ok
        autoInfo?.toolTip = String(format: L("settings.autoCorrectUnavailable"),
                                   enabled.map(\.name).joined(separator: ", "))
    }

    @objc private func toggleAutoCorrect(_ sender: NSButton) {
        autoMode = (sender.state == .on)   // setter starts/stops the monitor
        updateAutoAvailability()
    }

    @objc private func toggleAutoEnter(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "autoEnterNewline")
    }

#if SPARKLE
    @objc private func checkForUpdates() { updater?.checkForUpdates(nil) }
    @objc private func toggleAutoUpdate(_ sender: NSButton) {
        updater?.updater.automaticallyChecksForUpdates = (sender.state == .on)
    }
#endif


    private func reportMissingLayouts() {
        let a = NSAlert()
        a.messageText = L("alert.needLayouts.title")
        a.informativeText = L("alert.needLayouts.body")
        a.runModal()
    }

    private func promptAccessibilityIfNeeded() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: hotkey

    // Single entry point for both hotkey modes and both hotkeys. Fires once the
    // hotkey has been activated `taps` times (engine `TapSequence`; 1 = at once).
    private func hotkeyActivated(_ slot: HotkeySlot) {
        guard let hk = definition(slot) else { return }
        let typed = autoRun.hotkeyTarget
        guard tapSequences[slot, default: TapSequence()].activate(at: ProcessInfo.processInfo.systemUptime,
                                                                  taps: hk.taps) else { return }
        switch slot {
        case .retype:
            // Hotkey-off apps (#1): Figma's canvas reads the key code of our typed
            // Unicode events (0 = "A", the Frame tool) and its erase backspaces can
            // delete the selected layers.
            refreshKeyApp()
            if isHotkeyExcluded() { dbg("retype hotkey: off in \(frontBundleID ?? "?")"); return }
            beginCorrection { self.performRetype(typed: typed) }
        case .autoToggle:
            toggleAutoModeFromHotkey()
        }
    }

    // Unavailable auto-correct (one script) leaves the checkbox disabled, so the
    // hotkey can't change the preference either.
    private func toggleAutoModeFromHotkey() {
        guard autoAvailable else { dbg("auto toggle hotkey: unavailable, ignored"); return }
        autoMode.toggle()
        dbg("auto toggle hotkey: autoMode=\(autoMode)")
        updateAutoAvailability()
    }

    private func installHotKeyHandler() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let ih = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let st = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            dbg("hotkey fired id=\(id.id) status=\(st)")
            if st == noErr, let slot = HotkeySlot(rawValue: id.id) { AppController.shared.hotkeyActivated(slot) }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = (ih == noErr)
        dbg("InstallEventHandler status=\(ih)")
    }

    // Unregister the live hotkeys (both modes). Used to pause them while the user
    // records a new one, and as the first half of applyHotkey.
    private func suspendHotkey() {
        for r in hotKeyRefs.values { UnregisterEventHotKey(r) }
        hotKeyRefs = [:]
        removeEventTap(&keyTap, &keyTapSource)
        modifierTaps = [:]; tapSequences = [:]   // no stale press or count carried into a new hotkey
    }

    // Tear down whatever is active, then install the current hotkeys.
    private func applyHotkey() {
        suspendHotkey()
        // Disabled only while the shortcut recorder is actively capturing: taps there
        // must not fire a retype (which could leak our synthetic Cmd+X into the field).
        // finalizeSequence() commits a tap-sequence and calls applyHotkey() while the
        // field is still focused — this guard keeps the hotkey suspended until the
        // recorder stops (onRecordingChanged(false) clears the flag, then re-applies).
        // Having Settings merely open no longer disables the hotkey.
        guard !recordingHotkey else { return }

        var needsTap = false
        for slot in HotkeySlot.allCases {
            guard let hk = definition(slot) else { continue }
            switch hk.mode {
            case .carbon:
                var ref: EventHotKeyRef?
                let st = RegisterEventHotKey(hk.code, hk.mods, EventHotKeyID(signature: fourCharCode("RLAY"), id: slot.rawValue),
                                             GetApplicationEventTarget(), 0, &ref)
                if let ref { hotKeyRefs[slot] = ref }
                dbg("carbon hotkey \(slot) code=\(hk.code) mods=\(hk.mods) status=\(st)")
            case .modTap:
                needsTap = true
                dbg("modTap hotkey \(slot) chord=\(hk.chord) taps=\(hk.taps)")
            }
        }
        if needsTap { setupTapMonitors() }
    }

    // Create a listen-only session event tap, add it to the main run loop, enable it.
    private func installEventTap(_ mask: CGEventMask, _ callback: CGEventTapCallBack,
                                 options: CGEventTapOptions = .listenOnly) -> (CFMachPort, CFRunLoopSource?)? {
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: options, eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return nil }
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return (tap, src)
    }
    private func removeEventTap(_ tap: inout CFMachPort?, _ source: inout CFRunLoopSource?) {
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes); source = nil }
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t); tap = nil }
    }

    // Fire when exactly the configured set of modifier keys is tapped together
    // (pressed as a chord, then fully released) with no symbol key / mouse between.
    private func setupTapMonitors() {
        // The WHOLE mod-tap detection runs in ONE CGEventTap (Accessibility-backed,
        // no Input Monitoring needed): the modifier flagsChanged (arm/fire) AND the
        // key/mouse-down interruption arrive through the same ordered event stream,
        // so a key pressed during the hold (e.g. Option+' ) can't lose a race with
        // the modifier-release and mis-fire. (Splitting these across an event tap +
        // NSEvent monitors — two unordered sources — was the bug.)
        // Built explicitly (one bit per event type) — a single big `1 << … | …`
        // expression makes the Swift type-checker time out on some toolchains.
        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        var mask: CGEventMask = 0
        for t in types { mask |= (CGEventMask(1) << CGEventMask(t.rawValue)) }
        let cb: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<AppController>.fromOpaque(refcon).takeUnretainedValue()
            switch type {
            case .flagsChanged:
                me.handleTapFlags(modsFromCGFlags(event.flags))
            case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown:
                me.interruptTapCycles()   // a key/mouse during the hold -> not a tap
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                if let t = me.keyTap { CGEvent.tapEnable(tap: t, enable: true) }
            default:
                break
            }
            return Unmanaged.passUnretained(event)
        }
        if let (tap, src) = installEventTap(mask, cb) { keyTap = tap; keyTapSource = src }
    }

    fileprivate func interruptTapCycles() {
        for k in modifierTaps.keys { modifierTaps[k]?.interrupt() }
    }

    // Called from the event tap on every modifier change. `cur` = the modifier
    // keys currently held. Each modifier-tap hotkey arms on its exact chord and
    // fires on a clean release.
    fileprivate func handleTapFlags(_ cur: Set<UInt16>) {
        let now = ProcessInfo.processInfo.systemUptime
        for slot in HotkeySlot.allCases {
            guard let hk = definition(slot), hk.mode == .modTap else { continue }
            let chord = Set(hk.chord.map(canonicalMod))   // normalize L/R to match cur
            if modifierTaps[slot, default: ModifierTap()].changed(held: cur, chord: chord, at: now) {
                hotkeyActivated(slot)
            }
        }
    }

    // MARK: hotkey persistence

    private func loadHotkey() {
        let d = UserDefaults.standard
        hotkey = Hotkey.load(d, prefix: HotkeySlot.retype.prefix) ?? AppController.defaultHotkey
        autoHotkey = Hotkey.load(d, prefix: HotkeySlot.autoToggle.prefix)
    }

    // default hotkey: Shift tapped twice, as on Windows
    private static let defaultHotkey = Hotkey(mode: .modTap, chord: [UInt16(kVK_Shift)], taps: 2, display: "left ⇧ ×2")

    /// Once: a Mac that ran reLayout before the default changed, and never saved a
    /// hotkey, keeps the tap of left Option its user knows.
    private func pinOldDefaultHotkey() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "hkDefaultPinned") else { return }
        d.set(true, forKey: "hkDefaultPinned")
        let usedBefore = ["autoExcludedDefaultsSeen", "SUHasLaunchedBefore", "autoMode"].contains { d.object(forKey: $0) != nil }
        guard usedBefore, Hotkey.load(d, prefix: HotkeySlot.retype.prefix) == nil else { return }
        Hotkey(mode: .modTap, chord: [UInt16(kVK_Option)], display: "left ⌥").save(d, prefix: HotkeySlot.retype.prefix)
    }

    @objc private func resetHotkey() { restoreHotkey(.retype) }
    @objc private func clearAutoHotkey() { restoreHotkey(.autoToggle) }

    // The retype hotkey goes back to its default, the auto-correct toggle to none.
    private func restoreHotkey(_ slot: HotkeySlot) {
        shortcutFields[slot]?.endRecording()   // a recording in progress must not override the reset
        commitHotkey(slot, slot == .retype ? AppController.defaultHotkey : nil)
    }

    // Commit a hotkey captured by a ShortcutField (nil = none). One matching the
    // other hotkey's activation is refused: both would fire on the same press.
    private func commitHotkey(_ slot: HotkeySlot, _ hk: Hotkey?) {
        let other: HotkeySlot = slot == .retype ? .autoToggle : .retype
        let warn: String?
        if let hk, let o = definition(other), hk.clashes(with: o) {
            warn = other.caption.trimmingCharacters(in: CharacterSet(charactersIn: ":：").union(.whitespaces))
        } else {
            let d = UserDefaults.standard
            if let hk { hk.save(d, prefix: slot.prefix) } else { Hotkey.remove(d, prefix: slot.prefix) }
            if slot == .retype { hotkey = hk ?? AppController.defaultHotkey } else { autoHotkey = hk }
            applyHotkey()
            warn = hk.flatMap(systemConflict)
        }
        shortcutFields[slot]?.display = hotkeyDisplay(slot)
        conflictLabels[slot]?.stringValue = warn.map { String(format: L("settings.conflict"), $0) } ?? ""
        conflictLabels[slot]?.isHidden = (warn == nil)   // collapse the row when no conflict
        fitSettingsWindow()                              // re-fit so row spacing stays constant
    }

    private func hotkeyDisplay(_ slot: HotkeySlot) -> String { definition(slot)?.display ?? L("shortcut.none") }

    private func systemConflict(_ hk: Hotkey) -> String? {
        hk.mode == .carbon ? systemHotkeyConflict(keyCode: UInt16(hk.code), cocoaMods: cocoaMods(hk.mods)) : nil
    }

    // Resize the Settings window to its content's natural size, keeping the
    // top-left corner fixed. Called when a row's visibility changes (the conflict
    // line) so the grid isn't stretched to a stale fixed height — which would
    // otherwise redistribute the row spacing.
    private func fitSettingsWindow() {
        guard let w = settingsWindow, let c = w.contentView else { return }
        c.layoutSubtreeIfNeeded()
        let topLeft = NSPoint(x: w.frame.minX, y: w.frame.maxY)
        w.setContentSize(c.fittingSize)
        w.setFrameTopLeftPoint(topLeft)
    }

    // carbon modifier mask -> Cocoa device-independent mask (for conflict lookup)
    private func cocoaMods(_ carbon: UInt32) -> UInt {
        var m: NSEvent.ModifierFlags = []
        if carbon & UInt32(cmdKey) != 0     { m.insert(.command) }
        if carbon & UInt32(optionKey) != 0  { m.insert(.option) }
        if carbon & UInt32(controlKey) != 0 { m.insert(.control) }
        if carbon & UInt32(shiftKey) != 0   { m.insert(.shift) }
        return m.rawValue
    }

    // MARK: settings window

    // NSApp.activate(ignoringOtherApps:) is deprecated on macOS 14+.
    private func activateApp() {
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
    }

    // Settings widget builders (shared styling).
    private func makeCheckbox(_ title: String, _ action: Selector, on: Bool) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: action)
        b.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        b.state = on ? .on : .off
        return b
    }
    private func makeSecondaryLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.alignment = .center
        return l
    }

    @objc private func openReLayoutSettings() {
        if let w = settingsWindow {
            activateApp()
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = L("settings.title")
        w.isReleasedWhenClosed = false
        guard let content = w.contentView else { return }

        // right-aligned caption column, like macOS settings forms
        func caption(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.alignment = .right
            l.textColor = .secondaryLabelColor
            l.setContentHuggingPriority(.required, for: .horizontal)
            return l
        }

        // One recorder row per hotkey: field + restore button, and an (optional)
        // conflict warning under it. A multi-tap sequence (e.g. double Shift) is
        // recorded by repeating it; no separate toggle.
        func hotkeyColumn(_ slot: HotkeySlot, reset action: Selector) -> (column: NSStackView, row: NSStackView) {
            let field = ShortcutField(display: hotkeyDisplay(slot), label: slot.caption)
            field.onCommit = { [weak self] hk in self?.commitHotkey(slot, hk) }
            field.onRecordingChanged = { [weak self] active in
                // Suspend BOTH live hotkeys and the auto-correct monitor while
                // recording, so nothing fires (or auto-edits) on the keys being captured.
                // This focus-scoped flag is the sole gate — applyHotkey/applyAutoMode read
                // it, and finalizeSequence's mid-recording re-apply is held off until stop.
                self?.recordingHotkey = active
                if active {
                    self?.suspendHotkey(); self?.stopAutoMonitor()
                } else {
                    self?.applyHotkey(); self?.applyAutoMode()
                }
            }
            shortcutFields[slot] = field
            let resetIcon = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: L("settings.restoreDefault"))
            let reset = NSButton(image: resetIcon ?? NSImage(), target: self, action: action)
            reset.isBordered = false
            reset.bezelStyle = .accessoryBar
            reset.imageScaling = .scaleProportionallyDown
            reset.toolTip = L("settings.restoreDefault")
            field.setContentHuggingPriority(.init(1), for: .horizontal)   // let it stretch to fill the row
            let row = NSStackView(views: [field, reset])
            row.orientation = .horizontal
            row.spacing = 8
            row.alignment = .centerY

            let conflict = NSTextField(labelWithString: "")
            conflict.font = .systemFont(ofSize: 11)
            conflict.textColor = .systemOrange
            conflictLabels[slot] = conflict
            if let w = definition(slot).flatMap(systemConflict) {
                conflict.stringValue = String(format: L("settings.conflict"), w)
            }
            conflict.isHidden = conflict.stringValue.isEmpty   // no empty line when no conflict

            let column = NSStackView(views: [row, conflict])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 4
            return (column, row)
        }
        let (hkColumn, hkRow) = hotkeyColumn(.retype, reset: #selector(resetHotkey))
        let (autoHkColumn, autoHkRow) = hotkeyColumn(.autoToggle, reset: #selector(clearAutoHotkey))

        let cb = makeCheckbox(L("settings.openAtLogin"), #selector(toggleLogin), on: loginEnabled())
        loginCheckbox = cb

        // language picker: "System Default" + bundled languages; tag 0 = system, n = Loc.languages[n-1]
        let langPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        langPopup.addItem(withTitle: L("settings.language.system"))
        langPopup.lastItem?.tag = 0
        for (i, lang) in Loc.languages.enumerated() {
            langPopup.addItem(withTitle: lang.name)
            langPopup.lastItem?.tag = i + 1
        }
        if let code = Loc.override, let idx = Loc.languages.firstIndex(where: { $0.code == code }) {
            langPopup.selectItem(withTag: idx + 1)
        } else {
            langPopup.selectItem(withTag: 0)
        }
        langPopup.target = self
        langPopup.action = #selector(changeLanguage(_:))

        let autoCb = makeCheckbox(L("settings.autoCorrect"), #selector(toggleAutoCorrect(_:)), on: autoMode)
        let excBtn = NSButton(title: L("settings.exceptions"), target: self, action: #selector(openExceptions))
        excBtn.bezelStyle = .rounded; excBtn.controlSize = .small
        let autoInfoIcon = NSImageView(image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil) ?? NSImage())
        autoInfoIcon.contentTintColor = .secondaryLabelColor
        let label = NSStackView(views: [autoCb, autoInfoIcon])
        label.orientation = .horizontal; label.spacing = 4; label.alignment = .centerY
        func spacer() -> NSView {
            let v = NSView(); v.setContentHuggingPriority(.init(1), for: .horizontal); return v
        }
        let autoRow = NSStackView(views: [label])
        // Exceptions cover the hotkey as well as auto-correct: a section of their own.
        let excLabel = NSTextField(labelWithString: L("settings.exc.section"))
        excLabel.textColor = .secondaryLabelColor
        excLabel.lineBreakMode = .byWordWrapping
        excLabel.preferredMaxLayoutWidth = 240
        excLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let excRow = NSStackView(views: [excLabel, spacer(), excBtn])
        excRow.orientation = .horizontal; excRow.spacing = 12; excRow.alignment = .centerY
        autoRow.orientation = .horizontal; autoRow.spacing = 12; autoRow.alignment = .centerY
        let enterCb = makeCheckbox(L("settings.autoCorrectEnter"), #selector(toggleAutoEnter(_:)), on: autoEnterNewline)
        let enterRow = NSStackView(views: [enterCb])
        enterRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)   // sub-option of auto-correct
        // The ⓘ stays live while the checkbox is disabled: it says why.
        let similarCb = makeCheckbox(L("settings.autoCorrectSimilar"), #selector(toggleAutoSimilar(_:)), on: autoSameScript)
        let similarInfo = NSImageView(image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil) ?? NSImage())
        similarInfo.contentTintColor = .secondaryLabelColor
        similarInfo.toolTip = L("settings.autoCorrectSimilar.tip")   // hints live on ⓘ, like the auto-correct row
        let similarRow = NSStackView(views: [similarCb, similarInfo])
        similarRow.orientation = .horizontal; similarRow.spacing = 4; similarRow.alignment = .centerY
        similarRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        let spellCb = makeCheckbox(L("settings.autoCorrectSpell"), #selector(toggleAutoSpell(_:)), on: autoSpell)
        let spellInfo = NSImageView(image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil) ?? NSImage())
        spellInfo.contentTintColor = .secondaryLabelColor
        spellInfo.toolTip = L("settings.autoCorrectSpell.tip")
        let spellRow = NSStackView(views: [spellCb, spellInfo])
        spellRow.orientation = .horizontal; spellRow.spacing = 4; spellRow.alignment = .centerY
        spellRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        let learnedLbl = NSTextField(labelWithString: "")
        let learnedView = NSButton(title: L("settings.learned.view"), target: self, action: #selector(openLearned))
        learnedView.bezelStyle = .rounded; learnedView.controlSize = .small
        let learnedRow = NSStackView(views: [learnedLbl, spacer(), learnedView])
        learnedRow.orientation = .horizontal; learnedRow.spacing = 12; learnedRow.alignment = .centerY
        learnedRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)

        self.autoCb = autoCb; autoExcBtn = excBtn; autoInfo = autoInfoIcon; autoEnterCb = enterCb; autoSimilarCb = similarCb
        autoSpellCb = spellCb
        learnedLabel = learnedLbl; learnedViewBtn = learnedView
        updateAutoAvailability()

        // ── header: logo + name ──
        let logo = NSImageView()
        logo.image = NSApp.applicationIconImage
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.imageAlignment = .alignCenter   // stays centered though the view spans full width
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let name = NSTextField(labelWithString: "reLayout")
        name.font = .boldSystemFont(ofSize: 15)
        name.alignment = .center

        // ── labeled rows: language (section A) + hotkey (section B). Separate grids,
        // but a shared caption-column width keeps "Language:"/"Hotkey:" aligned. ──
        let capW = ceil([L("settings.language"), L("settings.hotkey"), L("settings.autoHotkey")]
                            .map { caption($0).fittingSize.width }.max() ?? 0)
        let langGrid = NSGridView(views: [[caption(L("settings.language")), langPopup]])
        let hkGrid   = NSGridView(views: [[caption(L("settings.hotkey")), hkColumn],
                                          [caption(L("settings.autoHotkey")), autoHkColumn]])
        for g in [langGrid, hkGrid] {
            g.rowSpacing = 10; g.columnSpacing = 10
            g.column(at: 0).xPlacement = .leading
            g.column(at: 0).width = capW
            g.rowAlignment = .none
        }
        langGrid.row(at: 0).yPlacement = .center
        hkGrid.row(at: 0).yPlacement = .center   // caption centered with the field
        hkGrid.row(at: 1).yPlacement = .center

        // ── footer: version + link + copyright ──
        let info = Bundle.main.infoDictionary
        let verStr = (info?["RLVersionFull"] as? String) ?? (info?["CFBundleShortVersionString"] as? String) ?? ""
        let version = makeSecondaryLabel(verStr.isEmpty ? "" : String(format: L("win.version"), verStr).prefix(1).uppercased()
                                         + String(format: L("win.version"), verStr).dropFirst())
        let url = "github.com/\(repoSlug)"
        let link = NSButton(title: url, target: self, action: #selector(openProjectURL))
        link.isBordered = false; link.bezelStyle = .inline; link.alignment = .center
        link.attributedTitle = NSAttributedString(string: url, attributes: [
            .foregroundColor: NSColor.linkColor, .font: NSFont.systemFont(ofSize: 11)])
        link.isHidden = repoSlug.isEmpty   // identity-less build: nothing to point at
        let copyright = makeSecondaryLabel((info?["NSHumanReadableCopyright"] as? String) ?? "")

        func sep() -> NSBox {
            let b = NSBox(); b.boxType = .separator
            b.translatesAutoresizingMaskIntoConstraints = false
            return b
        }
        let sep1 = sep(), sep2 = sep(), sep3 = sep(), sep4 = sep()

        // Section A: login + auto-update + language. Section B: hotkey. Section C: auto-correct.
        var arranged: [NSView] = [logo, name, sep1, cb]
#if SPARKLE
        let autoUpdateCb = makeCheckbox(L("settings.autoUpdate"), #selector(toggleAutoUpdate(_:)),
                                        on: updater?.updater.automaticallyChecksForUpdates ?? true)
        arranged.append(autoUpdateCb)
#endif
        arranged += [langGrid, sep2, hkGrid, sep3, autoRow, enterRow, similarRow, spellRow, learnedRow,
                     sep4, excRow, version, link, copyright]

        let stack = NSStackView(views: arranged)
        stack.orientation = .vertical
        stack.alignment = .leading   // checkbox rows + grid labels flush left
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(14, after: name)   // breathing room around the separators
        stack.setCustomSpacing(14, after: sep1)
        stack.setCustomSpacing(14, after: langGrid)   // before sep2
        stack.setCustomSpacing(14, after: sep2)
        stack.setCustomSpacing(14, after: hkGrid)     // before sep3
        stack.setCustomSpacing(14, after: sep3)
        stack.setCustomSpacing(14, after: learnedRow)   // before sep4
        stack.setCustomSpacing(14, after: sep4)
        stack.setCustomSpacing(20, after: excRow)       // footer
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            // No fixed width: the stack is pinned on both sides, so the content (and
            // window) sizes to the widest control — auto-fit, no empty margin.
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            sep1.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sep2.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // Rows with a right-hand button span the width; their spacers absorb it.
            learnedRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            excRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sep3.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sep4.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hkRow.widthAnchor.constraint(equalTo: langPopup.widthAnchor),   // hotkey field == language popup width
            autoHkRow.widthAnchor.constraint(equalTo: langPopup.widthAnchor),
            // span full width so their centered content stays centered while the
            // stack itself is leading-aligned (checkboxes / grid labels flush left)
            logo.widthAnchor.constraint(equalTo: stack.widthAnchor),
            name.widthAnchor.constraint(equalTo: stack.widthAnchor),
            version.widthAnchor.constraint(equalTo: stack.widthAnchor),
            link.widthAnchor.constraint(equalTo: stack.widthAnchor),
            copyright.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        content.layoutSubtreeIfNeeded()
        w.setContentSize(content.fittingSize)
        w.center()

        settingsWindow = w
        w.initialFirstResponder = nil
        w.animationBehavior = .none   // no zoom-in on open
        activateApp()
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(nil)   // don't leave the first checkbox focused on open
    }

    @objc private func openProjectURL() {
        guard !repoSlug.isEmpty, let u = URL(string: "https://github.com/\(repoSlug)") else { return }
        NSWorkspace.shared.open(u)
    }

    // MARK: - Learned words (the user's hotkey verdicts; see Core hotkeyMisses)

    // Typed form -> its conversion (hotkey overruled a silent auto mode).
    private var learnedConvert: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "autoLearned") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "autoLearned") }
    }
    // Typed forms whose auto-correction the user undid.
    private var learnedKeep: [String] {
        get { UserDefaults.standard.stringArray(forKey: "autoKept") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "autoKept") }
    }
    // Hotkey corrections seen so far for typed forms not yet promoted to `convert`.
    private var learnedCounts: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: "autoLearnCounts") as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "autoLearnCounts") }
    }
    // All four lists as the engine's `LearnedWords`, whose rules change them.
    private var learned: LearnedWords {
        get { LearnedWords(convert: learnedConvert, keep: Set(learnedKeep), counts: learnedCounts,
                           candidates: learnedCandidates) }
        set {
            learnedConvert = newValue.convert; learnedKeep = newValue.keep.sorted()
            learnedCounts = newValue.counts; learnedCandidates = newValue.candidates
        }
    }
    private func learnedVerdict(_ key: String) -> LearnedVerdict? { learned.verdict(key) }
    private func learn(convert misses: [String], replaced: String, out: String) {
        guard !misses.isEmpty else { return }
        let promoted = learned.count(misses: misses, replaced: replaced, out: out)
        dbg("learned: counted \(misses), promoted \(promoted)")
        refreshLearnedUI()
    }
    private func refreshLearnedUI() {
        DispatchQueue.main.async { self.updateAutoAvailability(); if self.learnedWindow?.isVisible == true { self.reloadLearnedRows() } }
    }
    private func unlearn(_ last: Conv) {
        learned.unlearn(learned: last.learned, autoWords: last.autoWords)
        if !last.autoWords.isEmpty { dbg("learned keep: \(last.autoWords)") }
        refreshLearnedUI()
    }

    // Candidates (counted, not yet promoted) keep their conversion for the list.
    private var learnedCandidates: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "autoLearnCandidates") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "autoLearnCandidates") }
    }

    enum LearnedKind { case convert, keep, candidate, new }
    struct LearnedRow { var typed: String; var out: String; let kind: LearnedKind }
    // Rebuilt on reload; the pending "new" row lives only here until committed.
    private var learnedRows: [LearnedRow] = []
    private var learnedNewPending = false
    private weak var learnedMinus: NSButton?
    private weak var excMinus: NSButton?
    private weak var learnedScroll: NSScrollView?

    // Two text columns share the clip width around the fixed checkbox column, and
    // the clip sits at x = 0: autoresizing left the table wider than the box and
    // scrolled sideways.
    private func fitLearnedColumns() {
        guard let t = learnedTable, let s = learnedScroll else { return }
        let text = (s.contentView.bounds.width - 24 - t.intercellSpacing.width * 3) / 2
        for c in t.tableColumns where c.identifier.rawValue != "ok" { c.width = max(text, 40) }
        s.contentView.scroll(to: NSPoint(x: 0, y: s.contentView.bounds.origin.y))
    }

    // A list the way Login Items draws one: the table and a footer with ⊕ / ⊖ in
    // one rounded, bordered box.
    private func listBox(_ scroll: NSScrollView, plus: Selector, minus: Selector) -> (box: NSBox, minus: NSButton) {
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .none
        (scroll.documentView as? NSTableView)?.style = .plain   // full-width rows, no inset pills
        func glyph(_ title: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.isBordered = false
            b.font = .systemFont(ofSize: 16, weight: .regular)   // "+" and "−" at one size
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 22).isActive = true
            return b
        }
        let plusBtn = glyph("+", plus), minusBtn = glyph("\u{2212}", minus)
        minusBtn.isEnabled = false
        let divider = NSBox(); divider.boxType = .separator; divider.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox(); line.boxType = .separator; line.translatesAutoresizingMaskIntoConstraints = false
        let box = NSBox()
        box.boxType = .custom; box.titlePosition = .noTitle
        box.borderColor = .separatorColor; box.borderWidth = 1; box.cornerRadius = 5
        box.contentViewMargins = .zero
        box.translatesAutoresizingMaskIntoConstraints = false
        guard let c = box.contentView else { return (box, minusBtn) }
        for v in [scroll, line, plusBtn, divider, minusBtn] { c.addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: c.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: c.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: c.trailingAnchor),
            line.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: c.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: c.trailingAnchor),
            plusBtn.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 1),
            plusBtn.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
            plusBtn.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -1),
            plusBtn.heightAnchor.constraint(equalToConstant: 20),
            divider.leadingAnchor.constraint(equalTo: plusBtn.trailingAnchor),
            divider.centerYAnchor.constraint(equalTo: plusBtn.centerYAnchor),
            divider.heightAnchor.constraint(equalToConstant: 14),
            minusBtn.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            minusBtn.centerYAnchor.constraint(equalTo: plusBtn.centerYAnchor),
        ])
        return (box, minusBtn)
    }

    private func reloadLearnedRows() {
        learnedRows = learnedConvert.map { LearnedRow(typed: $0.key, out: $0.value, kind: .convert) }.sorted { $0.typed < $1.typed }
            + learnedKeep.map { LearnedRow(typed: $0, out: "", kind: .keep) }
            + learnedCandidates.map { LearnedRow(typed: $0.key, out: $0.value, kind: .candidate) }.sorted { $0.typed < $1.typed }
        if learnedNewPending { learnedRows.append(LearnedRow(typed: "", out: "", kind: .new)) }
        learnedTable?.reloadData()
        fitLearnedColumns()
        learnedMinus?.isEnabled = !(learnedTable?.selectedRowIndexes.isEmpty ?? true)
    }

    @objc private func openLearned() {
        guard let parent = settingsWindow else { return }
        let w = learnedWindow ?? buildLearnedWindow()
        reloadLearnedRows()
        present(w, over: parent)
    }

    @objc private func learnedDone() {
        learnedWindow?.close()
        updateAutoAvailability()
    }

    // The ⊕ / ⊖ pair, like Login Items: ⊕ opens an empty editable row, ⊖ drops
    // the selected rows (any kind).
    @objc private func learnedPlus() {
        guard let t = learnedTable, !learnedNewPending else { return }
        learnedNewPending = true
        reloadLearnedRows()
        let row = learnedRows.count - 1
        t.scrollRowToVisible(row)
        t.editColumn(0, row: row, with: nil, select: true)
    }

    @objc private func learnedMinusAction() {
        guard let t = learnedTable else { return }
        var l = learned
        for i in t.selectedRowIndexes {
            let r = learnedRows[i]
            if r.kind == .new { learnedNewPending = false } else { l.forget([r.typed]) }
        }
        learned = l
        reloadLearnedRows()
        updateAutoAvailability()
    }

    // The checkbox column: checked = the verdict is in force. Checking a
    // candidate promotes it; unchecking a convert demotes it to a candidate;
    // unchecking a keep drops it.
    @objc private func learnedToggle(_ sender: NSButton) {
        guard learnedRows.indices.contains(sender.tag) else { return }
        let r = learnedRows[sender.tag]
        switch r.kind {
        case .candidate: learned.promote(r.typed, to: r.out)   // an empty conversion marks a keep candidate
        case .convert, .keep: learned.demote(r.typed)
        case .new: break
        }
        reloadLearnedRows()
        updateAutoAvailability()
    }

    // Candidates only: counts and their conversions. Confirmed like the reset.
    @objc private func cleanLearnedCandidates() {
        let a = NSAlert()
        a.messageText = String(format: L("settings.learned.cleanConfirm"), String(learnedCandidates.count))
        a.informativeText = L("settings.learned.cleanInfo")
        a.addButton(withTitle: L("settings.learned.clean"))
        a.addButton(withTitle: L("settings.learned.cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        learned.cleanCandidates()
        reloadLearnedRows()
    }

    // Irreversible user data: confirmed first.
    @objc private func resetLearned() {
        let n = learnedConvert.count + learnedKeep.count
        let a = NSAlert()
        a.messageText = String(format: L("settings.learned.confirm"), String(n))
        a.informativeText = L("settings.learned.confirmInfo")
        a.addButton(withTitle: L("settings.learned.reset"))
        a.addButton(withTitle: L("settings.learned.cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        learned = LearnedWords()
        learnedNewPending = false
        reloadLearnedRows()
        updateAutoAvailability()
    }

    private func learnedCell(_ table: NSTableView, column: NSTableColumn?, row: Int) -> NSView? {
        guard learnedRows.indices.contains(row) else { return nil }
        let r = learnedRows[row]
        if column?.identifier.rawValue == "ok" {
            let id = NSUserInterfaceItemIdentifier("learned-ok")
            let box = (table.makeView(withIdentifier: id, owner: self) as? NSButton)
                ?? NSButton(checkboxWithTitle: "", target: self, action: #selector(learnedToggle(_:)))
            box.identifier = id
            box.contentTintColor = .systemGreen
            box.tag = row
            box.state = (r.kind == .convert || r.kind == .keep) ? .on : .off
            box.isHidden = r.kind == .new
            return box
        }
        let isTyped = column?.identifier.rawValue == "typed"
        let id = NSUserInterfaceItemIdentifier("learned-text")
        let cell = (table.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? NSTextField(labelWithString: "")
        cell.identifier = id
        cell.stringValue = isTyped ? r.typed : (r.out.isEmpty && r.kind != .new ? L("settings.learned.keep") : r.out)
        cell.isEditable = r.kind == .new
        cell.isBordered = false
        cell.drawsBackground = false
        // The empty "Becomes" of a new row means "keep as typed": its placeholder says so.
        cell.placeholderString = r.kind == .new ? (isTyped ? L("settings.learned.col.typed") : L("settings.learned.keep")) : nil
        cell.delegate = self
        cell.tag = isTyped ? 0 : 1
        return cell
    }

    // The new row: typing in "Typed" then "Becomes" and leaving the field commits
    // it as a convert verdict; an empty "Typed" when editing ends drops the row.
    func controlTextDidEndEditing(_ note: Notification) {
        guard learnedNewPending, let field = note.object as? NSTextField, let t = learnedTable,
              let row = learnedRows.firstIndex(where: { $0.kind == .new }) else { return }
        if field.tag == 0 { learnedRows[row].typed = learnedKey(field.stringValue) }
        else { learnedRows[row].out = learnedKey(field.stringValue) }
        let r = learnedRows[row]
        let movement = note.userInfo?["NSTextMovement"] as? Int
        // Esc, or nothing typed: the row goes away.
        if movement == NSTextMovement.cancel.rawValue || r.typed.isEmpty {
            learnedNewPending = false; reloadLearnedRows(); return
        }
        // Tab out of "Typed" goes on to "Becomes".
        if field.tag == 0, movement == NSTextMovement.tab.rawValue { t.editColumn(1, row: row, with: nil, select: true); return }
        // Committed: a conversion, or with "Becomes" empty, keep the word as typed.
        learned.promote(r.typed, to: r.out)
        learnedNewPending = false
        reloadLearnedRows()
        updateAutoAvailability()
    }

    func tableViewSelectionDidChange(_ note: Notification) {
        guard let t = note.object as? NSTableView else { return }
        let minus = t === learnedTable ? learnedMinus : t === excTable ? excMinus : nil
        minus?.isEnabled = !t.selectedRowIndexes.isEmpty
    }

    private func buildLearnedWindow() -> NSWindow {
        let w = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 320),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = L("settings.learned.title")
        w.isReleasedWhenClosed = false
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        w.contentView = content

        let hint = NSTextField(wrappingLabelWithString: L("settings.learned.hint"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        let table = NSTableView()
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true   // Cmd / Shift / Option as everywhere on macOS
        // The two text columns share the width, the checkbox column is fixed: the
        // table never outgrows the box, so no horizontal scrolling.
        table.columnAutoresizingStyle = .noColumnAutoresizing   // fitLearnedColumns sizes them
        for (id, width) in [("typed", 160), ("out", 160), ("ok", 24)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = id == "ok" ? "" : L("settings.learned.col.\(id)")
            col.width = CGFloat(width)
            col.resizingMask = id == "ok" ? [] : .autoresizingMask
            if id == "ok" { col.minWidth = 24; col.maxWidth = 24 }
            table.addTableColumn(col)
        }
        table.dataSource = self
        table.delegate = self
        learnedTable = table
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        learnedScroll = scroll

        let (box, minus) = listBox(scroll, plus: #selector(learnedPlus), minus: #selector(learnedMinusAction))
        learnedMinus = minus
        // Columns are sized to the clip whenever it changes (window open, resize).
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView,
                                               queue: .main) { [weak self] _ in self?.fitLearnedColumns() }

        func btn(_ key: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: L(key), target: self, action: sel)
            b.bezelStyle = .rounded; b.controlSize = .small
            b.translatesAutoresizingMaskIntoConstraints = false
            return b
        }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [btn("settings.learned.clean", #selector(cleanLearnedCandidates)),
                                      btn("settings.learned.reset", #selector(resetLearned)),
                                      spacer,
                                      btn("settings.exc.done", #selector(learnedDone))])
        bar.orientation = .horizontal; bar.spacing = 8; bar.distribution = .fill
        bar.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(hint); content.addSubview(box); content.addSubview(bar)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 400),
            hint.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            box.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8),
            box.leadingAnchor.constraint(equalTo: hint.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: hint.trailingAnchor),
            box.heightAnchor.constraint(equalToConstant: 224),
            bar.topAnchor.constraint(equalTo: box.bottomAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: hint.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: hint.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        learnedWindow = w
        return w
    }

    // MARK: - Auto-correct exceptions (per-app deny-list editor)

    // Presented as a sheet on Settings → modal to it: the user can't refocus Settings
    // until the sheet is dismissed.
    @objc private func openExceptions() {
        guard let parent = settingsWindow else { return }
        let w = excWindow ?? buildExceptionsWindow()
        reloadExceptionRows()
        present(w, over: parent)
    }

    // A window of its own, centered over Settings: a sheet has no close button.
    private func present(_ w: NSWindow, over parent: NSWindow) {
        // Only the close button: the other two are drawn disabled otherwise.
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        if !w.isVisible {
            let p = parent.frame, f = w.frame
            w.setFrameOrigin(NSPoint(x: p.midX - f.width / 2, y: p.midY - f.height / 2))
        }
        w.makeKeyAndOrderFront(nil)
    }

    @objc private func excDone() {
        excWindow?.close()
    }

    private func buildExceptionsWindow() -> NSWindow {
        let w = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = L("settings.exc.title")
        w.isReleasedWhenClosed = false
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        w.contentView = content

        // Why a fresh install already lists apps (terminals, editors, VMs).
        let info = NSImageView(image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil) ?? NSImage())
        info.contentTintColor = .secondaryLabelColor
        info.toolTip = L("settings.exc.info")
        info.translatesAutoresizingMaskIntoConstraints = false
        // What the list does, under its name.
        let hint = NSTextField(labelWithString: L("settings.exc.hint"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        let table = NSTableView()
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        col.title = ""
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        // Ticked = that feature works in the app.
        for (id, key) in [("auto", "settings.exc.auto"), ("hotkey", "settings.exc.hotkey")] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = L(key)
            c.headerToolTip = L(key + ".tip")
            c.headerCell.alignment = .center
            c.width = max(70, (L(key) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width + 20)
            c.resizingMask = []
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        excTable = table
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        func btn(_ key: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: L(key), target: self, action: sel)
            b.bezelStyle = .rounded; b.controlSize = .small
            b.translatesAutoresizingMaskIntoConstraints = false
            return b
        }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        // ⊕ is "Choose…", ⊖ removes the selection; "Exclude current app" stays a button.
        let (box, minus) = listBox(scroll, plus: #selector(excChoose), minus: #selector(excMinusAction))
        excMinus = minus
        let bar = NSStackView(views: [btn("settings.exc.addCurrent", #selector(excAddCurrent)),
                                      spacer,
                                      btn("settings.exc.done", #selector(excDone))])
        bar.orientation = .horizontal; bar.spacing = 8; bar.distribution = .fill
        bar.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(info); content.addSubview(hint)
        content.addSubview(box); content.addSubview(bar)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 440),
            hint.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            info.leadingAnchor.constraint(equalTo: hint.trailingAnchor, constant: 4),
            info.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            box.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            box.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            box.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            box.heightAnchor.constraint(equalToConstant: 224),
            bar.topAnchor.constraint(equalTo: box.bottomAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        excWindow = w
        return w
    }

    @objc private func excAddCurrent() {
        guard let b = lastActiveBundleID else { NSSound.beep(); return }
        addExcluded(b)
    }

    // The table's rows: apps with either flag. A row whose flags are both cleared stays
    // until the list is rebuilt (reopened, an app added or removed).
    private var excRows: [String] = []
    private func reloadExceptionRows() {
        excRows = exceptions.rows
        excTable?.reloadData()
    }

    @objc private func excMinusAction() {
        guard let t = excTable else { return }
        exceptions.remove(Set(t.selectedRowIndexes.map { excRows[$0] }))
        reloadExceptionRows()
        excMinus?.isEnabled = false
    }

    @objc private func excToggleFlag(_ sender: NSButton) {
        guard excRows.indices.contains(sender.tag) else { return }
        let bid = excRows[sender.tag], on = sender.state == .on
        if sender.identifier?.rawValue == "hotkey" { exceptions.setHotkey(bid, off: !on) }
        else { exceptions.setAuto(bid, off: !on) }
    }

    @objc private func excChoose() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        guard p.runModal() == .OK else { return }
        for url in p.urls { if let b = Bundle(url: url)?.bundleIdentifier { addExcluded(b) } }
    }


    private func addExcluded(_ bid: String) {
        exceptions.add(bid)
        reloadExceptionRows()
    }

    // Resolve a bundle id to a display name + icon (generic fallback if not installed).
    private func appInfo(_ bid: String) -> (name: String, icon: NSImage) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            let name = FileManager.default.displayName(atPath: url.path)
            return (name.hasSuffix(".app") ? String(name.dropLast(4)) : name,
                    NSWorkspace.shared.icon(forFile: url.path))
        }
        let fallback = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        return (bid, fallback)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === learnedTable ? learnedRows.count : excRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === learnedTable { return learnedCell(tableView, column: tableColumn, row: row) }
        let bid = excRows[row]
        if let flag = tableColumn?.identifier.rawValue, flag != "app" {
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(excToggleFlag(_:)))
            box.identifier = NSUserInterfaceItemIdentifier(flag)
            box.tag = row
            box.state = (flag == "hotkey" ? exceptions.hotkeyOff(bid) : exceptions.autoOff(bid)) ? .off : .on
            box.toolTip = L("settings.exc.\(flag).tip")
            let cell = NSView()
            box.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(box)
            NSLayoutConstraint.activate([box.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                                         box.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        let info = appInfo(bid)
        let id = NSUserInterfaceItemIdentifier("exc")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? ExcRowView) ?? ExcRowView(frame: .zero)
        cell.identifier = id
        cell.configure(name: info.name, icon: info.icon)
        return cell
    }

    @objc private func toggleLogin() {
        setLogin(loginCheckbox?.state == .on)
        loginCheckbox?.state = loginEnabled() ? .on : .off   // reflect real state
    }


    // Language picker changed: tag 0 = follow system, else Loc.languages[tag-1].
    // Re-localize live by rebuilding the menu and recreating the Settings window.
    @objc private func changeLanguage(_ sender: NSPopUpButton) {
        let tag = sender.selectedTag()
        Loc.apply(tag == 0 ? nil : Loc.languages[tag - 1].code)
        setupMenu()
        if let w = settingsWindow { settingsWindow = nil; w.close() }
        excWindow = nil; learnedWindow = nil   // cached sheets carry the old language
        DispatchQueue.main.async { self.openReLayoutSettings() }
    }

    private func loginEnabled() -> Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    private func setLogin(_ on: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
        } catch {
            dbg("login toggle error: \(error)")
            let a = NSAlert()
            a.messageText = L("alert.loginItem.title")
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }

    // MARK: retype

    private func waitModifiersReleased() {
        for _ in 0..<60 {
            let f = CGEventSource.flagsState(.combinedSessionState)
            if !f.contains(.maskCommand), !f.contains(.maskControl),
               !f.contains(.maskShift), !f.contains(.maskAlternate) { return }
            usleep(pollInterval)
        }
    }

    // Marker stamped on our synthesized events so the auto-mode key monitor can
    // ignore them (else our own corrections would feed back into the buffer).
    static let synthMarker: Int64 = 0x52_4C_41_59   // "RLAY"
    private func markSynth(_ e: CGEvent?) { e?.setIntegerValueField(.eventSourceUserData, value: Self.synthMarker) }

    private func postKey(_ keyCode: CGKeyCode, _ flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        markSynth(down); markSynth(up)
        // Same injection point as typeUnicode: events posted at .cghidEventTap
        // enter the chain upstream of the session tap, so a delete posted before a
        // character could still be delivered after it. One queue = FIFO.
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    // Electron/Chromium (VS Code) can apply a burst of deletes after text posted
    // right behind it, leaving the old word half-erased; pace them and let them land.
    private func eraseBack(_ n: Int) {
        for _ in 0..<n { postKey(CGKeyCode(kVK_Delete), []); usleep(keyGap) }
        usleep(30_000)
    }

    // Which layouts the selection converts between is the engine's call
    // (planRetype in Core/Auto.swift), shared with the Windows port.
    // With auto mode on, the words it would have left alone are learned (engine
    // `hotkeyMisses`); `learned` lists them so the undo can forget them again.
    private func convert(_ text: String) -> (out: String, dst: Layout, src: Layout, learned: [String],
                                             alternatives: [(out: String, dst: Layout)])? {
        let enabled = Layout.enabledList()
        let curID = currentSourceID()
        guard let curIdx = enabled.firstIndex(where: { $0.id == curID }) else { return nil }
        let plan = planRetype(text, enabled: enabled, curIdx: curIdx, model: trigram)
        dbg("convert cur=\(curID) -> \(plan.map { "\($0.src.id) -> \($0.dst.id)" } ?? "nothing")")
        guard let p = plan else { return nil }
        var misses: [String] = []
        // Same gate as auto mode: nothing typed into a password field or an
        // excluded app is ever persisted.
        if autoMode, !isAutoExcluded() {
            misses = hotkeyMisses(replaced: text, out: p.out, src: p.src, dst: p.dst, enabled: enabled, model: trigram)
            learn(convert: misses, replaced: text, out: p.out)
        }
        let alts = enabled.firstIndex(where: { $0.id == p.src.id }).map {
            retypeAlternatives(text, enabled: enabled, srcIdx: $0, first: p.out, model: trigram)
        } ?? []
        return (p.out, p.dst, p.src, misses, alts)
    }

    // MARK: - auto-mode (trigram detection)

    private var trigramCache: [String: TrigramModel?] = [:]
    private func trigram(_ lang: String) -> TrigramModel? {
        if let c = trigramCache[lang] { return c }
        let m = Bundle.main.url(forResource: lang, withExtension: "txt", subdirectory: "trigram")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .flatMap { TrigramModel(text: $0) }
        trigramCache[lang] = m
        return m
    }

    // Cross-script trigram decision lives in the engine (Core/Auto.swift); this
    // only feeds it the cached models.
    /// - Returns: the decision; `repaired` = a typo in the conversion was fixed too.
    /// - Parameter verdict: the user's verdicts; the stored ones when nil.
    func autoDecide(_ w: String, cur: Layout, enabled: [Layout], verdict: ((String) -> LearnedVerdict?)? = nil)
        -> (target: Layout, out: String, ambiguous: Bool, repaired: Bool)? {
        let r = autoDecision(w, cur: cur, enabled: enabled, model: trigram, learned: verdict ?? learnedVerdict,
                             sameScript: autoSameScript, spell: autoSpell ? (isWord, { self.spellGuesses($0, $1) }) : nil)
        if r?.repaired == true { dbg("typo: \(w.debugDescription) -> \(r!.out.debugDescription)") }
        return r
    }

    private func spellGuesses(_ w: String, _ lang: String) -> [String] {
        guard let id = spellLanguages[lang] else { return [] }
        let t = uptimeMs()
        defer { spellTime.guesses += 1; spellTime.guessMs += uptimeMs() - t }
        return NSSpellChecker.shared.guesses(forWordRange: NSRange(location: 0, length: (w as NSString).length),
                                             in: w, language: id, inSpellDocumentWithTag: 0) ?? []
    }
    // Trace only: spell calls of the current decision, reset per word.
    private var spellTime = (checks: 0, checkMs: 0.0, guesses: 0, guessMs: 0.0)

    // Layout language code -> the spell checker's identifier for it ("pt" -> "pt_BR"
    // when there is no bare "pt"); an exact match wins.
    private lazy var spellLanguages: [String: String] = {
        var m: [String: String] = [:]
        for id in NSSpellChecker.shared.availableLanguages {
            let code = String(id.prefix(2))
            if m[code] == nil || id == code { m[code] = id }
        }
        return m
    }()
    // shortcut: synchronous call on the main thread (the tap's run loop) — median
    // 0.5 ms, 1 in 100 takes 50–100 ms; add a timeout with a trigram fallback if
    // that stall is felt.
    private func isWord(_ w: String, _ lang: String) -> Bool? {
        guard let id = spellLanguages[lang] else { return nil }
        let t = uptimeMs()
        defer { spellTime.checks += 1; spellTime.checkMs += uptimeMs() - t }
        return NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0, language: id, wrap: false,
                                                   inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }


    // MARK: - auto-mode live monitor

    var autoMode: Bool {
        get { UserDefaults.standard.bool(forKey: "autoMode") }
        set { UserDefaults.standard.set(newValue, forKey: "autoMode"); applyAutoMode(); updateStatusIcon() }
    }
    fileprivate var autoTap: CFMachPort?
    private var autoTapSource: CFRunLoopSource?
    // The typed-word run (word, trail, previous word) lives in the engine: the same
    // state machine drives the Windows port, and its rules are tested there.
    fileprivate var autoRun = AutoRun()
    fileprivate var edits = EditLearning<Layout>()

    // Fast typing races the retype: the deletes + retype of a finished word land
    // in the middle of the characters typed since, producing mixed text and bogus
    // conversions. While a correction is in flight the tap (a .defaultTap for auto
    // mode) SWALLOWS the character keys and the worker replays them afterwards, in
    // order — so the retype always sees exactly the text it measured.
    // Main-thread-only state: the tap callback runs on the main run loop and the
    // worker hands completion back with DispatchQueue.main.async.
    fileprivate var autoPending = 0     // retypes in flight (auto-correct or hotkey)
    // Keys swallowed while retyping (engine `KeyGate`): what they typed, Shift/Option, and the layout then.
    fileprivate var gate = KeyGate<(s: String, flags: CGEventFlags, layout: String)>()
    fileprivate var dbgLastCode: Int64 = -1
    // A retype that hangs (unresponsive app, AX call stuck) must never freeze the
    // keyboard: past this the gate passes keys through even while in flight.


    // Apps where auto-correct stays off — a user-editable deny-list (Settings >
    // Auto-correct > Exceptions…). Seeded once with common terminals/IDEs.
    // Virtual machines and remote desktops are in it too: typing there goes to
    // another system with its own layout, which the Mac can't see, and a correction
    // is forwarded as raw key codes — a Unicode event's key code 0 is kVK_ANSI_A, so
    // UTM typed "aaaa" in a Windows guest.
    private static let defaultExcludedApps: [String] = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.microsoft.VSCode",
        "com.apple.dt.Xcode", "com.sublimetext.4", "org.alacritty",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm",
        "com.utmapp.UTM", "com.parallels.desktop.console", "com.vmware.fusion",
        "org.virtualbox.app.VirtualBoxVM", "com.microsoft.rdc.macos",
        "com.figma.Desktop",
    ]
    // Apps where the retype hotkey does nothing (#1). In one listed in both, the key
    // tap reads no key at all.
    private static let defaultHotkeyExcludedApps: [String] = ["com.figma.Desktop"]
    var hotkeyExcludedApps: [String] {
        get { UserDefaults.standard.array(forKey: "hotkeyExcludedApps") as? [String]
                ?? AppController.defaultHotkeyExcludedApps }
        set { UserDefaults.standard.set(newValue, forKey: "hotkeyExcludedApps") }
    }
    // Both stored lists as the engine's rules (rows, flags, keys off).
    var exceptions: AppExceptions {
        get { AppExceptions(auto: autoExcludedApps, hotkey: hotkeyExcludedApps) }
        set { autoExcludedApps = newValue.auto; hotkeyExcludedApps = newValue.hotkey }
    }
    private func isHotkeyExcluded() -> Bool {
        guard let bid = frontBundleID, bid != Bundle.main.bundleIdentifier else { return false }
        return exceptions.hotkeyOff(bid)
    }
    fileprivate func isKeyReadingOff() -> Bool {
        guard let bid = frontBundleID, bid != Bundle.main.bundleIdentifier else { return false }
        return exceptions.keysOff(bid)
    }
    // The defaults before the "seen" record existed — what a list saved back then
    // already reflects (entries removed from it stay removed).
    private static let firstDefaultExcludedApps: [String] = Array(defaultExcludedApps.prefix(8))

    /// Adds defaults introduced since the user's lists were saved, once each, so a new
    /// default reaches existing users while one they removed never comes back.
    private func mergeNewDefaultExclusions() {
        // The hotkey list shipped with its current defaults: all of them count as seen.
        for (list, seenKey, defaults, first) in [
            ("autoExcludedApps", "autoExcludedDefaultsSeen", AppController.defaultExcludedApps, AppController.firstDefaultExcludedApps),
            ("hotkeyExcludedApps", "hotkeyExcludedDefaultsSeen", AppController.defaultHotkeyExcludedApps, AppController.defaultHotkeyExcludedApps),
        ] {
            let d = UserDefaults.standard
            let seen = Set(d.stringArray(forKey: seenKey) ?? first)
            d.set(defaults, forKey: seenKey)
            guard let saved = d.array(forKey: list) as? [String] else { continue }   // defaults apply as-is
            d.set(mergeExclusions(saved: saved, defaults: defaults, seen: seen), forKey: list)
        }
    }
    var autoExcludedApps: [String] {
        get { UserDefaults.standard.array(forKey: "autoExcludedApps") as? [String]
                ?? AppController.defaultExcludedApps }
        set { UserDefaults.standard.set(newValue, forKey: "autoExcludedApps") }
    }

    // The keystroke gate (autoPending/gate) lives in this tap, and the hotkey
    // retype needs it as much as auto-correct does — so the tap is installed
    // whenever the app is live, and `autoMode` only decides whether keys are also
    // fed to the word buffer.
    func applyAutoMode() { recordingHotkey ? stopAutoMonitor() : startAutoMonitor() }

    private func startAutoMonitor() {
        guard autoTap == nil else { return }
        let mask = [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            .reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
        let cb: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<AppController>.fromOpaque(refcon).takeUnretainedValue()
            // Both auto-correct and the hotkey off in this app: no key is read, buffered or held. Not while a correction
            // is in flight — its gate still owns the keys typed meanwhile.
            // Where the keys go may change on a click, a Cmd/Ctrl shortcut (Cmd+Space opens
            // Spotlight) or Return/Esc/Tab (it closes): ask then, not on every key.
            if type != .keyDown || event.flags.contains(.maskCommand) || event.flags.contains(.maskControl)
                || [36, 48, 53].contains(event.getIntegerValueField(.keyboardEventKeycode)) {
                me.refreshKeyApp()
                // The panel opens or closes after the key: look again once it has.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { me.refreshKeyApp() }
            }
            if me.autoPending == 0, type != .tapDisabledByTimeout, type != .tapDisabledByUserInput,
               me.isKeyReadingOff() {
                me.autoRun.reset(); me.endUndoWindow()
                return Unmanaged.passUnretained(event)
            }
            let synth = event.getIntegerValueField(.eventSourceUserData) == AppController.synthMarker
            let tapCode = event.getIntegerValueField(.keyboardEventKeycode)
            dbg("tap type=\(type.rawValue) code=\(dbgKeyNames.contains(Int(tapCode)) ? String(tapCode) : "·") "
                + "same=\(type == .keyDown && tapCode == me.dbgLastCode) "
                + "flags=\(String(event.flags.rawValue, radix: 16)) synth=\(synth) "
                + "pid=\(event.getIntegerValueField(.eventSourceUnixProcessID))")
            if type == .keyDown, !synth { me.dbgLastCode = tapCode }
            // Our own combo hotkeys are not typing: they neither end the word run
            // (the retype hotkey converts it) nor reach the buffer.
            if type == .keyDown, !synth,
               [me.hotkey, me.autoHotkey].contains(where: { $0?.isCombo(code: tapCode, flags: event.flags) == true }) {
                return Unmanaged.passUnretained(event)
            }
            // A click may move the caret or focus, and a Cmd/Ctrl shortcut may too
            // (paste, undo, Cmd+arrows, send, app switch): the buffered word and a
            // pending preposition no longer sit right before the caret, and a later
            // correction would delete someone else's text.
            if type != .keyDown || (!synth && (event.flags.contains(.maskCommand) || event.flags.contains(.maskControl))) {
                me.autoRun.reset()
            }
            // A click also ends the undo window: undo erases back from the caret, which
            // is no longer right after the text the conversion typed.
            if type != .keyDown { me.endUndoWindow() }
            // Anything that may delete or select text arms learning by revert (engine rule).
            if !synth, mayEditText(keyRole(type, event)) { me.edits.edit() }
            if type == .keyDown, !synth,
               event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Delete) {
                // Backspace (bare, or Option/Cmd-wide) edits the word being typed —
                // handled before the Cmd/Ctrl filter below, which would otherwise let
                // Cmd+Delete leave a buffer that no longer matches the screen.
                let wide = event.flags.contains(.maskAlternate) || event.flags.contains(.maskCommand)
                return me.autoBackspace(wide: wide) ? nil : Unmanaged.passUnretained(event)
            }
            if type == .keyDown, !synth,
               !event.flags.contains(.maskCommand), !event.flags.contains(.maskControl) {
                // Skip shortcuts/combo-hotkeys (Cmd/Ctrl held): not text, and the
                // combo-hotkey's own key must not clear a pending auto-fix undo.
                var len = 0
                var buf = [UniChar](repeating: 0, count: 4)
                event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &buf)
                let s = me.layoutChar(event) ?? String(utf16CodeUnits: buf, count: len)
                // Right after a Globe switch, TextInputSwitcher re-posts the first key it
                // held while its HUD had the keyboard (HISTORY, after v1.3.8). The tap
                // sees that key twice; the app types it once. Counting it twice made the
                // fix erase one character too many ("после гтвщ" -> "послеuundo", the
                // space gone). The re-post carries the switcher's pid: let it through
                // to the app, but do not feed it again.
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                let now = ProcessInfo.processInfo.systemUptime
                if code == me.lastFedKey.code, now - me.lastFedKey.time < 0.3,
                   me.isInputSwitcherEvent(event) {
                    dbg("globe double: \(s.debugDescription) from TextInputSwitcher, not fed")
                    return Unmanaged.passUnretained(event)
                }
                // A re-post that lands after other keys: its first sighting sits earlier
                // in the buffer than on screen, so a fix would erase the wrong span.
                if me.isInputSwitcherEvent(event) {
#if DEBUG
                    let i = me.dbgRecentFed.lastIndex { $0.code == code }
                    dbg("switcher repost, fed: matches #\(i.map { me.dbgRecentFed.count - $0 }.map(String.init) ?? "none") "
                        + "(1 = last of \(me.dbgRecentFed.count)), last \(Int((now - me.lastFedKey.time) * 1000))ms ago; word dropped")
#endif
                    me.autoRun.reset()
                    return Unmanaged.passUnretained(event)
                }
#if DEBUG
                me.dbgRecentFed = (me.dbgRecentFed + [(code, now)]).suffix(4)
#endif
                me.lastFedKey = (code, now)
                // Only text-producing keys are held back; modifiers, Globe, arrows
                // and delete keep flowing so nothing the user does can be stalled
                // by a correction that hangs.
                if me.autoPending > 0, !s.isEmpty {
                    let key = (s: s, flags: event.flags.intersection([.maskShift, .maskAlternate]), layout: me.currentSourceID())
                    switch me.gate.key(key, at: ProcessInfo.processInfo.systemUptime) {
                    case .pass: break
                    case .hold:
                        dbg("hold \(s.debugDescription) held=\(me.gate.held.count)")
                        return nil
                    case .release(let keys):
                        // The correction is stuck: the held keys and this one go out now,
                        // in order, posted from here — the worker is still busy with it.
                        dbg("gate: stuck correction, releasing \(keys.count)")
                        me.autoRun.reset(); me.endUndoWindow()
                        for k in keys { me.typeKey(k.s, flags: k.flags) }
                        return nil
                    }
                }
                // The boundary key that starts a correction is swallowed too: it
                // would otherwise travel to the app in parallel with the deletes we
                // are already posting, and land inside them.
                if me.autoFeed(s, flags: event.flags.intersection([.maskShift, .maskAlternate])) { return nil }
            } else if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = me.autoTap { CGEvent.tapEnable(tap: t, enable: true) }
            }
            return Unmanaged.passUnretained(event)
        }
        // .defaultTap (not .listenOnly): the callback must be able to drop the
        // user's keystrokes while a correction is being typed back.
        guard let (tap, src) = installEventTap(mask, cb, options: .defaultTap) else { return }
        autoTap = tap; autoTapSource = src
    }

    private func stopAutoMonitor() {
        removeEventTap(&autoTap, &autoTapSource)
        // autoPending is left alone: a correction in flight still ends in
        // finishCorrection, which counts it down (zeroed here, it went to -1).
        autoRun.reset(); gate.open()
    }

    // Backspace edits the word being typed, so the buffer has to follow it: drop
    // the last character instead of ending the run. Losing the buffer here made a
    // typo-fix mid-word convert only the part typed after it ("g\\" + fix + "æcf"
    // corrected "æcf" alone), and keeping the deleted character would have made the
    // retype delete one character too many. Option/Cmd+Delete removes a word or the
    // whole line — nothing left to track, so the run ends.
    // Never held by the gate: while keystrokes are held, backspace un-types the
    // last held one instead of reaching the app out of order.
    // Returns true when the keystroke was consumed (it un-typed a held character
    // instead of reaching the app).
    fileprivate func autoBackspace(wide: Bool) -> Bool {
        dbg("bksp wide=\(wide) held=\(gate.held.count) buf=\(autoRun.word.debugDescription)")
        if gate.backspace(wide: wide) { return true }
        autoRun.backspace(wide: wide)
        return false
    }

    // Feed a produced character into the word buffer; evaluate on a word boundary.
    // Returns true when the keystroke started a correction and must NOT be
    // delivered to the app — `autoCorrect` retypes it after the fix.
    // `flags` (Shift/Option) travel with a swallowed boundary so it is re-posted as
    // the same key: Shift+Return stays a newline instead of becoming "send".
    @discardableResult
    fileprivate func autoFeed(_ s: String, flags: CGEventFlags = []) -> Bool {
        // Any real keystroke after an (auto or hotkey) conversion ends its undo
        // window — the caret has moved on, so a later hotkey press should CONVERT
        // the new word, not revert the old fix. The undo hotkey itself is a
        // modifier/Cmd-combo (filtered above), so it never reaches here.
        endUndoWindow()
        dbg("feed \(s.debugDescription) buf=\(autoRun.word.debugDescription) "
            + "app=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")
        let event = autoRun.feed(s, mapsToCyrillic: { self.feedsAsCyr(String($0)) })
        guard autoMode else { return false }   // the buffer still serves the hotkey
        switch event {
        case .none:
            return false
        case .enter(let word, let trail):
            // Return may submit (launcher query, chat send), so it is never swallowed
            // and nothing is converted before it. `autoEnterFollowUp` looks at what
            // the app did and fixes the word only if Return inserted a line break.
            autoEnterFollowUp(word: word, trail: trail, flags: flags)
            return false
        case .boundary(let word, let trail):
            return autoEvaluate(word: word, trail: trail, boundary: s, flags: flags)
        }
    }

    private var autoEnterNewline: Bool { UserDefaults.standard.object(forKey: "autoEnterNewline") as? Bool ?? true }
    // Experimental: ru <-> uk conversion (see decideAutoTarget sameScript). Default off.
    private var autoSameScript: Bool { UserDefaults.standard.bool(forKey: "autoSameScript") }
    // Spell-check option: the system dictionary refines layout decisions
    // (see spellCheckedTarget). Default off.
    private var autoSpell: Bool { UserDefaults.standard.bool(forKey: "autoSpell") }
    @objc private func toggleAutoSpell(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "autoSpell")
    }
    private func hasSpellDictionary(_ enabled: [Layout]) -> Bool {
        enabled.contains { $0.languageCode.flatMap { spellLanguages[$0] } != nil }
    }
    @objc private func toggleAutoSimilar(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "autoSameScript")
    }

    // Main thread, from the tap, before the Return reaches the app. Only a long word
    // (no preposition adjacency across a line) in a field whose caret and text are
    // readable is followed up; everything else keeps plain Return behaviour.
    private func autoEnterFollowUp(word: String, trail: String, flags: CGEventFlags) {
        guard autoEnterNewline, !isAutoExcluded() else { return }
        let enabled = Layout.enabledList()
        guard let cur = enabled.first(where: { $0.id == currentSourceID() }),
              let plan = enterFixPlan(word: word, trail: trail, cur: cur,
                                      decide: { self.autoDecide($0, cur: cur, enabled: enabled) }),
              let el = focusedTextElement(), isEditable(el), let before = fieldSnapshot(el),
              before.tail.hasSuffix(plan.original) else { return }
        let srcSource = cur.source
        beginCorrection {
            self.finishEnter(el: el, before: before, word: word, original: plan.original, text: plan.text,
                             flags: flags, target: plan.target, srcSource: srcSource)
        }
    }

    // Worker. Waits for the field to settle — the system may capitalize the word
    // ~50 ms after the line break appears, so a single changed read is not enough —
    // then retypes the word above the new line only for `.newline`.
    private func finishEnter(el: AXUIElement, before: FieldSnapshot, word: String, original: String, text: String,
                             flags: CGEventFlags, target: Layout, srcSource: TISInputSource) {
        guard let after = awaitSettledField(before: before, read: { self.fieldSnapshot(el) },
                                            wait: { usleep(useconds_t($0 * 1000)) })
        else { dbg("enter: field did not settle"); return }
        let outcome = enterOutcome(before: before, after: after, word: original)
        dbg("enter: \(outcome) before=\(before.tail.debugDescription) after=\(after.tail.debugDescription)")
        guard outcome == .newline else { return }
        waitModifiersReleased()
        eraseBack(original.count + 1)
        typeUnicode(text)
        typeKey("\r", flags: flags)
        usleep(autoLandPause)
        DispatchQueue.main.sync { _ = self.selectLayout(target) }
        recordConversion(Conv(original: original + "\r", typed: text + "\r",
                                    src: srcSource,
                                    autoWords: [learnedKey(word)]))
    }

    private func focusedTextElement() -> AXUIElement? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString,
                                            &v) == .success,
              let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        let el = v as! AXUIElement   // type checked above
        AXUIElementSetMessagingTimeout(el, 0.2)
        return el
    }

    // nil when the element does not expose caret, length and ranged text.
    /// False for text views whose value can't be set — terminals (Terminal, Ghostty),
    /// where Return runs the line instead of breaking it.
    private func isEditable(_ el: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success
            && settable.boolValue
    }

    private func fieldSnapshot(_ el: AXUIElement) -> FieldSnapshot? {
        var n: CFTypeRef?, r: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXNumberOfCharactersAttribute as CFString, &n) == .success,
              let count = n as? Int,
              AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &r) == .success,
              let r, CFGetTypeID(r) == AXValueGetTypeID() else { return nil }
        var sel = CFRange()
        guard AXValueGetValue(r as! AXValue, .cfRange, &sel) else { return nil }   // type checked above
        let lo = max(0, sel.location - 64)
        var win = CFRange(location: lo, length: sel.location - lo)
        var t: CFTypeRef?
        guard let arg = AXValueCreate(.cfRange, &win),
              AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString,
                                                         arg, &t) == .success,
              let tail = t as? String else { return nil }
        return FieldSnapshot(count: count, caret: sel.location, selected: sel.length, tail: tail)
    }

    // ',' ''' ';' '[' … are б э ж х on ЙЦУКЕН: while a Latin layout is active with a
    // Cyrillic layout enabled, such a char is word material ("было" arrives as
    // ",skj"), not a word boundary. Decided by the live layout maps, not a char
    // table, so any layout pair works. autoDecide re-vets the full word's shape.
    private func feedsAsCyr(_ s: String) -> Bool {
        let enabled = Layout.enabledList()
        guard let cur = enabled.first(where: { $0.id == currentSourceID() }),
              !cur.isCyrillic else { return false }
        return enabled.contains { $0.isCyrillic && mapsToWordChar(s[...], src: cur, dst: $0, connectors: true) }
    }

    @discardableResult
    private func autoEvaluate(word: String, trail: String, boundary: String, flags: CGEventFlags) -> Bool {
        let enabled = Layout.enabledList()
        guard let cur = enabled.first(where: { $0.id == currentSourceID() }) else {
            dbg("auto: no current layout \(currentSourceID())"); autoRun.noCandidate(); return false
        }
        let t0 = uptimeMs()
        var tExcluded = t0, tLearn = t0
        spellTime = (0, 0, 0, 0)
        var words = learned
        let before = words
        let (action, lessons) = evaluateBoundary(
            word: word, trail: trail, cur: cur, enabled: enabled,
            run: &autoRun, edits: &edits, learned: &words, chainTarget: &autoChainTarget,
            excluded: { let x = self.isAutoExcluded(); tExcluded = uptimeMs(); return x },
            decide: { w, verdict in
                tLearn = uptimeMs()
                return self.autoDecide(w, cur: cur, enabled: enabled, verdict: verdict)
            })
        if words != before { learned = words; refreshLearnedUI() }
        for lesson in lessons { dbg("learned by edit: \(lesson)") }
        if tLearn > t0 {
            dbg(String(format: "timing: excluded=%.1f learn=%.1f decide=%.1f (spell check %d× %.1f, guesses %d× %.1f) ms",
                       tExcluded - t0, tLearn - tExcluded, uptimeMs() - tLearn,
                       spellTime.checks, spellTime.checkMs, spellTime.guesses, spellTime.guessMs))
        }
        switch action {
        case .none:
            dbg("auto: \(word.debugDescription) left (excluded/learned/no candidate/waits)")
            return false
        case .switchLayout(let target):
            selectLayout(target)
            return false
        case .fix(let fix, let target):
            dbg("auto: \(word.debugDescription) -> \(fix.text.debugDescription) [\(target.id)] cur=\(cur.id)")
            let srcSource = cur.source
            beginCorrection {
                self.autoCorrect(fix, boundary: boundary, boundaryFlags: flags, target: target, srcSource: srcSource)
            }
            return true
        }
    }

    // Run one retype on `worker` with the keystroke gate held: everything the user
    // types meanwhile is swallowed by the tap and replayed here afterwards. Called
    // on the main thread (from the tap callback).
    func beginCorrection(_ body: @escaping () -> Void) {
        gate.close(at: ProcessInfo.processInfo.systemUptime)
        autoPending += 1
        let mark = pressAgain.mark
        worker.async {
            self.workMark = mark
            body()
            DispatchQueue.main.async { self.finishCorrection() }
        }
    }

    // Nothing left in flight -> replay the swallowed keys in order, each fed through
    // the word buffer BEFORE it is typed, exactly like live typing. A replayed
    // boundary that starts a correction is typed by that correction, and the keys
    // after it go back on hold until it lands — typing them first would put them
    // on screen past the word the correction deletes from the end.
    private func finishCorrection() {
#if DEBUG
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            dbg("field tail: \(self.focusedTextElement().flatMap { self.fieldSnapshot($0) }?.tail.debugDescription ?? "unreadable")")
        }
#endif
        autoPending -= 1
        guard autoPending == 0 else { return }
        guard !gate.held.isEmpty else { gate.open(); return }
        autoPending += 1
        let enabled = Layout.enabledList()
        let cur = enabled.first { $0.id == currentSourceID() }
        // One at a time: the gate stays shut, so keys typed during the replay queue
        // behind it; a replayed key that starts a correction leaves the rest held.
        while var k = gate.nextToReplay(at: ProcessInfo.processInfo.systemUptime) {
            // Typed blind in the layout the correction just switched away from: the
            // keys mean what they type in the new one, like Windows' replay by key code.
            if let cur, k.layout != cur.id, let src = enabled.first(where: { $0.id == k.layout }) {
                k.s = transliterate(k.s, from: src, to: cur)
            }
            dbg("replay \(k.s.debugDescription)")
            if k.s == "\r" || k.s == "\n" {
                // No Return follow-up here: its "before" read would race this very key.
                autoRun.reset()
            } else if autoFeed(k.s, flags: k.flags) { break }
            worker.async { self.typeKey(k.s, flags: k.flags) }
        }
        worker.async { DispatchQueue.main.async { self.finishCorrection() } }
    }

    // Return/Tab go out as real keys: apps act on the key code (Raycast launches,
    // chats send, forms advance), while a Unicode "\r" on key 0 is only text.
    private func typeKey(_ s: String, flags: CGEventFlags) {
        switch s {
        case "\r", "\n": postKey(CGKeyCode(kVK_Return), flags)
        case "\t": postKey(CGKeyCode(kVK_Tab), flags)
        default: typeUnicode(s)
        }
    }

    // Delete the wrong word (and a swallowed preposition before it), retype the
    // conversion and the boundary, switch the system layout. Records it so the
    // hotkey undo reverts.
    private func autoCorrect(_ fix: AutoRun.Fix, boundary: String, boundaryFlags: CGEventFlags,
                             target: Layout, srcSource: TISInputSource) {
        let t0 = uptimeMs()
        waitModifiersReleased()
        dbg("fix: erase=\(fix.erase) type=\(fix.text.debugDescription) -> \(target.id)")
        let t1 = uptimeMs()
        eraseBack(fix.erase)
        let t2 = uptimeMs()
        typeUnicode(fix.text)
        typeKey(boundary, flags: boundaryFlags)
        usleep(autoLandPause)
        let t3 = uptimeMs()
        DispatchQueue.main.sync { _ = self.selectLayout(target) }
        dbg(String(format: "timing fix: modifiers+trace=%.1f erase=%.1f type=%.1f select=%.1f ms",
                   t1 - t0, t2 - t1, t3 - t2, uptimeMs() - t3))
        recordConversion(Conv(original: fix.original + boundary, typed: fix.text + boundary,
                                    src: srcSource,
                                    autoWords: fix.original.split(separator: " ").map { learnedKey(String($0)) }))
    }

    /// True when the event was posted by macOS's TextInputSwitcher (the Globe HUD).
    fileprivate func isInputSwitcherEvent(_ event: CGEvent) -> Bool {
        let pid = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))
        guard pid > 0 else { return false }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.TextInputSwitcher"
    }

    private func isAutoExcluded() -> Bool {
        refreshKeyApp()
        if let bid = frontBundleID, autoExcludedApps.contains(bid) { return true }   // user deny-list
        return focusedIsSecureField()
    }

    // Every layout switch goes through here: TIS is documented to ignore a request
    // for the source it already believes is current, so a view that has drifted from
    // what the user actually types in silently swallows the switch. The trace tells
    // a refused switch from one that was accepted and never applied.
    @discardableResult
    private func selectLayout(_ l: Layout) -> Bool {
        let before = currentSourceID()
        let st = TISSelectInputSource(l.source)
        dbg("select \(l.id): status=\(st) before=\(before) after=\(currentSourceID())")
        return st == noErr
    }

    // The character this key produces under the layout that is current NOW. The
    // event's own string is attached upstream of the window server and goes stale
    // after a layout switch: the trace caught a key reading as "п" while the app
    // inserted "g", and the mirror case buffered Latin for a word typed in Cyrillic,
    // which then "converted" into the text already on screen. Derived here from the
    // physical key, it matched what the app inserted in every app measured (native
    // and Chromium alike). nil for keys no layout maps (Return, Tab, dead keys) —
    // the caller keeps the event's string for those.
    private func layoutChar(_ event: CGEvent) -> String? {
        guard let cur = Layout.enabledList().first(where: { $0.id == currentSourceID() }) else { return nil }
        var mods = UInt32(0)
        if event.flags.contains(.maskShift) { mods |= UInt32(shiftKey) >> 8 }
        if event.flags.contains(.maskAlternate) { mods |= UInt32(optionKey) >> 8 }
        let kc = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard let c = cur.strokeToChar[KeyStroke(keyCode: kc, mods: mods)] else { return nil }
        return event.flags.contains(.maskAlphaShift) ? c.uppercased() : c
    }

    private func currentSourceID() -> String {
        guard let curRef = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idPtr = TISGetInputSourceProperty(curRef, kTISPropertyInputSourceID) else { return "?" }
        return Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
    }

    // Focused element's selected text via Accessibility.
    //   nil  -> AX unavailable for the focused element (use clipboard fallback)
    //   ""   -> AX available, nothing selected
    //   text -> the selection
    // No copy event, no clipboard — keeps DeepL's Ctrl+C+C watcher quiet.
    private func axSelectedText() -> String? {
        let sys = AXUIElementCreateSystemWide()
        var appVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedApplicationAttribute as CFString, &appVal) == .success,
              let appVal, CFGetTypeID(appVal) == AXUIElementGetTypeID() else { return nil }
        let app = appVal as! AXUIElement   // type checked above
        var elVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &elVal) == .success,
              let elVal, CFGetTypeID(elVal) == AXUIElementGetTypeID() else { return nil }
        let el = elVal as! AXUIElement   // type checked above
        var txtVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &txtVal) == .success,
              let s = txtVal as? String else { return nil }
        return s
    }

    // Clipboard read (only when AX is unavailable): Cmd+C, trusted only if the
    // pasteboard actually changed (else nothing was selected). A single copy —
    // DeepL's watcher needs a Cmd+C-Cmd+C pair, so one synthetic press is safe.
    private func copySelection(_ pb: NSPasteboard) -> String? {
        let before = pb.changeCount
        // Cmd+C is the key that types "c" in the current layout (Dvorak: kVK_ANSI_I);
        // a layout with no "c" (Cyrillic) keeps the ANSI position, as macOS does.
        let c = DispatchQueue.main.sync { Layout.enabledList().first { $0.id == currentSourceID() }?.charToStroke["c"] }
        postKey(CGKeyCode(c.flatMap { $0.mods == 0 ? $0.keyCode : nil } ?? UInt16(kVK_ANSI_C)), .maskCommand)
        // Wait for the copy, not a fixed time: a copy landing after the restore would
        // stay on the clipboard for good.
        for _ in 0..<20 where pb.changeCount == before { usleep(pollInterval) }
        guard pb.changeCount != before, let c = pb.string(forType: .string), !c.isEmpty else { return nil }
        // VS Code (Monaco) copies the whole caret line when nothing is selected and
        // says so in its clipboard metadata; the hotkey converts only a selection.
        if let meta = pb.data(forType: NSPasteboard.PasteboardType("org.chromium.web-custom-data")),
           String(decoding: meta, as: UTF8.self).replacingOccurrences(of: "\0", with: "")
               .contains("\"isFromEmptySelection\":true") {
            dbg("Cmd+C copied a whole line from an empty selection"); return ""
        }
        dbg("read via Cmd+C: \(c.debugDescription)")
        return c
    }

    /// - Parameters:
    ///   - typed: the word typed before the caret and the spaces after it
    ///     (`AutoRun.hotkeyTarget`), converted when nothing is selected.
    func performRetype(typed: (text: String, spaces: Int) = ("", 0)) {
        guard AXIsProcessTrusted() else {
            DispatchQueue.main.async { self.promptAccessibilityIfNeeded() }
            return
        }

        // Press-again: right after a conversion, the next press retypes the
        // original into the next layout (three or more enabled), and once the
        // readings are exhausted it reverses the conversion. A multi-tap hotkey
        // counts once per completed sequence.
        switch DispatchQueue.main.sync(execute: { pressAgain.next() }) {
        case .retarget(let erase, let text, let dst, let then)?: return performRetarget(erase: erase, type: text, in: dst, then: then)
        case .undo(let last)?: return performUndo(last)
        case nil: break
        }

        waitModifiersReleased()

        // The clipboard is saved/restored ONLY on the Cmd+C fallback path. The AX
        // path never touches it, so we must not clear+restore it there — doing so
        // would wipe any non-string clipboard content (images, files) on every
        // retype. clipboardSaved is set iff we actually dirtied the pasteboard.
        let pb = NSPasteboard.general
        var clipboardSaved: [[NSPasteboard.PasteboardType: Data]] = []
        var clipboardTouched = false

        var sel: String?
        switch retypeSource(selection: axSelectedText(), hasTypedWord: !typed.text.isEmpty,
                            probeBlocked: ProcessInfo.processInfo.systemUptime - lastEmptyProbe < 1.0) {
        case .selection(let ax):
            // AX path — never touches the clipboard (DeepL stays quiet)
            dbg("read via AX: \(ax.debugDescription)"); sel = ax
        case .typedWord:
            break
        case .nothing:
            dbg("nothing selected, nothing typed (no Cmd+C probe so soon after an empty one)")
        case .clipboardProbe:
            // No AX selection to trust -> read the selection with Cmd+C (copy keeps the
            // selection; typing replaces exactly it, so smart cut-and-paste in
            // Word-like apps can't swallow an adjacent space). Save the prior
            // clipboard to restore it.
            clipboardSaved = snapshotClipboard(pb)
            clipboardTouched = true
            sel = copySelection(pb)
            if sel?.isEmpty ?? true { lastEmptyProbe = ProcessInfo.processInfo.systemUptime }
        }

        // convert() touches TIS APIs, which must run on the main thread (macOS 26
        // asserts otherwise). Hop to main for it.
        if sel?.isEmpty ?? true, !typed.text.isEmpty {
            if clipboardTouched { restoreClipboard(clipboardSaved) }
            retypeTyped(typed); return
        }
        guard let text = sel, !text.isEmpty,
              let r = DispatchQueue.main.sync(execute: { self.convert(text) }) else {
            dbg("nothing to convert")
            if clipboardTouched { restoreClipboard(clipboardSaved) }
            return
        }

        // WRITE via synthesized Unicode keystrokes (no clipboard, no paste) — the
        // active selection is replaced by the typed input, like Caramba. No copy/paste
        // events, so DeepL stays quiet. Clipboard is never used for writing.
        dbg("type: \(r.out.debugDescription) replacing \(text.debugDescription)")
        typeUnicode(r.out)
        usleep(landPause)
        DispatchQueue.main.sync { self.autoRun.reset(); self.selectLayout(r.dst) }
        // restore clipboard only if the Cmd+C read fallback dirtied it
        if clipboardTouched { restoreClipboard(clipboardSaved) }
        // remember it so a quick second hotkey can undo
        recordConversion(Conv(original: text, typed: r.out, src: r.src.source,
                                    learned: r.learned, alternatives: r.alternatives))
    }

    // No selection: erase the word just typed (and the spaces after it), type its
    // conversion and the same spaces.
    private func retypeTyped(_ typed: (text: String, spaces: Int)) {
        guard let r = DispatchQueue.main.sync(execute: { self.convert(typed.text) }) else {
            dbg("nothing to convert in typed \(typed.text.debugDescription)"); return
        }
        let spaces = String(repeating: " ", count: typed.spaces)
        dbg("type: \(r.out.debugDescription) replacing typed \(typed.text.debugDescription) +\(typed.spaces) spaces")
        eraseBack(typed.text.count + typed.spaces)
        typeUnicode(r.out + spaces)
        usleep(landPause)
        DispatchQueue.main.sync { self.autoRun.reset(); self.selectLayout(r.dst) }
        recordConversion(Conv(original: typed.text + spaces, typed: r.out + spaces, src: r.src.source,
                                    learned: r.learned,
                                    alternatives: r.alternatives, suffix: spaces))
    }

    // The next reading of the original: erase what was just typed, type the
    // alternative, switch to its layout; the remaining readings stay in the record.
    private func performRetarget(erase: Int, type text: String, in dst: Layout, then: Conv) {
        waitModifiersReleased()
        dbg("retarget: \(text.debugDescription) -> \(dst.id)")
        eraseBack(erase)
        typeUnicode(text)
        usleep(landPause)
        DispatchQueue.main.sync { self.autoRun.remember(text); self.selectLayout(dst) }
        recordConversion(then)
    }

    // Reverse the last conversion: erase the text we just typed (the caret sits
    // right after it; Backspace, not Shift+Left: a terminal has no selection and
    // gets the arrow's escape sequence), type the original, flip the source back.
    private func performUndo(_ last: Conv) {
        waitModifiersReleased()
        dbg("undo: restore \(last.original.debugDescription)")
        DispatchQueue.main.sync { if self.autoMode { self.unlearn(last) } }   // UserDefaults: main thread
        eraseBack(last.typed.count)
        // A Return/Tab boundary goes back as the real key, like it was typed.
        if let b = last.original.last, "\r\n\t".contains(b) {
            typeUnicode(String(last.original.dropLast()))
            typeKey(String(b), flags: [])
        } else {
            typeUnicode(last.original)
        }
        usleep(landPause)
        // The restored text stays the hotkey's target as a whole (engine `remember`:
        // not fed through the word buffer, which would split it at punctuation).
        DispatchQueue.main.sync { _ = TISSelectInputSource(last.src); self.autoRun.remember(last.original) }
    }

    // Insert a string by synthesizing per-character Unicode key events. A line
    // break rides in one event with its neighbour: VS Code drops a lone "\n". A run
    // of spaces goes as one event: a second typed space fires the system's "period
    // with double-space", which VS Code applies at the wrong place.
    private func typeUnicode(_ s: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        var rest = s[...]
        while let first = rest.popFirst() {
            var piece = String(first)
            // At most 20 UTF-16 units per event: that is all one event is known to carry.
            while let c = rest.first, piece.utf16.count < 20, c.isNewline || (c == " " && first == " ") {
                piece.append(rest.removeFirst())
            }
            if first.isNewline, let c = rest.popFirst() { piece.append(c) }
            let units = Array(piece.utf16)
            if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
                down.flags = []
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                markSynth(down)
                down.post(tap: .cgSessionEventTap)
            }
            if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                up.flags = []
                up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                markSynth(up)
                up.post(tap: .cgSessionEventTap)
            }
            usleep(keyGap)
        }
    }

    // Every item with every flavor: restoring only the string flavor dropped a
    // copied image or file and left rich text as plain text.
    private func snapshotClipboard(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t, $0) } })
        }
    }

    private func restoreClipboard(_ saved: [[NSPasteboard.PasteboardType: Data]]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let items = saved.map { flavors -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, d) in flavors { item.setData(d, forType: t) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }
}

// MARK: - main

#if !TESTING
@main
enum ReLayoutApp {
    static func main() {
        if CommandLine.arguments.contains("--enabled") { printEnabledSources(); exit(0) }
        if CommandLine.arguments.contains("--selftest") { runSelfTest(); exit(0) }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = AppController.shared
        app.run()
    }

    // --enabled: dump the ENABLED keyboard sources in input-menu order.
    private static func printEnabledSources() {
        print("ENABLED keyboard sources, in TISCreateInputSourceList(nil,false) order:")
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
        guard let listPtr = TISCreateInputSourceList(filter, false)?.takeRetainedValue() else { return }
        for i in 0..<CFArrayGetCount(listPtr) {
            guard let raw = CFArrayGetValueAtIndex(listPtr, i) else { continue }
            let src = Unmanaged<TISInputSource>.fromOpaque(raw).takeUnretainedValue()
            let idP = TISGetInputSourceProperty(src, kTISPropertyInputSourceID)
            let nmP = TISGetInputSourceProperty(src, kTISPropertyLocalizedName)
            let id = idP.map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? "?"
            let nm = nmP.map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? "?"
            print("  [\(i)] \(nm)  —  \(id)")
        }
    }

    // --selftest: run convertWrong against the live ABC + Cyrillic layouts.
    private static func runSelfTest() {
        func short(_ l: Layout) -> String { l.id.replacingOccurrences(of: "com.apple.keylayout.", with: "") }
        let enabled = Layout.enabledList()
        print("enabled:", enabled.map { "\(short($0))\($0.isCyrillic ? "(cyr)" : "")" }.joined(separator: ", "))
        let byId = Dictionary(uniqueKeysWithValues: enabled.map { ($0.id, $0) })
        let ukr = byId.values.first { $0.isCyrillic }
        let abc = byId["com.apple.keylayout.ABC"]
        guard let ukr, let abc else { return }
        let pairs: [(String, Layout, Layout)] = [("ABC->UKR", abc, ukr), ("UKR->ABC", ukr, abc)]
        for (lbl, src, dst) in pairs {
            print("\n-- convertWrong \(lbl) (src=\(short(src)) dst=\(short(dst))) --")
            let samples = lbl.hasPrefix("ABC")
                ? ["ghbdtn", "я сказал ghbdtn", "я написал ßæ", "привет мир",
                   "rjt-xnj", "v\\zrj", "g\\æcf", "hjrjdbq gj-heccrb", "rfhf,f[", "vj«", "vj]", "vj'", "gj[j;"]
                : ["руддщ", "привет мир", "I said привет"]
            for s in samples {
                print("  \(s.debugDescription) -> \(convertWrong(s, src: src, dst: dst)?.debugDescription ?? "nil")")
            }
        }
    }
}
#endif

#if SPARKLE
extension AppController: SPUUpdaterDelegate {
    /// Silent updates install on quit; a menu-bar app never quits, so install (and relaunch) now.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        immediateInstallHandler()
        return true
    }
}
#endif
