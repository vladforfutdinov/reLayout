import WinSDK

// Low-level keyboard-hook hotkey engine. Unlike RegisterHotKey it can use a bare
// modifier (e.g. Left Shift) as the hotkey via tap detection — press & release
// with no other key in between, like the macOS mod-tap — as well as ordinary
// combos (Ctrl+Alt+R). Detection runs inside the WH_KEYBOARD_LL hook; the actual
// conversion is posted to the main thread (WM_RETYPE) so the hook stays cheap.
//
// The hotkey is (mods, vk). If vk is itself a modifier VK and mods == 0 it's a
// modifier-tap hotkey; otherwise it's a combo.

let WM_RETYPE = UINT(WM_APP) + 10

private var llHook: HHOOK?
private var mainThreadId: DWORD = 0

private var hkMods: UINT = 0
private var hkVK: UINT = 0

// modifier-tap detection
private var tapArmed = false
private var tapArmTick: DWORD = 0
private var tapInterrupted = false
// combo: suppress auto-repeat (one fire per physical press)
private var comboFired = false

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

private func postTrigger() {
    _ = PostThreadMessageW(mainThreadId, WM_RETYPE, 0, 0)
}

private func handleDetect(_ vk: UINT, down: Bool, up: Bool) {
    guard hkVK != 0 else { return }

    if isModifierVK(hkVK) && hkMods == 0 {
        // modifier-tap mode
        if down {
            if vk == hkVK {
                if !tapArmed { tapArmed = true; tapInterrupted = false; tapArmTick = GetTickCount() }
            } else if tapArmed {
                tapInterrupted = true        // another key during the hold -> not a tap
            }
        } else if up, vk == hkVK {
            if tapArmed, !tapInterrupted, GetTickCount() &- tapArmTick < 400 { postTrigger() }
            tapArmed = false
        }
    } else {
        // combo mode (one fire per press; cleared on release)
        if down, vk == hkVK, modsHeldExact(hkMods) {
            if !comboFired { comboFired = true; postTrigger() }
        } else if up, vk == hkVK {
            comboFired = false
        }
    }
}

private func endCapture() { capturing = false; captureDone = nil; captureLive = nil }

private func handleCapture(_ vk: UINT, down: Bool, up: Bool) {
    if down {
        if !isModifierVK(vk) {
            // a real key -> combo with whatever modifiers are held
            let cb = captureDone; endCapture(); cb?(currentMods(), vk)
        } else {
            captureLive?(keyName(vk))      // live hint, e.g. "Left Shift" — just release to set it
        }
    } else if up, isModifierVK(vk) {
        // a modifier released (no real key was pressed, else we'd have finalized
        // above) -> bare-modifier hotkey. Don't test GetAsyncKeyState here: during
        // this key's own keyUP it still reports as down.
        let cb = captureDone; endCapture(); cb?(0, vk)
    }
}

// C-compatible (capture-free) hook proc.
private let llProc: HOOKPROC = { nCode, wParam, lParam in
    if nCode == 0 /* HC_ACTION */, let p = UnsafeRawPointer(bitPattern: Int(lParam)) {
        let info = p.assumingMemoryBound(to: KBDLLHOOKSTRUCT.self).pointee
        // Ignore our own synthesized input (Ctrl+C / typing) — else it would feed
        // back into detection and loop.
        if (info.flags & 0x10 /* LLKHF_INJECTED */) == 0 {
            let vk = UINT(info.vkCode)
            let m  = UINT(wParam)
            let down = (m == UINT(WM_KEYDOWN) || m == UINT(WM_SYSKEYDOWN))
            let up   = (m == UINT(WM_KEYUP)   || m == UINT(WM_SYSKEYUP))
            if capturing { handleCapture(vk, down: down, up: up) }
            else         { handleDetect(vk, down: down, up: up) }
        }
    }
    return CallNextHookEx(nil, nCode, wParam, lParam)
}

// MARK: - public API

func installHotkeyHook() {
    mainThreadId = GetCurrentThreadId()
    let hk = loadHotkey()
    hkMods = hk.mods; hkVK = hk.vk
    llHook = SetWindowsHookExW(13 /* WH_KEYBOARD_LL */, llProc, GetModuleHandleW(nil), 0)
}

func uninstallHotkeyHook() {
    if let h = llHook { UnhookWindowsHookEx(h); llHook = nil }
}

func setHotkey(_ mods: UINT, _ vk: UINT) {
    hkMods = mods; hkVK = vk
    tapArmed = false; comboFired = false
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

// Human label, e.g. "Left Shift" (modifier-tap) or "Ctrl+Alt+R" (combo).
func hotkeyLabel(_ mods: UINT, _ vk: UINT) -> String {
    if isModifierVK(vk) && mods == 0 { return keyName(vk) }
    var parts: [String] = []
    if mods & 2 != 0 { parts.append("Ctrl") }
    if mods & 1 != 0 { parts.append("Alt") }
    if mods & 4 != 0 { parts.append("Shift") }
    if mods & 8 != 0 { parts.append("Win") }
    parts.append(keyName(vk))
    return parts.joined(separator: "+")
}

// Localized key name for a virtual-key (e.g. "R", "F2", "Left Shift").
func keyName(_ vk: UINT) -> String {
    let scan = MapVirtualKeyW(vk, 0 /* MAPVK_VK_TO_VSC */)
    // L/R modifiers and a few keys need the extended bit for a correct name.
    let extended: Set<UINT> = [0xA1, 0xA3, 0xA5, 0x5B, 0x5C]   // RShift, RCtrl, RAlt, LWin, RWin
    var lparam = LONG(scan << 16)
    if extended.contains(vk) { lparam |= LONG(1 << 24) }
    var buf = [WCHAR](repeating: 0, count: 64)
    let n = GetKeyNameTextW(lparam, &buf, Int32(buf.count))
    return n > 0 ? String(decoding: buf.prefix(Int(n)), as: UTF16.self) : "?"
}
