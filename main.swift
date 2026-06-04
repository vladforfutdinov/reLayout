import Cocoa
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Helpers

let dbgPath = "/tmp/relayout.log"
func dbg(_ s: String) {
    let line = s + "\n"
    if let h = FileHandle(forWritingAtPath: dbgPath) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else {
        try? line.data(using: .utf8)!.write(to: URL(fileURLWithPath: dbgPath))
    }
}

func fourCharCode(_ s: String) -> FourCharCode {
    var r: FourCharCode = 0
    for b in s.utf8.prefix(4) { r = (r << 8) + FourCharCode(b) }
    return r
}

func hasCyrillic(_ s: String) -> Bool {
    for u in s.unicodeScalars where (0x0400...0x04FF).contains(u.value) || (0x0500...0x052F).contains(u.value) {
        return true
    }
    return false
}

// MARK: - Keystroke (physical key + modifier state)

struct KeyStroke: Hashable {
    let keyCode: UInt16
    let mods: UInt32 // UCKeyTranslate modifierKeyState (carbon mods >> 8)
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

final class Layout {
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
    static func enabledList() -> [Layout] {
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
        guard let listPtr = TISCreateInputSourceList(filter, false)?.takeRetainedValue() else { return [] }
        var out: [Layout] = []
        for i in 0..<CFArrayGetCount(listPtr) {
            let raw = CFArrayGetValueAtIndex(listPtr, i)!
            let src = Unmanaged<TISInputSource>.fromOpaque(raw).takeUnretainedValue()
            if let l = Layout(src) { out.append(l) }
        }
        return out
    }

    // Prefer the user's ENABLED layout (added in System Settings), exact id over
    // substring, before falling back to any installed layout.
    static func find(idContains needles: [String]) -> Layout? {
        // pass 1: enabled only (includeAllInstalled = false)
        if let l = scan(needles, includeAllInstalled: false) { return l }
        // pass 2: anything installed
        return scan(needles, includeAllInstalled: true)
    }

    private static func scan(_ needles: [String], includeAllInstalled: Bool) -> Layout? {
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
        guard let listPtr = TISCreateInputSourceList(filter, includeAllInstalled)?.takeRetainedValue() else { return nil }
        var sources: [(id: String, src: TISInputSource)] = []
        for i in 0..<CFArrayGetCount(listPtr) {
            let raw = CFArrayGetValueAtIndex(listPtr, i)!
            let src = Unmanaged<TISInputSource>.fromOpaque(raw).takeUnretainedValue()
            guard let idPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { continue }
            let sid = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
            sources.append((sid, src))
        }
        // exact match first
        for n in needles {
            if let hit = sources.first(where: { $0.id == n }), let l = Layout(hit.src) { return l }
        }
        // then substring
        for n in needles {
            if let hit = sources.first(where: { $0.id.contains(n) }), let l = Layout(hit.src) { return l }
        }
        return nil
    }

    static func allKeyboardLayoutIDs() -> [String] {
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
        guard let listPtr = TISCreateInputSourceList(filter, true)?.takeRetainedValue() else { return [] }
        var out: [String] = []
        for i in 0..<CFArrayGetCount(listPtr) {
            let raw = CFArrayGetValueAtIndex(listPtr, i)!
            let src = Unmanaged<TISInputSource>.fromOpaque(raw).takeUnretainedValue()
            if let idPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) {
                out.append(Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String)
            }
        }
        return out
    }
}

