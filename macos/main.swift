import Cocoa
import Carbon.HIToolbox
import ServiceManagement
import UniformTypeIdentifiers
#if SPARKLE
import Sparkle   // only linked in release builds (build.sh WITH_SPARKLE=1)
#endif

// MARK: - Helpers

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
func dbg(_ s: String) {
#if DEBUG
    let dbgPath = "/tmp/relayout.log"
    let data = Data((s + "\n").utf8)
    if let h = FileHandle(forWritingAtPath: dbgPath) {
        h.seekToEndOfFile(); h.write(data); h.closeFile()
    } else {
        try? data.write(to: URL(fileURLWithPath: dbgPath))
    }
#endif
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

final class Layout: LayoutMaps {
    let id: String
    let source: TISInputSource
    private(set) var charToStroke: [String: KeyStroke] = [:]
    private(set) var strokeToChar: [KeyStroke: String] = [:]
    private(set) var isCyrillic = false

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
    // (mode, keyCode, carbonMods, chord, taps, display)
    var onCommit: ((HKMode, UInt32, UInt32, [UInt16], Int, String) -> Void)?
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

    init(display: String) {
        self.display = display
        super.init(frame: NSRect(x: 0, y: 0, width: 150, height: 24))
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(L("settings.hotkey"))
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
        if finalize, seqMode != nil { finalizeSequence() }
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

    // The sequence is finished (window elapsed) -> save it. Stay focused so the
    // user can immediately record a different sequence (which replaces this one).
    private func finalizeSequence() {
        guard let mode = seqMode else { return }
        seqTimer = nil
        let disp = seqDisplay()
        display = disp
        committing = true                 // onCommit relayouts the window / churns focus
        defer { committing = false }
        onCommit?(mode, seqCode, seqMods, seqChord, seqTaps, disp)
        window?.makeFirstResponder(self)
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

// MARK: - App controller

final class AppController: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = AppController()

    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
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

    // user-configurable hotkey (persisted in UserDefaults). Default: tap left Option.
    private var hotKeyMode: HKMode = .modTap
    private var hotKeyCode = UInt32(kVK_ANSI_R)   // carbon: virtual key
    private var hotKeyMods = UInt32(controlKey | optionKey)
    private var hotKeyChord: [UInt16] = [UInt16(kVK_Option)]   // modTap: modifier virtual keys
    private var hotKeyTaps = 1     // activations within the window to fire (1 = single tap)
    private var hotKeyDisplay = "left⌥"

    // Last conversion, for double-tap undo: pressing the hotkey again within
    // undoWindow seconds reverses it (reselects the typed text, restores the
    // original, flips the input source back). Accessed only from `worker`
    // (serial), so no lock. systemUptime is monotonic.
    private struct Conversion {
        let original: String
        let typed: String
        let srcSource: TISInputSource
        let time: Double
    }
    private var lastConversion: Conversion?
    private let undoWindow = 1.5

    // modifier-tap runtime state
    private var tapMonitors: [Any] = []
    fileprivate var keyTap: CFMachPort?       // CGEventTap that flags key presses during a hold
    private var keyTapSource: CFRunLoopSource?
    fileprivate var tapArmed = false
    private var tapArmTime: Double = 0
    fileprivate var tapInterrupted = false    // set by the key tap (file-scope callback)
    private var tapPolluted = false   // an out-of-set modifier appeared this cycle

    // Multi-tap hotkeys: a hotkey can require N activations within doubleTapWindow
    // (e.g. double-tap Shift). The count is part of the recorded hotkey (hotKeyTaps),
    // so there's no separate toggle. While hotKeyTaps > 1, press-again-undo is off.
    private var tapSeqCount = 0
    private var tapSeqTime = 0.0
    private let doubleTapWindow = 0.5
    private let modTapHoldWindow = 0.6   // max chord-hold duration to count as a tap

    // settings
    private var settingsWindow: NSWindow?
    private var settingsIsKey = false   // hotkey + auto-correct are paused while Settings is focused
    private var excWindow: NSWindow?    // auto-correct exceptions editor
    private weak var excTable: NSTableView?
    private weak var lastActiveApp: NSRunningApplication?   // last non-self frontmost app ("exclude current")
    private weak var shortcutField: ShortcutField?
    private weak var conflictLabel: NSTextField?
    private weak var loginCheckbox: NSButton?

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        Loc.load()   // apply saved language override before any UI is built
#if SPARKLE
        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
#endif
        promptAccessibilityIfNeeded()
        loadHotkey()
        installHotKeyHandler()
        applyHotkey()
        applyAutoMode()          // start the auto-correct monitor if enabled
        // Track the last non-self frontmost app so "Exclude current app" can target
        // it (once our Settings/Exceptions window is key, WE are frontmost).
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.bundleIdentifier != Bundle.main.bundleIdentifier {
                self?.lastActiveApp = app
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
        }
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        // Always the static "rL" wordmark. It's monochrome, so use it as a TEMPLATE
        // image: the system tints it to the menu-bar foreground colour (white on a
        // dark bar, black on a light bar), correct even when the bar's tint doesn't
        // match the app's Light/Dark appearance (e.g. wallpaper-driven).
        let glyph = (NSImage(named: "for-light-text-1024")?.copy() as? NSImage)
            ?? NSApp.applicationIconImage ?? NSImage()
        glyph.size = NSSize(width: 18, height: 18)
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

    @objc private func toggleAutoCorrect(_ sender: NSButton) {
        autoMode = (sender.state == .on)   // setter starts/stops the monitor
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

    // Single entry point for both hotkey modes. Fires once the hotkey has been
    // activated hotKeyTaps times within doubleTapWindow (1 = fire immediately).
    func triggerHotkey() {
        if hotKeyTaps <= 1 { worker.async { self.performRetype() }; return }
        let now = ProcessInfo.processInfo.systemUptime
        tapSeqCount = (now - tapSeqTime <= doubleTapWindow) ? tapSeqCount + 1 : 1
        tapSeqTime = now
        if tapSeqCount >= hotKeyTaps {
            tapSeqCount = 0
            worker.async { self.performRetype() }
        }
    }

    private func installHotKeyHandler() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let ih = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            dbg("hotkey fired")
            AppController.shared.triggerHotkey()
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = (ih == noErr)
        dbg("InstallEventHandler status=\(ih)")
    }

    // Unregister the live hotkey (both modes). Used to pause it while the user
    // records a new one, and as the first half of applyHotkey.
    private func suspendHotkey() {
        if let r = hotKeyRef { UnregisterEventHotKey(r); hotKeyRef = nil }
        for m in tapMonitors { NSEvent.removeMonitor(m) }
        tapMonitors.removeAll()
        removeEventTap(&keyTap, &keyTapSource)
        tapArmed = false
        tapPolluted = false
        tapInterrupted = false
        tapSeqCount = 0; tapSeqTime = 0   // don't carry a stale multi-tap count into a new hotkey
    }

    // Tear down whatever is active, then install the current mode.
    private func applyHotkey() {
        suspendHotkey()
        // The hotkey is disabled while the Settings window is focused: the user is
        // configuring/recording there, so taps must not trigger a retype (which could
        // also leak our synthetic Cmd+X into the field/doc). setSettingsKey re-applies
        // once Settings loses focus or closes.
        guard !settingsIsKey else { return }

        switch hotKeyMode {
        case .carbon:
            let hkID = EventHotKeyID(signature: fourCharCode("RLAY"), id: 1)
            let st = RegisterEventHotKey(hotKeyCode, hotKeyMods, hkID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
            dbg("carbon hotkey code=\(hotKeyCode) mods=\(hotKeyMods) status=\(st)")
        case .modTap:
            setupTapMonitors()
            dbg("modTap hotkey chord=\(hotKeyChord)")
        }
    }

    // Create a listen-only session event tap, add it to the main run loop, enable it.
    private func installEventTap(_ mask: CGEventMask, _ callback: CGEventTapCallBack) -> (CFMachPort, CFRunLoopSource?)? {
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask, callback: callback,
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
                me.tapInterrupted = true   // a key/mouse during the hold -> not a tap
                me.tapArmed = false
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                if let t = me.keyTap { CGEvent.tapEnable(tap: t, enable: true) }
            default:
                break
            }
            return Unmanaged.passUnretained(event)
        }
        if let (tap, src) = installEventTap(mask, cb) { keyTap = tap; keyTapSource = src }
    }

    // Called from the event tap on every modifier change. `cur` = the modifier
    // keys currently held. Arms on the exact chord, fires on a clean release.
    fileprivate func handleTapFlags(_ cur: Set<UInt16>) {
        let target = Set(hotKeyChord.map(canonicalMod))   // normalize L/R to match cur
        guard !target.isEmpty else { return }
        if cur.isEmpty {
            // fire only on a clean cycle: exact chord, no extra modifier ever, no
            // key/mouse interruption, released quickly.
            if tapArmed, !tapInterrupted, !tapPolluted,
               ProcessInfo.processInfo.systemUptime - tapArmTime < modTapHoldWindow {
                triggerHotkey()
            }
            tapArmed = false
            tapPolluted = false   // reset for the next press cycle
        } else if !cur.isSubset(of: target) {
            // a modifier OUTSIDE the configured set was held together with it —
            // poison the whole cycle so releasing back to the chord can't re-arm.
            tapPolluted = true
            tapArmed = false
        } else if cur == target {
            if !tapPolluted, !tapArmed {
                tapArmed = true
                tapArmTime = ProcessInfo.processInfo.systemUptime
                tapInterrupted = false
            }
        }
        // a non-empty strict subset = chord still building up / partially released -> wait
    }

    // MARK: hotkey persistence

    private func loadHotkey() {
        let d = UserDefaults.standard
        guard d.object(forKey: "hkType") != nil else { return } // keep defaults
        hotKeyMode = HKMode(rawValue: d.integer(forKey: "hkType")) ?? .carbon
        hotKeyCode = UInt32(d.integer(forKey: "hkCode"))
        hotKeyMods = UInt32(d.integer(forKey: "hkMods"))
        hotKeyChord = (d.array(forKey: "hkChord") as? [Int])?.map { UInt16($0) } ?? []
        hotKeyTaps = max(1, d.integer(forKey: "hkTaps"))   // 0 (absent) -> 1
        hotKeyDisplay = d.string(forKey: "hkDisplay") ?? hotKeyDisplay
    }

    private func saveHotkey(mode: HKMode, code: UInt32, mods: UInt32, chord: [UInt16], taps: Int, display: String) {
        hotKeyMode = mode; hotKeyCode = code; hotKeyMods = mods; hotKeyChord = chord
        hotKeyTaps = max(1, taps); hotKeyDisplay = display
        let d = UserDefaults.standard
        d.set(mode.rawValue, forKey: "hkType")
        d.set(Int(code), forKey: "hkCode")
        d.set(Int(mods), forKey: "hkMods")
        d.set(chord.map { Int($0) }, forKey: "hkChord")
        d.set(hotKeyTaps, forKey: "hkTaps")
        d.set(display, forKey: "hkDisplay")
    }

    // default hotkey: tap left Option
    private static let defaultHotkey: (HKMode, UInt32, UInt32, [UInt16], String) =
        (.modTap, UInt32(kVK_ANSI_R), UInt32(controlKey | optionKey), [UInt16(kVK_Option)], "left ⌥")

    @objc private func resetHotkey() {
        shortcutField?.endRecording()      // a recording in progress must not override the reset
        let d = AppController.defaultHotkey
        commitHotkey(d.0, d.1, d.2, d.3, 1, d.4)
        shortcutField?.display = d.4
    }

    // Commit a hotkey captured by the ShortcutField.
    private func commitHotkey(_ mode: HKMode, _ code: UInt32, _ mods: UInt32, _ chord: [UInt16], _ taps: Int, _ display: String) {
        saveHotkey(mode: mode, code: code, mods: mods, chord: chord, taps: taps, display: display)
        applyHotkey()
        setupMenu()
        let warn = mode == .carbon ? systemHotkeyConflict(keyCode: UInt16(code), cocoaMods: cocoaMods(mods)) : nil
        conflictLabel?.stringValue = warn.map { String(format: L("settings.conflict"), $0) } ?? ""
        conflictLabel?.isHidden = (warn == nil)   // collapse the row when no conflict
        fitSettingsWindow()                       // re-fit so row spacing stays constant
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

        let field = ShortcutField(display: hotKeyDisplay)
        field.onCommit = { [weak self] mode, code, mods, chord, taps, disp in
            self?.commitHotkey(mode, code, mods, chord, taps, disp)
        }
        field.onRecordingChanged = { [weak self] active in
            // Suspend BOTH the live hotkey and the auto-correct monitor while
            // recording, so nothing fires (or auto-edits) on the keys being captured.
            if active {
                self?.suspendHotkey(); self?.stopAutoMonitor()
            } else {
                self?.applyHotkey(); self?.applyAutoMode()
            }
        }
        shortcutField = field
        let resetIcon = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: L("settings.restoreDefault"))
        let reset = NSButton(image: resetIcon ?? NSImage(), target: self, action: #selector(resetHotkey))
        reset.isBordered = false
        reset.bezelStyle = .accessoryBar
        reset.imageScaling = .scaleProportionallyDown
        reset.toolTip = L("settings.restoreDefault")
        field.setContentHuggingPriority(.init(1), for: .horizontal)   // let it stretch to fill the row
        let hkRow = NSStackView(views: [field, reset])
        hkRow.orientation = .horizontal
        hkRow.spacing = 8
        hkRow.alignment = .centerY

        let conflict = NSTextField(labelWithString: "")
        conflict.font = .systemFont(ofSize: 11)
        conflict.textColor = .systemOrange
        conflictLabel = conflict
        if hotKeyMode == .carbon,
           let w = systemHotkeyConflict(keyCode: UInt16(hotKeyCode), cocoaMods: cocoaMods(hotKeyMods)) {
            conflict.stringValue = String(format: L("settings.conflict"), w)
        }
        conflict.isHidden = conflict.stringValue.isEmpty   // no empty line when no conflict

        // hotkey field + (optional) conflict warning. The hotkey can be a multi-tap
        // sequence (e.g. double Shift) — just record it twice; no separate toggle.
        let hkColumn = NSStackView(views: [hkRow, conflict])
        hkColumn.orientation = .vertical
        hkColumn.alignment = .leading
        hkColumn.spacing = 4

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
        let autoRow = NSStackView(views: [autoCb, excBtn])
        autoRow.orientation = .horizontal; autoRow.spacing = 12; autoRow.alignment = .centerY

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
        let capW = ceil(max(caption(L("settings.language")).fittingSize.width,
                            caption(L("settings.hotkey")).fittingSize.width))
        let langGrid = NSGridView(views: [[caption(L("settings.language")), langPopup]])
        let hkGrid   = NSGridView(views: [[caption(L("settings.hotkey")), hkColumn]])
        for g in [langGrid, hkGrid] {
            g.rowSpacing = 10; g.columnSpacing = 10
            g.column(at: 0).xPlacement = .leading
            g.column(at: 0).width = capW
            g.rowAlignment = .none
        }
        langGrid.row(at: 0).yPlacement = .center
        hkGrid.row(at: 0).yPlacement = .center   // caption centered with the field

        // ── footer: version + link + copyright ──
        let info = Bundle.main.infoDictionary
        let verStr = (info?["RLVersionFull"] as? String) ?? (info?["CFBundleShortVersionString"] as? String) ?? ""
        let version = makeSecondaryLabel(verStr.isEmpty ? "" : "Version \(verStr)")
        let url = "github.com/vladforfutdinov/reLayout"
        let link = NSButton(title: url, target: self, action: #selector(openProjectURL))
        link.isBordered = false; link.bezelStyle = .inline; link.alignment = .center
        link.attributedTitle = NSAttributedString(string: url, attributes: [
            .foregroundColor: NSColor.linkColor, .font: NSFont.systemFont(ofSize: 11)])
        let copyright = makeSecondaryLabel((info?["NSHumanReadableCopyright"] as? String) ?? "")

        func sep() -> NSBox {
            let b = NSBox(); b.boxType = .separator
            b.translatesAutoresizingMaskIntoConstraints = false
            return b
        }
        let sep1 = sep(), sep2 = sep(), sep3 = sep()

        // Section A: login + auto-update + language. Section B: auto-correct + hotkey.
        var arranged: [NSView] = [logo, name, sep1, cb]
#if SPARKLE
        let autoUpdateCb = makeCheckbox(L("settings.autoUpdate"), #selector(toggleAutoUpdate(_:)),
                                        on: updater?.updater.automaticallyChecksForUpdates ?? true)
        arranged.append(autoUpdateCb)
#endif
        arranged += [langGrid, sep2, autoRow, hkGrid, sep3, version, link, copyright]

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
            sep3.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hkRow.widthAnchor.constraint(equalTo: langPopup.widthAnchor),   // hotkey field == language popup width
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
        // Pause the live hotkey + auto-correct whenever Settings is the key window
        // (the user is configuring there), resume when it loses focus or closes.
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { [weak self] _ in
            self?.setSettingsKey(true)
        }
        nc.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { [weak self] _ in
            self?.setSettingsKey(false)
        }
        nc.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.setSettingsKey(false)
        }
        w.initialFirstResponder = nil
        activateApp()
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(nil)   // don't leave the first checkbox focused on open
    }

    private func setSettingsKey(_ key: Bool) {
        guard settingsIsKey != key else { return }
        settingsIsKey = key
        if key { suspendHotkey(); stopAutoMonitor() }
        else { applyHotkey(); applyAutoMode() }
    }

    @objc private func openProjectURL() {
        if let u = URL(string: "https://github.com/vladforfutdinov/reLayout") { NSWorkspace.shared.open(u) }
    }

    // MARK: - Auto-correct exceptions (per-app deny-list editor)

    @objc private func openExceptions() {
        if let w = excWindow { activateApp(); w.makeKeyAndOrderFront(nil); excTable?.reloadData(); return }
        let w = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 280),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = L("settings.exc.title")
        w.isReleasedWhenClosed = false
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        w.contentView = content

        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
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
        let bar = NSStackView(views: [btn("settings.exc.addCurrent", #selector(excAddCurrent)),
                                      btn("settings.exc.choose", #selector(excChoose)),
                                      spacer,
                                      btn("settings.exc.remove", #selector(excRemove))])
        bar.orientation = .horizontal; bar.spacing = 8; bar.distribution = .fill
        bar.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scroll); content.addSubview(bar)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 380),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.heightAnchor.constraint(equalToConstant: 200),
            bar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        excWindow = w
        activateApp(); w.center(); w.makeKeyAndOrderFront(nil)
        table.reloadData()
    }

    @objc private func excAddCurrent() {
        guard let b = lastActiveApp?.bundleIdentifier else { NSSound.beep(); return }
        addExcluded(b)
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

    @objc private func excRemove() {
        guard let t = excTable else { return }
        let rows = t.selectedRowIndexes
        guard !rows.isEmpty else { return }
        autoExcludedApps = autoExcludedApps.enumerated().filter { !rows.contains($0.offset) }.map { $0.element }
        t.reloadData()
    }

    private func addExcluded(_ bid: String) {
        var list = autoExcludedApps
        guard !list.contains(bid) else { return }
        list.append(bid)
        autoExcludedApps = list
        excTable?.reloadData()
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

    func numberOfRows(in tableView: NSTableView) -> Int { autoExcludedApps.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let info = appInfo(autoExcludedApps[row])
        let iv = NSImageView(image: info.icon)
        iv.translatesAutoresizingMaskIntoConstraints = false
        let tf = NSTextField(labelWithString: info.name)
        tf.lineBreakMode = .byTruncatingTail
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.toolTip = autoExcludedApps[row]
        let cell = NSTableCellView()
        cell.addSubview(iv); cell.addSubview(tf)
        cell.textField = tf
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 16),
            iv.heightAnchor.constraint(equalToConstant: 16),
            tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
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
            usleep(20_000)
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
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // Source = current (wrong) layout. Target chosen by:
    //   - 2 enabled       -> the other one
    //   - >2, cur != #0   -> #0 (first)
    //   - >2, cur == #0   -> layout of the OTHER-script words if uniquely determinable,
    //                        else #1 (second)
    private func convert(_ text: String) -> (out: String, dst: Layout, src: Layout)? {
        let enabled = Layout.enabledList()
        guard enabled.count >= 2 else { return nil }
        let curID = currentSourceID()
        guard let curIdx = enabled.firstIndex(where: { $0.id == curID }) else { return nil }
        let cur = enabled[curIdx]

        // Hybrid source detection: normally the wrong layout is the active one (you
        // pressed the hotkey right after mistyping). But if the text contains NONE
        // of the current layout's script, you switched layout after typing — detect
        // the wrong layout from the text instead, and convert back to the current
        // (target) layout. Common case is untouched -> no regression.
        if !textHasScript(text, cyrillic: cur.isCyrillic),
           let wrongCyr = dominantScript(text), wrongCyr != cur.isCyrillic,
           let src = enabled.first(where: { $0.isCyrillic == wrongCyr }),
           let out = convertWrong(text, src: src, dst: cur) {
            dbg("convert[detected] src=\(src.id) -> dst=\(cur.id)")
            return (out, cur, src)
        }

        let target: Layout
        if enabled.count == 2 {
            target = enabled[curIdx == 0 ? 1 : 0]
        } else if curIdx != 0 {
            target = enabled[0]
        } else if let rest = restTextLayout(text, cur: cur, enabled: enabled) {
            target = rest
        } else {
            target = enabled[1]
        }

        dbg("convert cur=\(cur.id) -> target=\(target.id)")
        guard let out = convertWrong(text, src: cur, dst: target) else { return nil }
        return (out, target, cur)
    }

    // MARK: - auto-mode (trigram detection)

    // Calibrated for ~99% precision on cross-script pairs (see scripts/trigram).
    private let autoGarbage: Float = -2.5   // word looks like junk in its own language
    private let autoMargin:  Float = 0.5    // converted form must beat it by this much

    private var trigramCache: [String: TrigramModel?] = [:]
    private func trigram(_ lang: String) -> TrigramModel? {
        if let c = trigramCache[lang] { return c }
        let m = Bundle.main.url(forResource: lang, withExtension: "txt", subdirectory: "trigram")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .flatMap { TrigramModel(text: $0) }
        trigramCache[lang] = m
        return m
    }

    // Decide whether a just-typed word `w` (in layout `cur`) was typed in the wrong
    // layout, and to which cross-script target. Returns (target, converted) or nil.
    // Auto fires ONLY between layouts of different scripts (Cyrillic<->Latin), where
    // detection is reliable; same-script pairs always return nil.
    func autoDecide(_ w: String, cur: Layout, enabled: [Layout]) -> (target: Layout, out: String)? {
        guard w.count >= 3, w.unicodeScalars.allSatisfy({ $0.properties.isAlphabetic }) else { return nil }
        guard let curLang = cur.languageCode, let curModel = trigram(curLang) else { return nil }
        let targets = enabled.filter { $0.isCyrillic != cur.isCyrillic }   // cross-script only
        guard !targets.isEmpty else { return nil }

        let sTyped = curModel.score(w)
        guard sTyped < autoGarbage else { return nil }   // already plausible -> leave it

        var best: (Layout, String, Float)?
        for t in targets {
            guard let out = convertWrong(w, src: cur, dst: t), out != w,
                  let tLang = t.languageCode, let tModel = trigram(tLang) else { continue }
            let sAlt = tModel.score(out)
            guard sAlt - sTyped > autoMargin else { continue }
            if best == nil || sAlt > best!.2 { best = (t, out, sAlt) }
        }
        guard let b = best else { return nil }
        return (b.0, b.1)
    }

    // MARK: - auto-mode live monitor

    var autoMode: Bool {
        get { UserDefaults.standard.bool(forKey: "autoMode") }
        set { UserDefaults.standard.set(newValue, forKey: "autoMode"); applyAutoMode() }
    }
    fileprivate var autoTap: CFMachPort?
    private var autoTapSource: CFRunLoopSource?
    fileprivate var autoBuffer = ""

    // Apps where auto-correct stays off — a user-editable deny-list (Settings >
    // Auto-correct > Exceptions…). Seeded once with common terminals/IDEs.
    private static let defaultExcludedApps: [String] = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.microsoft.VSCode",
        "com.apple.dt.Xcode", "com.sublimetext.4", "org.alacritty",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm",
    ]
    var autoExcludedApps: [String] {
        get { UserDefaults.standard.array(forKey: "autoExcludedApps") as? [String]
                ?? AppController.defaultExcludedApps }
        set { UserDefaults.standard.set(newValue, forKey: "autoExcludedApps") }
    }

    func applyAutoMode() { (autoMode && !settingsIsKey) ? startAutoMonitor() : stopAutoMonitor() }

    private func startAutoMonitor() {
        guard autoTap == nil else { return }
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let cb: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<AppController>.fromOpaque(refcon).takeUnretainedValue()
            if type == .keyDown,
               event.getIntegerValueField(.eventSourceUserData) != AppController.synthMarker,
               !event.flags.contains(.maskCommand), !event.flags.contains(.maskControl) {
                // Skip shortcuts/combo-hotkeys (Cmd/Ctrl held): not text, and the
                // combo-hotkey's own key must not clear a pending auto-fix undo.
                var len = 0
                var buf = [UniChar](repeating: 0, count: 4)
                event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &buf)
                me.autoFeed(String(utf16CodeUnits: buf, count: len))
            } else if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = me.autoTap { CGEvent.tapEnable(tap: t, enable: true) }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let (tap, src) = installEventTap(mask, cb) else { return }
        autoTap = tap; autoTapSource = src
    }

    private func stopAutoMonitor() {
        removeEventTap(&autoTap, &autoTapSource)
        autoBuffer = ""
    }

    // Feed a produced character into the word buffer; evaluate on a word boundary.
    fileprivate func autoFeed(_ s: String) {
        // Any real keystroke after an (auto or hotkey) conversion ends its undo
        // window — the caret has moved on, so a later hotkey press should CONVERT
        // the new word, not revert the old fix. The undo hotkey itself is a
        // modifier/Cmd-combo (filtered above), so it never reaches here.
        lastConversion = nil
        if s == " " || s == "\r" || s == "\n" || s == "\t" {
            autoEvaluate(boundary: s); autoBuffer = ""
        } else if s.count == 1, let c = s.first, c.isLetter {
            autoBuffer.append(c)
            if autoBuffer.count > 64 { autoBuffer.removeFirst(autoBuffer.count - 64) }
        } else {
            autoBuffer = ""   // punctuation / navigation / delete -> end the run
        }
    }

    private func autoEvaluate(boundary: String) {
        let word = autoBuffer
        guard word.count >= 3, !isAutoExcluded() else { return }
        let enabled = Layout.enabledList()
        guard let cur = enabled.first(where: { $0.id == currentSourceID() }),
              let d = autoDecide(word, cur: cur, enabled: enabled) else { return }
        let srcSource = cur.source
        worker.async {
            self.autoCorrect(word: word, boundary: boundary,
                             target: d.target, srcSource: srcSource, out: d.out)
        }
    }

    // Delete the wrong word (+ the boundary just typed), retype the converted text
    // and boundary, switch the system layout. Records it so the hotkey undo reverts.
    private func autoCorrect(word: String, boundary: String, target: Layout,
                             srcSource: TISInputSource, out: String) {
        waitModifiersReleased()
        for _ in 0..<(word.count + boundary.count) { postKey(CGKeyCode(kVK_Delete), []) }
        usleep(10_000)
        typeUnicode(out + boundary)
        usleep(10_000)
        DispatchQueue.main.sync { _ = TISSelectInputSource(target.source) }
        lastConversion = Conversion(original: word + boundary, typed: out + boundary,
                                    srcSource: srcSource, time: ProcessInfo.processInfo.systemUptime)
    }

    private func isAutoExcluded() -> Bool {
        if let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           autoExcludedApps.contains(bid) { return true }   // user deny-list
        let sys = AXUIElementCreateSystemWide()
        var el: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &el) == .success,
              let el, CFGetTypeID(el) == AXUIElementGetTypeID() else { return false }
        var sub: CFTypeRef?
        if AXUIElementCopyAttributeValue(el as! AXUIElement, kAXSubroleAttribute as CFString, &sub) == .success,
           let s = sub as? String, s == (kAXSecureTextFieldSubrole as String) { return true }
        return false
    }

    // The target implied by the NON-wrong (other-script) words in the selection,
    // but only when exactly one enabled layout has that script. Else nil.
    private func restTextLayout(_ text: String, cur: Layout, enabled: [Layout]) -> Layout? {
        if cur.isCyrillic {
            let restLatin = tokenize(text).contains { !($0.first?.isWhitespace ?? true) && !hasCyr($0) && hasLatin($0) }
            guard restLatin else { return nil }
            let cands = enabled.filter { !$0.isCyrillic && $0.id != cur.id }
            return cands.count == 1 ? cands[0] : nil
        } else {
            let restCyr = tokenize(text).contains { !($0.first?.isWhitespace ?? true) && hasCyr($0) }
            guard restCyr else { return nil }
            let cands = enabled.filter { $0.isCyrillic && $0.id != cur.id }
            return cands.count == 1 ? cands[0] : nil
        }
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
    // pasteboard actually changed (else nothing was selected).
    private func copySelection(_ pb: NSPasteboard) -> String? {
        let before = pb.changeCount
        postKey(CGKeyCode(kVK_ANSI_C), .maskCommand)
        usleep(120_000)
        guard pb.changeCount != before, let c = pb.string(forType: .string), !c.isEmpty else { return nil }
        dbg("read via Cmd+C: \(c.debugDescription)")
        return c
    }

    // Cmd+X (cut): reads AND removes the selection in one step. Used by the
    // clipboard fallback instead of Cmd+C — it dodges DeepL's Cmd+C-Cmd+C watcher,
    // and the converted text is typed back in its place. nil if nothing was cut.
    private func cutSelection(_ pb: NSPasteboard) -> String? {
        let before = pb.changeCount
        postKey(CGKeyCode(kVK_ANSI_X), .maskCommand)
        usleep(120_000)
        guard pb.changeCount != before, let c = pb.string(forType: .string), !c.isEmpty else { return nil }
        dbg("read via Cmd+X: \(c.debugDescription)")
        return c
    }

    func performRetype() {
        guard AXIsProcessTrusted() else {
            DispatchQueue.main.async { self.promptAccessibilityIfNeeded() }
            return
        }

        // Press-again undo: a second hotkey within undoWindow of a conversion
        // reverses it. Disabled when "Trigger on double-tap" is on — a second
        // double-tap would be ambiguous with the trigger itself.
        if hotKeyTaps == 1, let last = lastConversion,
           ProcessInfo.processInfo.systemUptime - last.time < undoWindow {
            lastConversion = nil
            performUndo(last)
            return
        }

        waitModifiersReleased()

        // The clipboard is saved/restored ONLY on the Cmd+C fallback path. The AX
        // path never touches it, so we must not clear+restore it there — doing so
        // would wipe any non-string clipboard content (images, files) on every
        // retype. clipboardSaved is set iff we actually dirtied the pasteboard.
        let pb = NSPasteboard.general
        var clipboardSaved: String?
        var clipboardTouched = false

        var sel: String?
        var removedSelection = false   // Cmd+X cut the text -> restore it if convert fails
        let ax = axSelectedText()
        if let ax {
            // AX path — never touches the clipboard (DeepL stays quiet)
            if !ax.isEmpty {
                dbg("read via AX: \(ax.debugDescription)")
                sel = ax
            } else {
                dbg("AX empty -> Shift+Cmd+Left")
                postKey(CGKeyCode(kVK_LeftArrow), [.maskShift, .maskCommand])
                usleep(120_000)
                let s = axSelectedText()
                if let s, !s.isEmpty { dbg("read via AX: \(s.debugDescription)"); sel = s }
            }
        } else {
            // AX unavailable -> clipboard fallback via Cmd+X (cut). Cut reads AND
            // removes the selection, dodges DeepL's Cmd+C-Cmd+C watcher, and lets us
            // type the result back in place. Save the prior clipboard to restore it.
            clipboardSaved = pb.string(forType: .string)
            clipboardTouched = true
            sel = cutSelection(pb)
            if sel == nil {
                dbg("no selection -> Shift+Cmd+Left")
                postKey(CGKeyCode(kVK_LeftArrow), [.maskShift, .maskCommand])
                usleep(120_000)
                sel = cutSelection(pb)
            }
            removedSelection = (sel != nil)
        }

        // convert() touches TIS APIs, which must run on the main thread (macOS 26
        // asserts otherwise). Hop to main for it.
        guard let text = sel, !text.isEmpty,
              let r = DispatchQueue.main.sync(execute: { self.convert(text) }) else {
            dbg("nothing to convert")
            if removedSelection, let cut = sel { typeUnicode(cut) }   // put back what we cut
            if clipboardTouched { restoreClipboard(clipboardSaved) }
            return
        }

        // WRITE via synthesized Unicode keystrokes (no clipboard, no paste) — the
        // active selection is replaced by the typed input, like Caramba. No copy/paste
        // events, so DeepL stays quiet. Clipboard is never used for writing.
        dbg("type: \(r.out.debugDescription)")
        typeUnicode(r.out)
        usleep(20_000)
        DispatchQueue.main.sync { _ = TISSelectInputSource(r.dst.source) }
        // restore clipboard only if the Cmd+C read fallback dirtied it
        if clipboardTouched { restoreClipboard(clipboardSaved) }
        // remember it so a quick second hotkey can undo
        lastConversion = Conversion(original: text, typed: r.out,
                                    srcSource: r.src.source,
                                    time: ProcessInfo.processInfo.systemUptime)
    }

    // Reverse the last conversion: reselect the text we just typed (Shift+Left
    // once per character, since the caret sits right after it), replace it with
    // the original, and flip the input source back to the source layout.
    private func performUndo(_ last: Conversion) {
        waitModifiersReleased()
        dbg("undo: restore \(last.original.debugDescription)")
        for _ in 0..<last.typed.count {
            postKey(CGKeyCode(kVK_LeftArrow), .maskShift)
        }
        usleep(20_000)
        typeUnicode(last.original)
        usleep(20_000)
        DispatchQueue.main.sync { _ = TISSelectInputSource(last.srcSource) }
    }

    // Insert a string by synthesizing per-character Unicode key events.
    private func typeUnicode(_ s: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for ch in s {
            let units = Array(String(ch).utf16)
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
            usleep(1500)   // small gap so slow apps don't drop characters
        }
    }

    private func restoreClipboard(_ saved: String?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let saved { pb.setString(saved, forType: .string) }
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
                ? ["ghbdtn", "я сказал ghbdtn", "я написал ßæ", "привет мир"]
                : ["руддщ", "привет мир", "I said привет"]
            for s in samples {
                print("  \(s.debugDescription) -> \(convertWrong(s, src: src, dst: dst)?.debugDescription ?? "nil")")
            }
        }
    }
}
#endif
