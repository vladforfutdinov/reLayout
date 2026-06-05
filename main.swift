import Cocoa
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Helpers

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

// MARK: - Keystroke (physical key + modifier state)

struct KeyStroke: Hashable {
    let keyCode: UInt16
    let mods: UInt32 // UCKeyTranslate modifierKeyState (carbon mods >> 8)
}

// Conversion-relevant surface of a keyboard layout. Lets the transliteration
// engine be exercised with injected fixtures (tests) instead of a live TIS source.
protocol LayoutMaps {
    var charToStroke: [String: KeyStroke] { get }
    var strokeToChar: [KeyStroke: String] { get }
    var isCyrillic: Bool { get }
}

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

func transliterate(_ text: String, from src: LayoutMaps, to dst: LayoutMaps) -> String {
    var out = ""
    for ch in text {
        let key = String(ch)
        if let stroke = src.charToStroke[key], let mapped = dst.strokeToChar[stroke] {
            out += mapped
        } else {
            out += key
        }
    }
    return out
}

private func isCyrLetter(_ u: Unicode.Scalar) -> Bool {
    (0x0400...0x04FF).contains(u.value) || (0x0500...0x052F).contains(u.value)
}

private func hasCyr(_ w: Substring) -> Bool { w.unicodeScalars.contains(where: isCyrLetter) }

private func isLatinLetter(_ u: Unicode.Scalar) -> Bool {
    let v = u.value
    if (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) { return true }
    // Latin-1 Supplement + Latin Extended-A/B letters (ä ö ü ß é …), minus × ÷
    if (0xC0...0x24F).contains(v) && v != 0xD7 && v != 0xF7 { return true }
    return false
}

private func hasLatin(_ w: Substring) -> Bool { w.unicodeScalars.contains(where: isLatinLetter) }

// A word is wrong-but-Cyrillic-target if any of its chars (which src can type) maps
// to a Cyrillic letter in dst. Catches the Option layer (ß/æ -> ы/э), neither a-z nor Cyrillic.
private func mapsToCyr(_ w: Substring, src: LayoutMaps, dst: LayoutMaps) -> Bool {
    for ch in w {
        if let st = src.charToStroke[String(ch)], let m = dst.strokeToChar[st],
           let f = m.unicodeScalars.first, isCyrLetter(f) { return true }
    }
    return false
}

// Tokenize into alternating whitespace / non-whitespace runs (order preserved).
private func tokenize(_ text: String) -> [Substring] {
    var tokens: [Substring] = []
    var i = text.startIndex
    while i < text.endIndex {
        let space = text[i].isWhitespace
        var j = i
        while j < text.endIndex, text[j].isWhitespace == space { j = text.index(after: j) }
        tokens.append(text[i..<j]); i = j
    }
    return tokens
}