func transliterate(_ text: String, from src: Layout, to dst: Layout) -> String {
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
private func mapsToCyr(_ w: Substring, src: Layout, dst: Layout) -> Bool {
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
func convertWrong(_ text: String, src: Layout, dst: Layout) -> String? {
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

// MARK: - App controller

final class AppController: NSObject, NSApplicationDelegate {
    static let shared = AppController()

    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false
    private let worker = DispatchQueue(label: "relayout.worker")

    // user-configurable hotkey (persisted in UserDefaults)
    private enum HKMode: Int { case carbon = 0, modTap = 1 }
    private var hotKeyMode: HKMode = .carbon
    private var hotKeyCode = UInt32(kVK_ANSI_R)   // carbon: virtual key
    private var hotKeyMods = UInt32(controlKey | optionKey)
    private var hotKeyChord: [UInt16] = []        // modTap: set of modifier virtual keys
    private var hotKeyDisplay = "⌃⌥R"

    // modifier-tap runtime state
    private var tapMonitors: [Any] = []
    private var tapArmed = false
    private var tapArmTime: Double = 0
    private var tapInterrupted = false

    // settings
    private var settingsWindow: NSWindow?
    private weak var settingsHotkeyLabel: NSTextField?
    private weak var loginCheckbox: NSButton?

    // recorder
    private var recorderWindow: NSWindow?
    private var recorderIsSheet = false
    private var recorderMonitor: Any?
    private var pendingMode: HKMode = .carbon
    private var pendingCode: UInt32?
    private var pendingMods: UInt32 = 0
    private var pendingChord: [UInt16] = []
    private var pendingDisplay = ""
    private var recPeak: Set<UInt16>?
    private var recComboUsed = false
    private weak var recorderLabel: NSTextField?
    private weak var recorderSaveButton: NSButton?

    func applicationDidFinishLaunching(_ note: Notification) {
        promptAccessibilityIfNeeded()
        loadHotkey()
        installHotKeyHandler()
        applyHotkey()
        setupMenu()
        // mirror the system input-source indicator in the menu bar
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(inputSourceChanged),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
        updateStatusIcon()
        if Layout.enabledList().count < 2 { reportMissingLayouts() }
    }

    @objc private func inputSourceChanged() {
        DispatchQueue.main.async { self.updateStatusIcon() }
    }

    // macOS renders the menu-bar input indicator itself (kTISPropertyIconImageURL is
    // empty for keyboard layouts), so we redraw the same look: a rounded box with the
    // source's native-language abbreviation (УК / РУ / A), as a template image that
    // adapts to light/dark menu bars.
    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        guard let srcRef = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
        button.image = badgeImage(abbrev(srcRef))
        button.imagePosition = .imageOnly
        button.title = ""
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
        // menu.addItem(NSMenuItem(title: "Retype selection [\(hotKeyDisplay))", action: #selector(retypeMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openReLayoutSettings), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Keyboard Settings…", action: #selector(openKeyboardSettings), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ReLayout", action: #selector(quit), keyEquivalent: "q"))
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

    @objc private func retypeMenu() { worker.async { self.performRetype() } }
    @objc private func quit() { NSApp.terminate(nil) }

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
        a.messageText = "ReLayout: need at least 2 keyboard layouts"
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

    // Which modifier KEYS are currently down, distinguishing left/right via the
    // device-dependent bits in modifierFlags.rawValue (the .option/.shift/… masks
    // are shared by both sides and can't tell L from R).
    private func pressedModKeys(_ f: NSEvent.ModifierFlags) -> Set<UInt16> {
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

    // MARK: hotkey persistence + recorder

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

    private func carbonMods(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option)  { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift)   { m |= UInt32(shiftKey) }
        return m
    }

    private func displayString(_ code: UInt16, _ f: NSEvent.ModifierFlags, _ chars: String?) -> String {
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option)  { s += "⌥" }
        if f.contains(.shift)   { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        return s + keyName(code, chars)
    }

    private func modKeyLabel(_ kc: UInt16) -> String {
        let sym: String
        switch Int(kc) {
        case kVK_Option, kVK_RightOption:   sym = "⌥"
        case kVK_Control, kVK_RightControl: sym = "⌃"
        case kVK_Command, kVK_RightCommand: sym = "⌘"
        case kVK_Shift, kVK_RightShift:     sym = "⇧"
        default:                            sym = "?"
        }
        let right = [kVK_RightOption, kVK_RightControl, kVK_RightCommand, kVK_RightShift].contains(Int(kc))
        return "\(right ? "right" : "left")\(sym)"
    }

    private func chordDisplay(_ set: Set<UInt16>) -> String {
        let parts = set.sorted().map { modKeyLabel($0) }
        return parts.joined(separator: "+")
    }

    private func keyName(_ code: UInt16, _ chars: String?) -> String {
        switch Int(code) {
        case kVK_Space:        return "Space"
        case kVK_Return:       return "↩"
        case kVK_Tab:          return "⇥"
        case kVK_Delete:       return "⌫"
        case kVK_Escape:       return "⎋"
        case kVK_F1:  return "F1";  case kVK_F2:  return "F2";  case kVK_F3:  return "F3"
        case kVK_F4:  return "F4";  case kVK_F5:  return "F5";  case kVK_F6:  return "F6"
        case kVK_F7:  return "F7";  case kVK_F8:  return "F8";  case kVK_F9:  return "F9"
        case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
        case kVK_LeftArrow: return "←"; case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"; case kVK_DownArrow: return "↓"
        default:
            if let c = chars, !c.isEmpty, c != " " { return c.uppercased() }
            return "key\(code)"
        }
    }

    @objc private func changeHotkey() {
        if recorderWindow != nil { recorderWindow?.makeKeyAndOrderFront(nil); return }
        pendingCode = nil
        pendingChord = []
        recPeak = nil
        recComboUsed = false
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 160),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "ReLayout — set hotkey"
        w.center()
        w.isReleasedWhenClosed = false

        let label = NSTextField(labelWithString: "Current: \(hotKeyDisplay)\nPress a shortcut, or tap modifier(s) together")
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.font = .systemFont(ofSize: 13)
        label.frame = NSRect(x: 20, y: 70, width: 340, height: 64)
        w.contentView?.addSubview(label)
        recorderLabel = label

        let save = NSButton(title: "Save", target: self, action: #selector(saveRecorded))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.frame = NSRect(x: 270, y: 18, width: 90, height: 32)
        save.isEnabled = false
        w.contentView?.addSubview(save)
        recorderSaveButton = save

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelRecorder))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}" // Esc
        cancel.frame = NSRect(x: 20, y: 18, width: 90, height: 32)
        w.contentView?.addSubview(cancel)

        recorderWindow = w
        if let sw = settingsWindow, sw.isVisible {
            recorderIsSheet = true
            sw.beginSheet(w, completionHandler: nil)
        } else {
            recorderIsSheet = false
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        }

        recorderMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] ev in
            guard let self else { return ev }
            if ev.type == .keyDown { return self.recordKeyDown(ev) }
            self.recordFlags(ev)
            return nil
        }
    }

    // Normal key + modifier(s) -> carbon combo.
    private func recordKeyDown(_ ev: NSEvent) -> NSEvent? {
        // let Return/Esc drive the buttons
        if ev.keyCode == UInt16(kVK_Return) || ev.keyCode == UInt16(kVK_Escape) { return ev }
        recComboUsed = true
        let mods = ev.modifierFlags.intersection([.command, .option, .control, .shift])
        if mods.intersection([.command, .option, .control]).isEmpty {
            recorderLabel?.stringValue = "Need ⌘, ⌥ or ⌃ — or tap modifier(s) alone"
            return nil
        }
        setPendingCarbon(code: UInt32(ev.keyCode), mods: carbonMods(mods), cocoaMods: mods.rawValue,
                         display: displayString(ev.keyCode, mods, ev.charactersIgnoringModifiers))
        return nil
    }

    // Modifier-only chord: capture the largest simultaneous set of modifier keys,
    // commit on full release (if no symbol key was used).
    private func recordFlags(_ ev: NSEvent) {
        let cur = pressedModKeys(ev.modifierFlags)
        if cur.isEmpty {
            if !recComboUsed, let p = recPeak, !p.isEmpty {
                setPendingChord(p)
            }
            recPeak = nil
            recComboUsed = false
        } else if recPeak == nil || cur.count > (recPeak?.count ?? 0) {
            recPeak = cur
        }
    }

    // Normal key + modifier(s) -> carbon combo.
    private func setPendingCarbon(code: UInt32, mods: UInt32, cocoaMods: UInt, display: String) {
        pendingMode = .carbon; pendingCode = code; pendingMods = mods; pendingChord = []
        showPending(display, warn: systemHotkeyConflict(keyCode: UInt16(code), cocoaMods: cocoaMods))
    }

    private func setPendingChord(_ set: Set<UInt16>) {
        pendingMode = .modTap; pendingCode = nil; pendingMods = 0
        pendingChord = Array(set)
        showPending(chordDisplay(set))
    }

    private func showPending(_ display: String, warn: String? = nil) {
        pendingDisplay = display
        if let warn {
            recorderLabel?.font = .systemFont(ofSize: 15)
            recorderLabel?.stringValue = "\(display)\n⚠︎ conflicts with \(warn) — Save to override"
        } else {
            recorderLabel?.font = .boldSystemFont(ofSize: 22)
            recorderLabel?.stringValue = display
        }
        recorderSaveButton?.isEnabled = true   // warn, don't block
    }

    // Look up a key+modifier combo in macOS's symbolic hotkeys (System Settings ▸
    // Keyboard ▸ Shortcuts). Returns a human name if the combo is already taken.
    private func systemHotkeyConflict(keyCode: UInt16, cocoaMods: UInt) -> String? {
        guard let d = UserDefaults(suiteName: "com.apple.symbolichotkeys"),
              let map = d.dictionary(forKey: "AppleSymbolicHotKeys") else { return nil }
        let MASK: UInt = 0x10_0000 | 0x08_0000 | 0x04_0000 | 0x02_0000 // cmd|opt|ctrl|shift
        let want = cocoaMods & MASK
        for (idStr, raw) in map {
            guard let entry = raw as? [String: Any],
                  (entry["enabled"] as? Bool) == true,
                  let value = entry["value"] as? [String: Any],
                  let params = value["parameters"] as? [Any], params.count >= 3,
                  let kc = (params[1] as? NSNumber)?.intValue,
                  let mm = (params[2] as? NSNumber)?.intValue, kc >= 0 else { continue }
            if kc == Int(keyCode), UInt(mm) & MASK == want {
                return symbolicHotkeyName(Int(idStr) ?? -1)
            }
        }
        return nil
    }

    private func symbolicHotkeyName(_ id: Int) -> String {
        let names: [Int: String] = [
            7: "macOS: focus menu bar", 8: "macOS: focus Dock",
            9: "macOS: focus next window", 10: "macOS: focus toolbar",
            11: "macOS: focus floating window", 27: "macOS: focus next window",
            32: "Mission Control", 33: "Mission Control: app windows",
            36: "macOS: show Desktop", 52: "macOS: zoom toggle",
            57: "macOS: invert colors",
            60: "macOS: select previous input source",
            61: "macOS: select next input source",
            64: "Spotlight search", 65: "Finder search window",
            79: "macOS: move left a space", 81: "macOS: move right a space",
            28: "Screenshot ▸ save to file", 29: "Screenshot ▸ copy to clipboard",
            30: "Screenshot ▸ area to file", 31: "Screenshot ▸ area to clipboard",
            184: "Screenshot & recording options",
            162: "Launchpad", 163: "Notification Center", 175: "Notification Center",
            222: "macOS: dictation",
        ]
        return names[id] ?? "a macOS keyboard shortcut (#\(id))"
    }

    @objc private func saveRecorded() {
        let valid = (pendingMode == .carbon && pendingCode != nil)
            || (pendingMode == .modTap && !pendingChord.isEmpty)
        guard valid else { return }
        saveHotkey(mode: pendingMode, code: pendingCode ?? 0, mods: pendingMods,
                   chord: pendingChord, display: pendingDisplay)
        applyHotkey()
        setupMenu()
        settingsHotkeyLabel?.stringValue = hotKeyDisplay
        closeRecorder()
    }

    @objc private func cancelRecorder() { closeRecorder() }

    private func closeRecorder() {
        if let m = recorderMonitor { NSEvent.removeMonitor(m); recorderMonitor = nil }
        pendingCode = nil
        recPeak = nil
        recComboUsed = false
        if let w = recorderWindow {
            if recorderIsSheet, let sw = settingsWindow { sw.endSheet(w) } else { w.close() }
        }
        recorderWindow = nil
        recorderIsSheet = false
    }

    // MARK: settings window

    @objc private func openReLayoutSettings() {
        if let w = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 250),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "ReLayout Settings"
        w.center()
        w.isReleasedWhenClosed = false
        let v = w.contentView!

        func label(_ s: String, _ frame: NSRect, bold: Bool = false, size: CGFloat = 13) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.frame = frame
            l.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
            l.textColor = bold ? .secondaryLabelColor : .labelColor
            v.addSubview(l)
            return l
        }

        _ = label("HOTKEY", NSRect(x: 20, y: 200, width: 200, height: 18), bold: true, size: 11)
        let hk = label(hotKeyDisplay, NSRect(x: 20, y: 168, width: 280, height: 26), size: 18)
        settingsHotkeyLabel = hk
        let change = NSButton(title: "Change…", target: self, action: #selector(changeHotkey))
        change.bezelStyle = .rounded
        change.frame = NSRect(x: 318, y: 168, width: 102, height: 28)
        v.addSubview(change)

        _ = label("STARTUP", NSRect(x: 20, y: 124, width: 200, height: 18), bold: true, size: 11)
        let cb = NSButton(checkboxWithTitle: "Open ReLayout at login", target: self, action: #selector(toggleLogin))
        cb.frame = NSRect(x: 20, y: 98, width: 320, height: 22)
        cb.state = loginEnabled() ? .on : .off
        v.addSubview(cb)
        loginCheckbox = cb

        _ = label("LAYOUTS", NSRect(x: 20, y: 56, width: 200, height: 18), bold: true, size: 11)
        _ = label(layoutInfoTitle(), NSRect(x: 20, y: 28, width: 290, height: 20), size: 13)

        // Esc / ⏎ closes the window
        let close = NSButton(title: "Close", target: self, action: #selector(closeSettings))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"   // Esc
        close.frame = NSRect(x: 330, y: 14, width: 90, height: 30)
        v.addSubview(close)

        settingsWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    @objc private func closeSettings() { settingsWindow?.close() }

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
              let appVal else { return nil }
        let app = appVal as! AXUIElement
        var elVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &elVal) == .success,
              let elVal else { return nil }
        let el = elVal as! AXUIElement
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

        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)

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
            // AX unavailable -> clipboard fallback (Cmd+C)
            sel = copySelection(pb)
            if sel == nil {
                dbg("no selection -> Shift+Cmd+Left")
                postKey(CGKeyCode(kVK_LeftArrow), [.maskShift, .maskCommand])
                usleep(120_000)
                sel = copySelection(pb)
            }
        }

        guard let text = sel, !text.isEmpty, let r = convert(text) else {
            dbg("nothing to convert")
            restoreClipboard(saved)
            return
        }

        // WRITE via synthesized Unicode keystrokes (no clipboard, no paste) — the
        // active selection is replaced by the typed input, like Caramba. No copy/paste
        // events, so DeepL stays quiet. Clipboard is never used for writing.
        dbg("type: \(r.out.debugDescription)")
        typeUnicode(r.out)
        usleep(20_000)
        TISSelectInputSource(r.dst.source)
        // restore clipboard only if the Cmd+C read fallback dirtied it
        restoreClipboard(saved)
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

