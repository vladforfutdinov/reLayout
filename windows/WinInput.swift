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

private func send(_ inputs: [INPUT]) {
    var arr = inputs
    _ = SendInput(UINT(arr.count), &arr, Int32(MemoryLayout<INPUT>.size))
}

// Type a string as synthesized Unicode key events — replaces the active selection.
func sendUnicode(_ s: String) {
    var inputs: [INPUT] = []
    for u in s.utf16 {
        inputs.append(keyEvent(vk: 0, scan: u, flags: DWORD(KEYEVENTF_UNICODE)))
        inputs.append(keyEvent(vk: 0, scan: u, flags: DWORD(KEYEVENTF_UNICODE) | DWORD(KEYEVENTF_KEYUP)))
    }
    if !inputs.isEmpty { send(inputs) }
}

// Select the previous `count` caret stops (Shift+Left × count) — used by undo to
// re-select the text we just typed so the next sendUnicode replaces it.
func selectLeft(_ count: Int) {
    guard count > 0 else { return }
    let shift = WORD(VK_SHIFT)
    var inputs: [INPUT] = [keyEvent(vk: shift, scan: 0, flags: 0)]
    for _ in 0..<count {
        inputs.append(keyEvent(vk: WORD(VK_LEFT), scan: 0, flags: 0))
        inputs.append(keyEvent(vk: WORD(VK_LEFT), scan: 0, flags: DWORD(KEYEVENTF_KEYUP)))
    }
    inputs.append(keyEvent(vk: shift, scan: 0, flags: DWORD(KEYEVENTF_KEYUP)))
    send(inputs)
}

// Synthesize Ctrl+C to copy the current selection.
private func sendCtrlC() {
    let ctrl = WORD(VK_CONTROL)
    send([
        keyEvent(vk: ctrl, scan: 0, flags: 0),
        keyEvent(vk: WORD(0x43), scan: 0, flags: 0),            // 'C'
        keyEvent(vk: WORD(0x43), scan: 0, flags: DWORD(KEYEVENTF_KEYUP)),
        keyEvent(vk: ctrl, scan: 0, flags: DWORD(KEYEVENTF_KEYUP)),
    ])
}

// Read CF_UNICODETEXT from the clipboard.
private func clipboardText() -> String? {
    guard OpenClipboard(nil) else { return nil }
    defer { CloseClipboard() }
    guard let h = GetClipboardData(UINT(CF_UNICODETEXT)) else { return nil }
    guard let p = GlobalLock(h) else { return nil }
    defer { GlobalUnlock(h) }
    let s = String(decodingCString: p.assumingMemoryBound(to: WCHAR.self), as: UTF16.self)
    return s.isEmpty ? nil : s
}

// Read the current selection via Ctrl+C (MVP; UI Automation TextPattern later).
func readSelection() -> String? {
    sendCtrlC()
    Sleep(120)
    return clipboardText()
}

// Ask the foreground window to switch to the given layout.
func switchLayout(to dst: WinLayout) {
    let lp = unsafeBitCast(dst.hkl, to: LPARAM.self)
    _ = PostMessageW(GetForegroundWindow(), UINT(WM_INPUTLANGCHANGEREQUEST), 0, lp)
}

// Wait briefly for the hotkey's modifiers to be released before synthesizing input.
func waitModifiersReleased() {
    for _ in 0..<60 {
        let ctrl = GetAsyncKeyState(Int32(VK_CONTROL)) & ~1
        let alt  = GetAsyncKeyState(Int32(VK_MENU)) & ~1
        let shift = GetAsyncKeyState(Int32(VK_SHIFT)) & ~1
        if ctrl == 0 && alt == 0 && shift == 0 { return }
        Sleep(20)
    }
}