// Per-word conversion. The "wrong" words are those typed in `src` (the active/wrong
// layout) — identified by script — and only those are converted to `dst`.
//   src Cyrillic -> convert words containing Cyrillic
//   src Latin    -> convert words with Latin letters (or src->dst Cyrillic-mapping, e.g. ß/æ)
// Returns nil if nothing changed.
func convertWrong(_ text: String, src: LayoutMaps, dst: LayoutMaps) -> String? {
    var acc = ""
    for t in tokenize(text) {
        if t.first?.isWhitespace ?? false { acc += t; continue }
        let wrong: Bool
        if src.isCyrillic {
            wrong = hasCyr(t)
        } else {
            wrong = !hasCyr(t) && (hasLatin(t) || mapsToCyr(t, src: src, dst: dst))
        }
        acc += wrong ? transliterate(String(t), from: src, to: dst) : String(t)
    }
    return acc == text ? nil : acc
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
    // (mode, keyCode, carbonMods, chord, display)
    var onCommit: ((HKMode, UInt32, UInt32, [UInt16], String) -> Void)?

    private var recording = false { didSet { needsDisplay = true } }
    private var monitor: Any?
    private var peak: Set<UInt16>?
    private var comboUsed = false

    init(display: String) {
        self.display = display
        super.init(frame: NSRect(x: 0, y: 0, width: 150, height: 24))
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Hotkey")
    }
    required init?(coder: NSCoder) { fatalError("ShortcutField is code-only") }

    // VoiceOver: announce the current shortcut and let activation start recording.
    override func accessibilityValue() -> Any? { recording ? "Recording" : display }
    override func accessibilityPerformPress() -> Bool { recording ? stop() : start(); return true }

    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.textBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = recording ? 2 : 1
        path.stroke()

        let text = recording ? "Type shortcut…" : display
        let color: NSColor = recording ? .secondaryLabelColor : .labelColor
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
        window?.makeFirstResponder(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] ev in
            guard let self else { return ev }
            if ev.type == .keyDown { return self.handleKeyDown(ev) }
            self.handleFlags(ev)
            return nil
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        recording = false
    }

    private func handleKeyDown(_ ev: NSEvent) -> NSEvent? {
        if ev.keyCode == UInt16(kVK_Escape) { stop(); return nil }   // cancel
        comboUsed = true
        let mods = ev.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !mods.intersection([.command, .option, .control]).isEmpty else { return nil } // need a real modifier
        let disp = comboDisplay(ev.keyCode, mods, ev.charactersIgnoringModifiers)
        commit(.carbon, UInt32(ev.keyCode), carbonModsFrom(mods), [], disp)
        return nil
    }

    private func handleFlags(_ ev: NSEvent) {
        let cur = pressedModKeys(ev.modifierFlags)
        if cur.isEmpty {
            if !comboUsed, let p = peak, !p.isEmpty {
                commit(.modTap, 0, 0, Array(p), chordDisplay(p))
            }
            peak = nil; comboUsed = false
        } else if peak == nil || cur.count > (peak?.count ?? 0) {
            peak = cur
        }
    }

    private func commit(_ mode: HKMode, _ code: UInt32, _ mods: UInt32, _ chord: [UInt16], _ disp: String) {
        display = disp
        stop()
        onCommit?(mode, code, mods, chord, disp)
    }
}

// Settings window that closes on Esc (macOS convention via cancelOperation).
final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
}

// MARK: - App controller

final class AppController: NSObject, NSApplicationDelegate {
    static let shared = AppController()

    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false

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
    private var hotKeyDisplay = "left⌥"

    // modifier-tap runtime state
    private var tapMonitors: [Any] = []
    private var tapArmed = false
    private var tapArmTime: Double = 0
    private var tapInterrupted = false

