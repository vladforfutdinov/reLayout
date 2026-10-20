import WinSDK

// Low-level keyboard-hook hotkey engine. Unlike RegisterHotKey it can use a bare
// modifier (e.g. Left Shift) as the hotkey via tap detection — press & release
// with no other key in between, like the macOS mod-tap — as well as ordinary
// combos (Ctrl+Alt+R). Detection runs inside the WH_KEYBOARD_LL hook; the actual
// conversion is posted to the main thread (WM_RETYPE) so the hook stays cheap.
//
// A hotkey is (mods, vk). If vk is itself a modifier VK and mods == 0 it's a
// modifier-tap hotkey; vk `chordVK` is a tap of the modifiers in `mods` together
// (Ctrl+Shift); otherwise it's a combo. There are two: convert, and
// auto-correct on/off, each detected by its own `HotkeyDetector`.

let WM_RETYPE = UINT(WM_APP) + 10
let WM_TOGGLE_AUTO = UINT(WM_APP) + 14

/// A recorded hotkey; `vk` 0 is unset. `doubleTap` fires it on the second press only.
struct Hotkey {
    var mods: UINT
    var vk: UINT
    var doubleTap = false

    static let none = Hotkey(mods: 0, vk: 0)
    var isSet: Bool { vk != 0 }

    /// Same keys as `other`, double tap or not: both would fire on one press.
    func clashes(with other: Hotkey) -> Bool { isSet && mods == other.mods && vk == other.vk }
}

/// The app's hotkeys; the raw value indexes `detectors`.
enum HotkeySlot: Int, CaseIterable {
    case retype, autoToggle
    var other: HotkeySlot { self == .retype ? .autoToggle : .retype }
}

private var llHook: HHOOK?
private var mainThreadId: DWORD = 0

// capture mode (recording a new hotkey from the Settings window)
private var capturing = false
private var captureDone: ((UINT, UINT) -> Void)?
private var captureLive: ((String) -> Void)?   // live hint while keys are held

// Left/right-specific and generic modifier virtual-keys.
private let modifierVKs: Set<UINT> = [0x10, 0xA0, 0xA1,   // Shift, LShift, RShift
                                      0x11, 0xA2, 0xA3,   // Ctrl,  LCtrl,  RCtrl
                                      0x12, 0xA4, 0xA5,   // Alt,   LAlt,   RAlt
                                      0x5B, 0x5C]         // LWin,  RWin
func isModifierVK(_ vk: UINT) -> Bool { modifierVKs.contains(vk) }
private let altOrWinVKs: Set<UINT> = [0x12, 0xA4, 0xA5, 0x5B, 0x5C]

/// `vk` of a modifier-chord tap: the modifiers in `mods`, pressed and released
/// together with no other key (0xFF is a reserved VK).
let chordVK: UINT = 0xFF

/// MOD_* flag of a modifier VK, 0 for any other key.
private func modFlag(_ vk: UINT) -> UINT {
    switch vk {
    case 0x10, 0xA0, 0xA1: return 4   // MOD_SHIFT
    case 0x11, 0xA2, 0xA3: return 2   // MOD_CONTROL
    case 0x12, 0xA4, 0xA5: return 1   // MOD_ALT
    case 0x5B, 0x5C: return 8         // MOD_WIN
    default: return 0
    }
}

private func keyDown(_ vk: Int32) -> Bool { (Int(GetAsyncKeyState(vk)) & 0x8000) != 0 }

// Exact modifier match (extra modifiers block the combo, like RegisterHotKey).
private func modsHeldExact(_ mods: UINT) -> Bool {
    func need(_ m: Int32) -> Bool { (mods & UINT(m)) != 0 }
    let ctrl  = keyDown(0x11)
    let alt   = keyDown(0x12)
    let shift = keyDown(0x10)
    let win   = keyDown(0x5B) || keyDown(0x5C)
    return ctrl == need(2 /*MOD_CONTROL*/) && alt == need(1 /*MOD_ALT*/)
        && shift == need(4 /*MOD_SHIFT*/) && win == need(8 /*MOD_WIN*/)
}

// Current physically-held modifiers as MOD_* flags (used while capturing a combo).
private func currentMods() -> UINT {
    var m: UINT = 0
    if keyDown(0x11) { m |= 2 }
    if keyDown(0x12) { m |= 1 }
    if keyDown(0x10) { m |= 4 }
    if keyDown(0x5B) || keyDown(0x5C) { m |= 8 }
    return m
}

/// One hotkey's detection state inside the hook.
private struct HotkeyDetector {
    let message: UINT   // posted to the main thread when the hotkey fires
    var mods: UINT = 0
    var vk: UINT = 0
    // modifier-tap detection
    var tapArmed = false
    var tapArmTick: DWORD = 0
    var tapInterrupted = false
    // combo: suppress auto-repeat (one fire per physical press)
    var comboFired = false
    // chord tap: modifiers held now, and all held during this press
    var held: UINT = 0
    var peak: UINT = 0

    init(message: UINT) { self.message = message }

    mutating func set(_ hk: Hotkey) {
        mods = hk.mods; vk = hk.vk
        tapArmed = false; comboFired = false; held = 0; peak = 0
    }