// MARK: - selftest (no GUI)

if CommandLine.arguments.contains("--enabled") {
    print("ENABLED keyboard sources, in TISCreateInputSourceList(nil,false) order:")
    let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
    if let listPtr = TISCreateInputSourceList(filter, false)?.takeRetainedValue() {
        for i in 0..<CFArrayGetCount(listPtr) {
            let raw = CFArrayGetValueAtIndex(listPtr, i)!
            let src = Unmanaged<TISInputSource>.fromOpaque(raw).takeUnretainedValue()
            let idP = TISGetInputSourceProperty(src, kTISPropertyInputSourceID)
            let nmP = TISGetInputSourceProperty(src, kTISPropertyLocalizedName)
            let id = idP.map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? "?"
            let nm = nmP.map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? "?"
            print("  [\(i)] \(nm)  —  \(id)")
        }
    }
    exit(0)
}

if CommandLine.arguments.contains("--selftest") {
    func short(_ l: Layout) -> String { l.id.replacingOccurrences(of: "com.apple.keylayout.", with: "") }
    let enabled = Layout.enabledList()
    print("enabled:", enabled.map { "\(short($0))\($0.isCyrillic ? "(cyr)" : "")" }.joined(separator: ", "))
    let byId = Dictionary(uniqueKeysWithValues: enabled.map { ($0.id, $0) })
    let ukr = byId.values.first { $0.isCyrillic }
    let abc = byId["com.apple.keylayout.ABC"]
    if let ukr, let abc {
        let pairs: [(String, Layout, Layout)] = [
            ("ABC->UKR", abc, ukr),
            ("UKR->ABC", ukr, abc),
        ]
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
    exit(0)
}

// MARK: - main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.delegate = AppController.shared
app.run()