    // settings
    private var settingsWindow: NSWindow?
    private weak var shortcutField: ShortcutField?
    private weak var conflictLabel: NSTextField?
    private weak var loginCheckbox: NSButton?

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        promptAccessibilityIfNeeded()
        loadHotkey()
        installHotKeyHandler()
        applyHotkey()
        setupMenu()
        // mirror the system input-source indicator in the menu bar
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(inputSourceChanged),
                        name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
        // enabled-set change -> the cached layout list is stale; drop it and refresh
        dnc.addObserver(self, selector: #selector(enabledSourcesChanged),
                        name: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String), object: nil)
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

    // macOS renders the menu-bar input indicator itself (kTISPropertyIconImageURL is
    // empty for keyboard layouts), so we redraw the same look: a rounded box with the
    // source's native-language abbreviation (УК / РУ / A), as a template image that
    // adapts to light/dark menu bars.
    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        guard let srcRef = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
        let badge = badgeImage(abbrev(srcRef))
        // The badge is a template image with no inherent meaning to VoiceOver;
        // describe the current input source so the menu-bar item is announced.
        let name = localizedSourceName(srcRef)
        badge.accessibilityDescription = name
        button.image = badge
        button.imagePosition = .imageOnly
        button.title = ""
        button.setAccessibilityLabel("reLayout, current input source: \(name)")
    }

    private func localizedSourceName(_ src: TISInputSource) -> String {
        if let p = TISGetInputSourceProperty(src, kTISPropertyLocalizedName) {
            return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
        }
        return abbrev(src)
    }

    private func abbrev(_ src: TISInputSource) -> String {
        if let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) {
            let id = Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
            if id.contains(".ABC") { return "A" }
        }
        // native-language two-letter abbreviation, e.g. uk -> "УК", ru -> "РУ"
        if let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages),
           let langs = Unmanaged<CFArray>.fromOpaque(p).takeUnretainedValue() as? [String],
           let l0 = langs.first,
           let nm = Locale(identifier: l0).localizedString(forLanguageCode: l0), !nm.isEmpty {
            return String(nm.prefix(2)).uppercased()
        }
        if let p = TISGetInputSourceProperty(src, kTISPropertyLocalizedName) {
            let name = Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
            return String(name.prefix(2)).uppercased()
        }
        return "⇄"
    }

    private func badgeImage(_ text: String) -> NSImage {
        // Latin abbreviation (ABC / EN) -> filled light keycap with dark glyph, like
        // macOS. Cyrillic (УК / РУ) -> outlined box, template (adapts to menu bar).
        let filled = !text.unicodeScalars.contains { isCyrLetter($0) }
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let tsize = (text as NSString).size(withAttributes: attrs)

        // single fixed canvas + fixed box for every layout -> constant menu-bar slot
        let canvas = NSSize(width: 25, height: 16)
        let r: CGFloat = 5
        let img = NSImage(size: canvas)
        img.lockFocus()
        let box = NSRect(x: 1, y: 0, width: canvas.width - 2, height: canvas.height)
        let pt = NSPoint(x: (canvas.width - tsize.width) / 2, y: (canvas.height - tsize.height) / 2)
        // Both are TEMPLATE images so the menu bar tints + dims them like its own
        // items (inactive display, dark/light). filled = solid box with the glyph
        // KNOCKED OUT (transparent), outline = a ring with the glyph drawn.
        if filled {
            let p = NSBezierPath(roundedRect: box, xRadius: r, yRadius: r)
            NSColor.black.setFill(); p.fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            (text as NSString).draw(at: pt, withAttributes: attrs)
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        } else {
            let outer = NSBezierPath(roundedRect: box, xRadius: r, yRadius: r)
            let inner = NSBezierPath(roundedRect: box.insetBy(dx: 1, dy: 1), xRadius: r - 1, yRadius: r - 1)
            outer.append(inner.reversed)
            outer.windingRule = .evenOdd
            NSColor.black.setFill(); outer.fill()
            (text as NSString).draw(at: pt, withAttributes: attrs)
        }
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    // MARK: menu

    private func setupMenu() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            updateStatusIcon()
        }
        let menu = NSMenu()
        let info = NSMenuItem(title: layoutInfoTitle(), action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "About reLayout", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openReLayoutSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Keyboard Settings…", action: #selector(openKeyboardSettings), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit reLayout", action: #selector(quit), keyEquivalent: "q"))
        for it in menu.items where it.action != nil { it.target = self }
        statusItem.menu = menu
    }

    private func layoutInfoTitle() -> String {
        let names = Layout.enabledList().map {
            $0.id.replacingOccurrences(of: "com.apple.keylayout.", with: "")
        }
        let list = names.isEmpty ? "—" : names.joined(separator: " · ")
        return "\(list) [ \(hotKeyDisplay) ]"
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // Standard macOS About panel. Name/version/icon/copyright come from Info.plist
    // (CFBundleName, CFBundleShortVersionString, CFBundleVersion,
    // NSHumanReadableCopyright); we add the project link as clickable credits.
    @objc private func showAbout() {
        activateApp()
        let credits = NSAttributedString(
            string: "github.com/vladforfutdinov/reLayout",
            attributes: [
                .link: URL(string: "https://github.com/vladforfutdinov/reLayout") as Any,
                .font: NSFont.systemFont(ofSize: 11),
            ])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func openKeyboardSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.keyboard",
        ]
        for s in candidates {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }

    private func reportMissingLayouts() {
        let a = NSAlert()
        a.messageText = "reLayout: need at least 2 keyboard layouts"
        a.informativeText = "Add a second input source in System Settings ▸ Keyboard ▸ Input Sources."
        a.runModal()
    }

    private func promptAccessibilityIfNeeded() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: hotkey

    private func installHotKeyHandler() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let ih = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            dbg("hotkey fired")
            AppController.shared.worker.async { AppController.shared.performRetype() }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = (ih == noErr)
        dbg("InstallEventHandler status=\(ih)")
    }

    // Tear down whatever is active, then install the current mode.
    private func applyHotkey() {
        if let r = hotKeyRef { UnregisterEventHotKey(r); hotKeyRef = nil }
        for m in tapMonitors { NSEvent.removeMonitor(m) }
        tapMonitors.removeAll()
        tapArmed = false

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

    // Fire when exactly the configured set of modifier keys is tapped together
    // (pressed as a chord, then fully released) with no symbol key / mouse between.
    private func setupTapMonitors() {
        let onFlags: (NSEvent) -> Void = { [weak self] in self?.handleTapFlags($0) }
        let onOther: (NSEvent) -> Void = { [weak self] _ in self?.tapInterrupted = true; self?.tapArmed = false }
        let busy: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged], handler: onFlags) { tapMonitors.append(g) }
        if let gk = NSEvent.addGlobalMonitorForEvents(matching: busy, handler: onOther) { tapMonitors.append(gk) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged], handler: { onFlags($0); return $0 }) { tapMonitors.append(l) }
        if let lk = NSEvent.addLocalMonitorForEvents(matching: busy, handler: { onOther($0); return $0 }) { tapMonitors.append(lk) }
    }

    private func handleTapFlags(_ ev: NSEvent) {
        let target = Set(hotKeyChord)
        guard !target.isEmpty else { return }
        let cur = pressedModKeys(ev.modifierFlags)
        if cur == target {
            tapArmed = true; tapArmTime = ProcessInfo.processInfo.systemUptime; tapInterrupted = false
        } else if cur.isEmpty {
            if tapArmed, !tapInterrupted,
               ProcessInfo.processInfo.systemUptime - tapArmTime < 0.6 {
                tapArmed = false
                worker.async { self.performRetype() }
            }
            tapArmed = false
        } else if !cur.isSubset(of: target) {
            tapArmed = false   // an extra modifier outside the set -> cancel
        }
        // a strict subset = chord still building up or partially released -> wait
    }

    // MARK: hotkey persistence

    private func loadHotkey() {
        let d = UserDefaults.standard
        guard d.object(forKey: "hkType") != nil else { return } // keep defaults
        hotKeyMode = HKMode(rawValue: d.integer(forKey: "hkType")) ?? .carbon
        hotKeyCode = UInt32(d.integer(forKey: "hkCode"))
        hotKeyMods = UInt32(d.integer(forKey: "hkMods"))
        hotKeyChord = (d.array(forKey: "hkChord") as? [Int])?.map { UInt16($0) } ?? []
        hotKeyDisplay = d.string(forKey: "hkDisplay") ?? hotKeyDisplay
    }

    private func saveHotkey(mode: HKMode, code: UInt32, mods: UInt32, chord: [UInt16], display: String) {
        hotKeyMode = mode; hotKeyCode = code; hotKeyMods = mods; hotKeyChord = chord; hotKeyDisplay = display
        let d = UserDefaults.standard
        d.set(mode.rawValue, forKey: "hkType")
        d.set(Int(code), forKey: "hkCode")
        d.set(Int(mods), forKey: "hkMods")
        d.set(chord.map { Int($0) }, forKey: "hkChord")
        d.set(display, forKey: "hkDisplay")
    }

    // default hotkey: tap left Option
    private static let defaultHotkey: (HKMode, UInt32, UInt32, [UInt16], String) =
        (.modTap, UInt32(kVK_ANSI_R), UInt32(controlKey | optionKey), [UInt16(kVK_Option)], "left ⌥")

    @objc private func resetHotkey() {
        let d = AppController.defaultHotkey
        commitHotkey(d.0, d.1, d.2, d.3, d.4)
        shortcutField?.display = d.4
    }

    // Commit a hotkey captured by the ShortcutField.
    private func commitHotkey(_ mode: HKMode, _ code: UInt32, _ mods: UInt32, _ chord: [UInt16], _ display: String) {
        saveHotkey(mode: mode, code: code, mods: mods, chord: chord, display: display)
        applyHotkey()
        setupMenu()
        let warn = mode == .carbon ? systemHotkeyConflict(keyCode: UInt16(code), cocoaMods: cocoaMods(mods)) : nil
        conflictLabel?.stringValue = warn.map { "⚠︎ also used by \($0)" } ?? ""
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

    @objc private func openReLayoutSettings() {
        if let w = settingsWindow {
            activateApp()
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "reLayout Settings"
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
        field.onCommit = { [weak self] mode, code, mods, chord, disp in
            self?.commitHotkey(mode, code, mods, chord, disp)
        }
        shortcutField = field
        let resetIcon = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Restore default")
        let reset = NSButton(image: resetIcon ?? NSImage(), target: self, action: #selector(resetHotkey))
        reset.isBordered = false
        reset.bezelStyle = .accessoryBar
        reset.imageScaling = .scaleProportionallyDown
        reset.toolTip = "Restore default (left ⌥)"
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
            conflict.stringValue = "⚠︎ also used by \(w)"
        }

        let cb = NSButton(checkboxWithTitle: "Open at login", target: self, action: #selector(toggleLogin))
        cb.state = loginEnabled() ? .on : .off
        loginCheckbox = cb

        let layouts = NSTextField(labelWithString: layoutListText())
        layouts.textColor = .secondaryLabelColor

        let grid = NSGridView(views: [
            [caption(""), cb],
            [caption("Layouts:"), layouts],
            [caption("Hotkey:"), hkRow],
            [NSGridCell.emptyContentView, conflict],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .none
        for i in 0..<grid.numberOfRows { grid.row(at: i).yPlacement = .center }
        grid.row(at: 3).topPadding = 0   // tuck conflict under the field
        grid.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        content.layoutSubtreeIfNeeded()
        w.setContentSize(content.fittingSize)
        w.center()

        settingsWindow = w
        activateApp()
        w.makeKeyAndOrderFront(nil)
    }

    private func layoutListText() -> String {
        let names = Layout.enabledList().map { $0.id.replacingOccurrences(of: "com.apple.keylayout.", with: "") }
        return names.isEmpty ? "—" : names.joined(separator: " · ")
    }

    @objc private func toggleLogin() {
        setLogin(loginCheckbox?.state == .on)
        loginCheckbox?.state = loginEnabled() ? .on : .off   // reflect real state
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
            a.messageText = "Couldn't change the login item"
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

    private func postKey(_ keyCode: CGKeyCode, _ flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // Source = current (wrong) layout. Target chosen by:
    //   - 2 enabled       -> the other one
    //   - >2, cur != #0   -> #0 (first)
    //   - >2, cur == #0   -> layout of the OTHER-script words if uniquely determinable,
    //                        else #1 (second)
    private func convert(_ text: String) -> (out: String, dst: Layout)? {
        let enabled = Layout.enabledList()
        guard enabled.count >= 2 else { return nil }
        let curID = currentSourceID()
        guard let curIdx = enabled.firstIndex(where: { $0.id == curID }) else { return nil }
        let cur = enabled[curIdx]

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
        return (out, target)
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

    func performRetype() {
        guard AXIsProcessTrusted() else {
            DispatchQueue.main.async { self.promptAccessibilityIfNeeded() }
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
            // AX unavailable -> clipboard fallback (Cmd+C), which overwrites the
            // pasteboard; remember the prior string so we can put it back.
            clipboardSaved = pb.string(forType: .string)
            clipboardTouched = true
            sel = copySelection(pb)
            if sel == nil {
                dbg("no selection -> Shift+Cmd+Left")
                postKey(CGKeyCode(kVK_LeftArrow), [.maskShift, .maskCommand])
                usleep(120_000)
                sel = copySelection(pb)
            }
        }

        // convert() touches TIS APIs, which must run on the main thread (macOS 26
        // asserts otherwise). Hop to main for it.
        guard let text = sel, !text.isEmpty,
              let r = DispatchQueue.main.sync(execute: { self.convert(text) }) else {
            dbg("nothing to convert")
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
    }

    // Insert a string by synthesizing per-character Unicode key events.
    private func typeUnicode(_ s: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for ch in s {
            let units = Array(String(ch).utf16)
            if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
                down.flags = []
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                down.post(tap: .cgSessionEventTap)
            }
            if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                up.flags = []
                up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
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