    private func fire() {
        _ = PostThreadMessageW(mainThreadId, message, 0, 0)
    }

    /// - Returns: true if the key belongs to a matched combo and must not reach the app.
    mutating func handle(_ key: UINT, down: Bool, up: Bool) -> Bool {
        guard vk != 0 else { return false }

        if vk == chordVK {
            let flag = modFlag(key)
            guard flag != 0 else {
                if down { tapInterrupted = true }   // another key during the hold -> not a tap
                return false
            }
            if down {
                if held == 0 { tapArmed = true; tapInterrupted = false; tapArmTick = GetTickCount(); peak = 0 }
                held |= flag; peak |= held
            } else if up {
                held &= ~flag
                guard held == 0, tapArmed else { return false }
                tapArmed = false
                guard !tapInterrupted, peak == mods, GetTickCount() &- tapArmTick < 600 else { return false }
                fire()
                if mods & (1 | 8) != 0 {   // Alt/Win released alone would open the menu or Start
                    sendMaskedRelease(key)
                    return true
                }
            }
            return false
        } else if isModifierVK(vk) && mods == 0 {
            // modifier-tap mode
            if down {
                if key == vk {
                    if !tapArmed { tapArmed = true; tapInterrupted = false; tapArmTick = GetTickCount() }
                } else if tapArmed {
                    tapInterrupted = true        // another key during the hold -> not a tap
                }
            } else if up, key == vk {
                defer { tapArmed = false }
                guard tapArmed, !tapInterrupted, GetTickCount() &- tapArmTick < 400 else { return false }
                fire()
                if altOrWinVKs.contains(key) {
                    sendMaskedRelease(key)
                    return true
                }
            }
            return false
        } else {
            // combo mode (one fire per press; cleared on release)
            if down, key == vk, modsHeldExact(mods) {
                if !comboFired {
                    comboFired = true
                    // Only a lone Alt opens the menu bar on release, and Win opens Start;
                    // with Ctrl held too (Ctrl+Alt+R) Alt goes up as a plain key, so no mask.
                    let alt = mods & 1 /*MOD_ALT*/ != 0, ctrl = mods & 2 /*MOD_CONTROL*/ != 0
                    if (alt && !ctrl) || mods & 8 /*MOD_WIN*/ != 0 { sendMaskKey() }
                    fire()
                }
                return true
            } else if up, key == vk {
                defer { comboFired = false }
                return comboFired
            }
            return false
        }
    }
}

private var detectors = [HotkeyDetector(message: WM_RETYPE), HotkeyDetector(message: WM_TOGGLE_AUTO)]

private var captureHeld: UINT = 0, capturePeak: UINT = 0

private func endCapture() {
    capturing = false; captureDone = nil; captureLive = nil; captureHeld = 0; capturePeak = 0
}

private func handleCapture(_ vk: UINT, down: Bool, up: Bool) {
    if down {
        if !isModifierVK(vk) {
            // a real key -> combo with whatever modifiers are held
            let cb = captureDone; endCapture(); cb?(currentMods(), vk)
        } else {
            captureHeld |= modFlag(vk); capturePeak |= captureHeld
            // live hint, e.g. "Left Shift" or "Ctrl+Shift" — just release to set it
            captureLive?(capturePeak.nonzeroBitCount > 1 ? hotkeyLabel(capturePeak, chordVK) : keyName(vk))
        }
    } else if up, isModifierVK(vk) {
        // modifiers released with no real key in between (else we'd have finalized
        // above) -> a bare-modifier hotkey, or a chord once the last one is up.
        // Don't test GetAsyncKeyState here: during this key's own keyUP it still
        // reports as down.
        captureHeld &= ~modFlag(vk)
        guard captureHeld == 0 else { return }
        let peak = capturePeak, cb = captureDone
        endCapture()
        if peak.nonzeroBitCount > 1 { cb?(peak, chordVK) } else { cb?(0, vk) }
    }
}

#if DEBUG
/// Keys the end-to-end harness (scripts/e2e/win-harness.swift) injects carry this in
/// `dwExtraInfo`; dev builds treat them as typed. Must match the harness.
let e2eKeyMarker: ULONG_PTR = 0x524C_4532
#endif

