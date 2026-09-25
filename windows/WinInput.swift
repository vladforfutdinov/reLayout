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
    if [VK_HOME, VK_END, VK_LEFT, VK_RIGHT, VK_LWIN, VK_RWIN, VK_RMENU, VK_RCONTROL].contains(vk) {
        flags |= DWORD(KEYEVENTF_EXTENDEDKEY)
    }
    return keyEvent(vk: WORD(vk), scan: scan, flags: flags)
}

@discardableResult
private func send(_ inputs: [INPUT]) -> Bool {
    var arr = inputs
    // Fewer events than asked = blocked (UIPI: elevated foreground window).
    let accepted = SendInput(UINT(arr.count), &arr, Int32(MemoryLayout<INPUT>.size))
    dlog("send \(arr.count) accepted=\(accepted) err=\(accepted == UINT(arr.count) ? 0 : GetLastError()) "
         + arr.map { "[\(String($0.ki.wVk, radix: 16)) \(String($0.ki.wScan, radix: 16)) \(String($0.ki.dwFlags, radix: 16))]" }
              .joined(separator: " "))
    return accepted == UINT(arr.count)
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

/// A key of `layout` pressed or released, with the scan code that layout gives it.
private func strokeEvent(_ vk: Int32, _ layout: WinLayout, up: Bool = false) -> INPUT {
    let scan = WORD(truncatingIfNeeded: MapVirtualKeyExW(UINT(vk), 0 /* MAPVK_VK_TO_VSC */, layout.hkl))
    return keyEvent(vk: WORD(vk), scan: scan, flags: up ? DWORD(KEYEVENTF_KEYUP) : 0)
}

/// Switches the focused window to `layout` and waits until it took effect there.
/// - Returns: false when it did not within ~300 ms.
func activateLayout(_ layout: WinLayout) -> Bool {
    switchLayout(to: layout)
    for _ in 0..<30 {
        if let cur = WinLayout.current(), cur.hkl == layout.hkl { return true }
        pumpWait(10)
    }
    return false
}

/// Types `s` as real key presses of `layout`, switching the focused window to it
/// first, in one batch. Unicode events (VK_PACKET) can't be batched: a busy app
/// (Windows 11 Notepad) reads the same character for several presses. Undocumented —
/// the likely cause is one pending packet character per thread, overwritten before
/// the app reads it — and observed under QEMU, which may contribute. A converted text is made of the
/// target layout's characters by construction; one the layout lacks, or a switch
/// that doesn't take, falls back to paced Unicode events.
func typeText(_ s: String, in layout: WinLayout) -> Bool {
    guard activateLayout(layout) else { return sendUnicode(s) }
    var inputs: [INPUT] = []
    for ch in s {
        if ch == "\r\n" || ch == "\n" || ch == "\r" {
            inputs += [vkEvent(VK_RETURN), vkEvent(VK_RETURN, up: true)]
            continue
        }
        guard let stroke = layout.charToStroke[String(ch)] else {
            guard inputs.isEmpty || send(inputs) else { return false }
            inputs = []
            guard sendUnicode(String(ch)) else { return false }
            continue
        }
        // mods: 1 = Shift, 2 = AltGr (Ctrl+Alt), 3 = both — see WinLayout.
        let shift = stroke.mods & 1 != 0, altGr = stroke.mods & 2 != 0
        let key = Int32(stroke.keyCode)
        if altGr { inputs += [strokeEvent(VK_CONTROL, layout), strokeEvent(VK_MENU, layout)] }
        if shift { inputs.append(strokeEvent(VK_SHIFT, layout)) }
        inputs += [strokeEvent(key, layout), strokeEvent(key, layout, up: true)]
        if shift { inputs.append(strokeEvent(VK_SHIFT, layout, up: true)) }
        if altGr { inputs += [strokeEvent(VK_MENU, layout, up: true), strokeEvent(VK_CONTROL, layout, up: true)] }
    }
    return inputs.isEmpty || send(inputs)
}

/// Types `s` as Unicode key events, replacing the active selection. Line breaks
/// (`\r\n`, `\n`, `\r`), spaces and tabs go out as real keys: apps act on the key,
/// not on a VK_PACKET carrying the character.
/// - Returns: false if the input was blocked.
func sendUnicode(_ s: String) -> Bool {
    // One character per SendInput call with a short pause, like the macOS app's
    // typeUnicode: Windows 11 Notepad, fed a whole text in one batch — or in back-to-
    // back calls — repeated one character for everything after the first space.
    // The pause needs a 1 ms timer: at the default 15.6 ms it types slower than a hand.
    timeBeginPeriod(1)
    defer { timeEndPeriod(1) }
    for ch in s {
        var inputs: [INPUT] = []
        if ch == "\r\n" || ch == "\n" || ch == "\r" {
            inputs = [vkEvent(VK_RETURN), vkEvent(VK_RETURN, up: true)]
        } else if ch == " " || ch == "\t" {
            let vk = ch == " " ? VK_SPACE : VK_TAB
            inputs = [vkEvent(vk), vkEvent(vk, up: true)]
        } else {
            for u in String(ch).utf16 {
                inputs.append(keyEvent(vk: 0, scan: u, flags: DWORD(KEYEVENTF_UNICODE)))
                inputs.append(keyEvent(vk: 0, scan: u, flags: DWORD(KEYEVENTF_UNICODE) | DWORD(KEYEVENTF_KEYUP)))
            }
        }
        guard send(inputs) else { return false }
        pumpWait(1)
    }
    return true
}

/// Selects the `count` characters left of the caret (Shift+Left), so typing
/// replaces exactly them.
func selectLeft(_ count: Int) {
    guard count > 0 else { return }
    var inputs = [vkEvent(VK_SHIFT)]
    for _ in 0..<count { inputs += [vkEvent(VK_LEFT), vkEvent(VK_LEFT, up: true)] }
    inputs.append(vkEvent(VK_SHIFT, up: true))
    send(inputs)
    pumpWait(20)
}

/// Presses Backspace `count` times, in one batch.
func sendBackspaces(_ count: Int) {
    guard count > 0 else { return }
    var inputs: [INPUT] = []
    for _ in 0..<count { inputs += [vkEvent(VK_BACK), vkEvent(VK_BACK, up: true)] }
    send(inputs)
}

/// Presses one key, as the app expects it (Space/Tab act on the key, not on text).
/// - Parameter shift: hold Shift around it (Shift+Tab, Shift+Enter).
func sendKeyTap(_ vk: Int32, shift: Bool = false) {
    let tap = [vkEvent(vk), vkEvent(vk, up: true)]
    send(shift ? [vkEvent(VK_SHIFT)] + tap + [vkEvent(VK_SHIFT, up: true)] : tap)
}

private let maskKey = [keyEvent(vk: 0xE8, scan: 0, flags: 0), keyEvent(vk: 0xE8, scan: 0, flags: DWORD(KEYEVENTF_KEYUP))]

/// Unassigned VK tapped while Alt/Win is held, so their release neither opens the
/// menu bar nor Start after the hotkey key itself was swallowed.
func sendMaskKey() {
    send(maskKey)
}

/// Replays a swallowed Alt/Win release behind the mask key: a bare tap of either
/// would otherwise open the menu bar or Start and take our Ctrl+C.
func sendMaskedRelease(_ vk: UINT) {
    send(maskKey + [vkEvent(Int32(vk), up: true)])
}

/// Window with keyboard focus in the foreground input thread (a UWP app's
/// CoreWindow, not its ApplicationFrameHost frame), else the foreground window.
func focusWindow() -> HWND? {
    var info = GUITHREADINFO()
    info.cbSize = DWORD(MemoryLayout<GUITHREADINFO>.size)
    if GetGUIThreadInfo(0, &info), let focus = info.hwndFocus { return focus }
    return GetForegroundWindow()
}

/// Full path of the executable that owns `hwnd`.
func processImagePath(of hwnd: HWND?) -> String? {
    var pid: DWORD = 0
    GetWindowThreadProcessId(hwnd, &pid)
    guard pid != 0, pid != GetCurrentProcessId(),
          let handle = OpenProcess(DWORD(0x1000 /* PROCESS_QUERY_LIMITED_INFORMATION */), false, pid)
    else { return nil }
    defer { CloseHandle(handle) }
    var buf = [WCHAR](repeating: 0, count: 1024)
    var size = DWORD(buf.count)
    guard QueryFullProcessImageNameW(handle, 0, &buf, &size) else { return nil }
    return String(decoding: buf.prefix(Int(size)), as: UTF16.self)
}

/// "C:\\Windows\\System32\\cmd.exe" -> "cmd.exe": the key the exceptions list uses.
func exeName(_ path: String) -> String {
    (path.split(separator: "\\").last.map(String.init) ?? path).lowercased()
}

/// True for terminal windows: Ctrl+C there interrupts the running program.
func foregroundIsConsole() -> Bool {
    guard let fg = GetForegroundWindow() else { return false }
    var buf = [WCHAR](repeating: 0, count: 64)
    let n = Int(GetClassNameW(fg, &buf, Int32(buf.count)))
    let cls = String(decoding: buf.prefix(n), as: UTF16.self)
    return ["ConsoleWindowClass", "CASCADIA_HOSTING_WINDOW_CLASS", "VirtualConsoleClass", "mintty"].contains(cls)
}

private func openClipboardRetrying(owner: HWND? = nil) -> Bool {
    for _ in 0..<10 {   // another app (the one that just copied) may still hold it
        if OpenClipboard(owner) { return true }
        pumpWait(20)
    }
    return false
}

private func clipboardText() -> String {
    guard openClipboardRetrying() else { return "" }
    defer { CloseClipboard() }
    guard let h = GetClipboardData(UINT(CF_UNICODETEXT)), let p = GlobalLock(h) else { return "" }
    defer { GlobalUnlock(h) }
    return String(decodingCString: p.assumingMemoryBound(to: WCHAR.self), as: UTF16.self)
}

/// The user's clipboard, saved before the Ctrl+C read and put back after it.
struct ClipboardSnapshot {
    fileprivate var items: [(format: UINT, data: [UInt8])] = []
}

// Handles that are not HGLOBAL memory: CF_BITMAP, CF_METAFILEPICT, CF_PALETTE,
// CF_ENHMETAFILE, owner-display/DSP formats, and the private/GDI-object ranges.
// CF_DIB stays, and Windows synthesizes CF_BITMAP from it.
private func isMemoryFormat(_ f: UINT) -> Bool {
    ![2, 3, 9, 14, 0x80, 0x82, 0x83, 0x8E].contains(f) && !(0x200...0x3FF).contains(f)
}

private let snapshotLimit = 64 << 20

/// Copies every memory-backed clipboard format.
/// - Returns: nil if the clipboard can't be opened or holds more than 64 MB;
///   the caller then leaves the clipboard as the Ctrl+C read left it.
func saveClipboard() -> ClipboardSnapshot? {
    guard openClipboardRetrying() else { return nil }
    defer { CloseClipboard() }
    var snap = ClipboardSnapshot()
    var total = 0
    var fmt = EnumClipboardFormats(0)
    while fmt != 0 {
        if isMemoryFormat(fmt), let h = GetClipboardData(fmt) {
            let size = Int(GlobalSize(h))
            total += size
            guard total <= snapshotLimit else { return nil }
            if size > 0, let p = GlobalLock(h) {
                snap.items.append((format: fmt, data: Array(UnsafeRawBufferPointer(start: p, count: size))))
                GlobalUnlock(h)
            }
        }
        fmt = EnumClipboardFormats(fmt)
    }
    return snap
}

// Keeps the restored copy out of Win+V history and cloud clipboard.
private let excludeFromHistory = "ExcludeClipboardContentFromMonitorProcessing"
    .withCString(encodedAs: UTF16.self) { RegisterClipboardFormatW($0) }

/// Puts a snapshot back. `owner` must be a window: with a nil owner,
/// `SetClipboardData` fails after `EmptyClipboard`.
func restoreClipboard(_ snap: ClipboardSnapshot, owner: HWND?) {
    guard let owner, openClipboardRetrying(owner: owner) else { return }
    defer { CloseClipboard() }
    EmptyClipboard()
    for item in snap.items { setClipboardBytes(item.format, item.data) }
    setClipboardBytes(excludeFromHistory, [0])
}

private func setClipboardBytes(_ fmt: UINT, _ bytes: [UInt8]) {
    guard fmt != 0, !bytes.isEmpty, let h = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(bytes.count)) else { return }
    guard let p = GlobalLock(h) else { _ = GlobalFree(h); return }
    bytes.withUnsafeBytes { p.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    GlobalUnlock(h)
    if SetClipboardData(fmt, h) == nil { _ = GlobalFree(h) }   // on success the system owns it
}

private let chromiumCustomData = "Chromium Web Custom MIME Data Format"
    .withCString(encodedAs: UTF16.self) { RegisterClipboardFormatW($0) }

/// Whether a Chromium editor (VS Code) marked the copy as made with nothing
/// selected, i.e. its whole-line copy — the same metadata the macOS app reads.
/// - Returns: nil when the clipboard carries no such mark.
private func copiedFromEmptySelection() -> Bool? {
    guard chromiumCustomData != 0, openClipboardRetrying() else { return nil }
    defer { CloseClipboard() }
    guard let h = GetClipboardData(chromiumCustomData), let p = GlobalLock(h) else { return nil }
    defer { GlobalUnlock(h) }
    let units = UnsafeBufferPointer(start: p.assumingMemoryBound(to: UInt16.self), count: Int(GlobalSize(h)) / 2)
    let meta = String(decoding: units, as: UTF16.self)
    guard meta.contains("\"isFromEmptySelection\":") else { return nil }
    return meta.contains("\"isFromEmptySelection\":true")
}

/// Reads the selection via Ctrl+C.
/// - Returns: nil if nothing is selected (clipboard unchanged, or an editor's
///   whole-line copy: marked as such by VS Code, else guessed from a trailing line
///   break); "" if something was copied but no text could be read.
func readSelection() -> String? {
    let before = GetClipboardSequenceNumber()
    guard send(tap(0x43 /* C */, with: VK_CONTROL)) else { return nil }
    var waited: DWORD = 0
    while GetClipboardSequenceNumber() == before {
        guard waited < 500 else { return nil }
        pumpWait(20); waited += 20
    }
    let text = clipboardText()
    let wholeLine = copiedFromEmptySelection() ?? (text.last?.isNewline == true)
    return wholeLine ? nil : text
}

/// Asks the focused window to switch to the given layout.
func switchLayout(to dst: WinLayout) {
    _ = PostMessageW(focusWindow(), UINT(WM_INPUTLANGCHANGEREQUEST), 0, LPARAM(Int(bitPattern: dst.hkl)))
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
