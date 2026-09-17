import WinSDK
import ReLayoutCore

// Win32 input glue: read the selection (clipboard via Ctrl+C), write text
// (SendInput Unicode), and switch the foreground layout.

private func keyEvent(vk: WORD, scan: WORD, flags: DWORD) -> INPUT {
    var i = INPUT()
    i.type = DWORD(INPUT_KEYBOARD)
    i.ki = KEYBDINPUT(wVk: vk, wScan: scan, dwFlags: flags, time: 0, dwExtraInfo: 0)
    return i
}

// Real key event: hardware scan code, extended bit where the key needs it (else
// Home reads as numpad 7 and NumLock breaks Shift+Home).
private func vkEvent(_ vk: Int32, up: Bool = false) -> INPUT {
    let scan = WORD(truncatingIfNeeded: MapVirtualKeyW(UINT(vk), 0 /* MAPVK_VK_TO_VSC */))
    var flags: DWORD = up ? DWORD(KEYEVENTF_KEYUP) : 0
    if [VK_HOME, VK_END, VK_LEFT, VK_RIGHT].contains(vk) { flags |= DWORD(KEYEVENTF_EXTENDEDKEY) }
    return keyEvent(vk: WORD(vk), scan: scan, flags: flags)
}

@discardableResult
private func send(_ inputs: [INPUT]) -> Bool {
    var arr = inputs
    // Fewer events than asked = blocked (UIPI: elevated foreground window).
    return SendInput(UINT(arr.count), &arr, Int32(MemoryLayout<INPUT>.size)) == UINT(arr.count)
}

private func tap(_ vk: Int32, with mod: Int32) -> [INPUT] {
    [vkEvent(mod), vkEvent(vk), vkEvent(vk, up: true), vkEvent(mod, up: true)]
}

/// Waits `ms` while still dispatching the low-level hook, which runs on this thread:
/// a plain `Sleep` stalls every key (our own Ctrl+C too) and Windows drops a hook
/// that keeps timing out.
func pumpWait(_ ms: DWORD) {
    let start = GetTickCount()
    var msg = MSG()
    while true {
        let elapsed = GetTickCount() &- start
        guard elapsed < ms else { return }
        _ = MsgWaitForMultipleObjects(0, nil, false, ms - elapsed, 0x04FF /* QS_ALLINPUT */)
        _ = PeekMessageW(&msg, nil, 0, 0, 0 /* PM_NOREMOVE */)
    }
}

/// Types `s` as Unicode key events, replacing the active selection.
/// - Returns: false if the input was blocked.
func sendUnicode(_ s: String) -> Bool {
    var inputs: [INPUT] = []
    for u in s.utf16 {
        inputs.append(keyEvent(vk: 0, scan: u, flags: DWORD(KEYEVENTF_UNICODE)))
        inputs.append(keyEvent(vk: 0, scan: u, flags: DWORD(KEYEVENTF_UNICODE) | DWORD(KEYEVENTF_KEYUP)))
    }
    return inputs.isEmpty || send(inputs)
}

/// Selects from the caret to line start (Shift+Home): the no-selection fallback.
func selectToLineStart() {
    send(tap(VK_HOME, with: VK_SHIFT))
    pumpWait(20)
}

/// Collapses a selection to its right end, where the caret was before Shift+Home.
func collapseSelection() {
    send([vkEvent(VK_RIGHT), vkEvent(VK_RIGHT, up: true)])
}

/// Unassigned VK tapped while Alt/Win is held, so their release neither opens the
/// menu bar nor Start after the hotkey key itself was swallowed.
func sendMaskKey() {
    send([keyEvent(vk: 0xE8, scan: 0, flags: 0), keyEvent(vk: 0xE8, scan: 0, flags: DWORD(KEYEVENTF_KEYUP))])
}

private func clipboardText() -> String {
    var opened = false
    for _ in 0..<10 {   // the copying app may still hold the clipboard
        if OpenClipboard(nil) { opened = true; break }
        pumpWait(20)
    }
    guard opened else { return "" }
    defer { CloseClipboard() }
    guard let h = GetClipboardData(UINT(CF_UNICODETEXT)), let p = GlobalLock(h) else { return "" }
    defer { GlobalUnlock(h) }
    return String(decodingCString: p.assumingMemoryBound(to: WCHAR.self), as: UTF16.self)
}

/// Reads the selection via Ctrl+C.
/// - Returns: nil if nothing is selected (clipboard unchanged, or an editor's
///   whole-line copy ending in a line break); "" if something was copied but no
///   text could be read.
func readSelection() -> String? {
    let before = GetClipboardSequenceNumber()
    guard send(tap(0x43 /* C */, with: VK_CONTROL)) else { return nil }
    var waited: DWORD = 0
    while GetClipboardSequenceNumber() == before {
        guard waited < 500 else { return nil }
        pumpWait(20); waited += 20
    }
    let text = clipboardText()
    return text.last?.isNewline == true ? nil : text
}

// Ask the foreground window to switch to the given layout.
func switchLayout(to dst: WinLayout) {
    let lp = unsafeBitCast(dst.hkl, to: LPARAM.self)
    _ = PostMessageW(GetForegroundWindow(), UINT(WM_INPUTLANGCHANGEREQUEST), 0, lp)
}

/// Waits for all modifiers (Win included) to be released before synthesizing input.
/// - Returns: false if they are still held after ~1.2 s.
func waitModifiersReleased() -> Bool {
    let mods = [VK_CONTROL, VK_MENU, VK_SHIFT, VK_LWIN, VK_RWIN]
    for _ in 0..<60 {
        if mods.allSatisfy({ (Int(GetAsyncKeyState($0)) & 0x8000) == 0 }) { return true }
        pumpWait(20)
    }
    return false
}