// C-compatible (capture-free) hook proc.
private let llProc: HOOKPROC = { nCode, wParam, lParam in
    if nCode == 0 /* HC_ACTION */, let p = UnsafeRawPointer(bitPattern: Int(lParam)) {
        let info = p.assumingMemoryBound(to: KBDLLHOOKSTRUCT.self).pointee
        dlogHook(vk: info.vkCode, scan: info.scanCode, flags: info.flags, message: UInt(wParam))
        // Ignore our own synthesized input (Ctrl+C / typing) — else it would feed
        // back into detection and loop.
        var typed = (info.flags & 0x10 /* LLKHF_INJECTED */) == 0
#if DEBUG
        if !typed, info.dwExtraInfo == e2eKeyMarker { typed = true }
#endif
        // Another program typed (a remapper, an on-screen keyboard, a password
        // manager): text changed that the run did not see, so it no longer matches.
        if !typed, info.dwExtraInfo != ownInputMarker,
           wParam == WPARAM(WM_KEYDOWN) || wParam == WPARAM(WM_SYSKEYDOWN) {
            resetAutoBuffer()
            forgetConversion()
        }
        if typed {
            let vk = UINT(info.vkCode)
            let m  = UINT(wParam)
            let down = (m == UINT(WM_KEYDOWN) || m == UINT(WM_SYSKEYDOWN))
            let up   = (m == UINT(WM_KEYUP)   || m == UINT(WM_SYSKEYUP))
            if capturing {
                handleCapture(vk, down: down, up: up)
                // Swallow the recorded key, not modifiers: a blocked key never
                // reaches GetAsyncKeyState, which currentMods() reads.
                if !isModifierVK(vk) { return 1 }
                return CallNextHookEx(nil, nCode, wParam, lParam)
            }
            // Every detector sees the key: a tap of one is interrupted by the other's keys.
            var matched = false
            for i in detectors.indices {
                if detectors[i].handle(vk, down: down, up: up) { matched = true }
            }
            if matched { return 1 }
            // A real key (not a modifier, which may belong to the hotkey itself)
            // ends the undo window.
            if down, !isModifierVK(vk) { forgetConversion() }
            // Auto mode watches the same keys: it corrects what it saw typed.
            if down {
                let mods = currentMods()
                let ctrl = mods & 2 != 0, alt = mods & 1 != 0, win = mods & 8 != 0
                // AltGr is Ctrl+Alt together and types characters; either alone, or
                // Win, makes the key a command.
                if autoFeed(vk: vk, scan: WORD(truncatingIfNeeded: info.scanCode),
                            shortcut: win || ctrl != alt, shift: mods & 4 != 0) {
                    return 1
                }
            }
        }
    }
    return CallNextHookEx(nil, nCode, wParam, lParam)
}

// MARK: - public API

/// Installs the low-level keyboard hook on the calling thread.
/// - Returns: false if Windows refused the hook.
func installHotkeyHook() -> Bool {
    mainThreadId = GetCurrentThreadId()
    for slot in HotkeySlot.allCases { detectors[slot.rawValue].set(loadHotkey(slot)) }
    llHook = SetWindowsHookExW(13 /* WH_KEYBOARD_LL */, llProc, GetModuleHandleW(nil), 0)
    return llHook != nil
}

func uninstallHotkeyHook() {
    if let h = llHook { UnhookWindowsHookEx(h); llHook = nil }
}

func setHotkey(_ slot: HotkeySlot, _ hk: Hotkey) {
    detectors[slot.rawValue].set(hk)
}

// Enter capture: held modifiers are reported live via `onLive`; the final
// key/combo (or a released bare modifier) is reported via `onDone`. Both run on
// the main thread.
func startHotkeyCapture(onLive: @escaping (String) -> Void,
                        onDone: @escaping (UINT, UINT) -> Void) {
    captureLive = onLive
    captureDone = onDone
    capturing = true
}

func cancelHotkeyCapture() { endCapture() }

/// The saved hotkey as shown in Settings and the tray, "×2" for a double tap.
func hotkeyDisplay(_ slot: HotkeySlot) -> String {
    let hk = loadHotkey(slot)
    guard hk.isSet else { return L("shortcut.none") }
    return hotkeyLabel(hk.mods, hk.vk) + (hk.doubleTap ? " ×2" : "")
}

// Human label, e.g. "Left Shift" (modifier-tap) or "Ctrl+Alt+R" (combo).
func hotkeyLabel(_ mods: UINT, _ vk: UINT) -> String {
    if isModifierVK(vk) && mods == 0 { return keyName(vk) }
    var parts: [String] = []
    if mods & 2 != 0 { parts.append("Ctrl") }
    if mods & 1 != 0 { parts.append("Alt") }
    if mods & 4 != 0 { parts.append("Shift") }
    if mods & 8 != 0 { parts.append("Win") }
    if vk != chordVK { parts.append(keyName(vk)) }
    return parts.joined(separator: "+")
}

// Localized key name for a virtual-key (e.g. "R", "F2", "Left Shift").
func keyName(_ vk: UINT) -> String {
    let scan = MapVirtualKeyW(vk, 0 /* MAPVK_VK_TO_VSC */)
    // Extended keys: RCtrl, RAlt, Win, Apps, navigation block, numpad Divide, NumLock.
    // RShift is not extended; without the bit, arrows read as numpad keys.
    let extended: Set<UINT> = [0xA3, 0xA5, 0x5B, 0x5C, 0x5D, 0x21, 0x22, 0x23, 0x24,
                               0x25, 0x26, 0x27, 0x28, 0x2D, 0x2E, 0x6F, 0x90]
    var lparam = LONG(scan << 16)
    if extended.contains(vk) { lparam |= LONG(1 << 24) }
    var buf = [WCHAR](repeating: 0, count: 64)
    let n = GetKeyNameTextW(lparam, &buf, Int32(buf.count))
    return n > 0 ? String(decoding: buf.prefix(Int(n)), as: UTF16.self) : "?"
}
