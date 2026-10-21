// Windows end-to-end harness: a window with a RichEdit (what Notepad uses; it has
// native UI Automation text, a plain EDIT has none), typed into with
// SendInput scan codes that carry the dev build's e2e marker (the hook drops other
// injected keys), checked by reading the control back. Run by scripts/e2e-win.ps1
// in the interactive session; keep in step with scripts/e2e/harness.swift (macOS).
import WinSDK
import Foundation

let marker: ULONG_PTR = 0x524C_4532   // e2eKeyMarker in windows/WinHotkey.swift

// Set-1 scan codes of the US keyboard; with KEYEVENTF_SCANCODE Windows maps them
// through the foreground layout, like a physical key.
let scans: [Character: WORD] = [
    "q": 0x10, "w": 0x11, "e": 0x12, "r": 0x13, "t": 0x14, "y": 0x15, "u": 0x16, "i": 0x17, "o": 0x18,
    "p": 0x19, "[": 0x1A, "a": 0x1E, "s": 0x1F, "d": 0x20, "f": 0x21, "g": 0x22, "h": 0x23, "j": 0x24,
    "k": 0x25, "l": 0x26, ";": 0x27, "'": 0x28, "z": 0x2C, "x": 0x2D, "c": 0x2E, "v": 0x2F, "b": 0x30,
    "n": 0x31, "m": 0x32, ",": 0x33, ".": 0x34, " ": 0x39, "\t": 0x0F, "\r": 0x1C,
]
let scanCtrl: WORD = 0x1D, scanAlt: WORD = 0x38, scanR: WORD = 0x13

var mainWindow: HWND?
var edit: HWND?
var password: HWND?   // an ES_PASSWORD EDIT below the RichEdit
var uiThread: DWORD = 0

func pause(_ ms: DWORD) { Sleep(ms) }
/// Unbuffered: the process ends with ExitProcess, which would drop buffered output.
func say(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }

func key(_ scan: WORD, down: Bool, extra: ULONG_PTR = marker, extended: Bool = false) {
    var i = INPUT()
    i.type = DWORD(INPUT_KEYBOARD)
    i.ki = KEYBDINPUT(wVk: 0, wScan: scan,
                      dwFlags: DWORD(KEYEVENTF_SCANCODE) | (down ? 0 : DWORD(KEYEVENTF_KEYUP))
                          | (extended ? DWORD(KEYEVENTF_EXTENDEDKEY) : 0),
                      time: 0, dwExtraInfo: extra)
    SendInput(1, &i, Int32(MemoryLayout<INPUT>.size))
    pause(down ? 10 : 35)
}

func type(_ s: String) {
    for c in s {
        guard let sc = scans[c] else { fatalError("no scan code for \(c.debugDescription)") }
        key(sc, down: true); key(sc, down: false)
    }
}

/// The default retype hotkey, Ctrl+Alt+R.
func hotkey() {
    key(scanCtrl, down: true); key(scanAlt, down: true)
    key(scanR, down: true); key(scanR, down: false)
    key(scanAlt, down: false); key(scanCtrl, down: false)
    pause(100)
}

/// A click in a field: the app's mouse hook ends its word buffer and undo window.
func click(_ control: HWND? = edit) {
    var r = RECT()
    GetWindowRect(control, &r)
    SetCursorPos((r.left + r.right) / 2, (r.top + r.bottom) / 2)
    for flag in [MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP] {
        var i = INPUT()
        i.type = DWORD(INPUT_MOUSE)
        i.mi.dwFlags = DWORD(flag)
        SendInput(1, &i, Int32(MemoryLayout<INPUT>.size))
        pause(40)
    }
}

/// Line breaks read as "\n": RichEdit keeps "\r" internally.
func fieldText(_ control: HWND? = edit) -> String {
    let n = Int(SendMessageW(control, UINT(WM_GETTEXTLENGTH), 0, 0))
    var buf = [WCHAR](repeating: 0, count: n + 1)
    _ = buf.withUnsafeMutableBufferPointer {
        SendMessageW(control, UINT(WM_GETTEXT), WPARAM(n + 1), LPARAM(Int(bitPattern: $0.baseAddress)))
    }
    return String(decoding: buf.prefix(n), as: UTF16.self)
        .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
}

func setField(_ s: String, selectAll: Bool, in control: HWND? = edit) {
    s.withCString(encodedAs: UTF16.self) { _ = SendMessageW(control, UINT(WM_SETTEXT), 0, LPARAM(Int(bitPattern: $0))) }
    let n = s.utf16.count
    _ = SendMessageW(control, UINT(EM_SETSEL), WPARAM(selectAll ? 0 : n), LPARAM(n))
}

func layouts() -> [HKL] {
    var list = [HKL?](repeating: nil, count: 16)
    let n = Int(GetKeyboardLayoutList(16, &list))
    return list.prefix(n).compactMap { $0 }
}
func lang(_ h: HKL) -> Int { Int(UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(h))) & 0xFFFF) }
func currentLayout() -> HKL? { GetKeyboardLayout(uiThread) }

func select(_ h: HKL) {
    _ = PostMessageW(edit, UINT(WM_INPUTLANGCHANGEREQUEST), 0, LPARAM(Int(bitPattern: UnsafeRawPointer(h))))
    for _ in 0..<30 where currentLayout() != h { pause(10) }
    pause(50)
}

var latin: HKL!
var failures = 0

/// Stops the run rather than type into whatever window has focus instead.
func requireFocus() {
    for _ in 0..<40 {
        if GetForegroundWindow() == mainWindow { return }
        // A process may take the foreground right after it sent input; this Alt is
        // unmarked, so the app's hook ignores it.
        key(scanAlt, down: true, extra: 0); key(scanAlt, down: false, extra: 0)
        SetForegroundWindow(mainWindow)
        pause(50)
    }
    say("ABORT the test window is not in the foreground; nothing more is typed")
    ExitProcess(3)
}

func reset(_ s: String = "", selectAll: Bool = false) {
    requireFocus()
    click()
    setField(s, selectAll: selectAll)
    select(latin)
}

func expect(_ name: String, _ want: String, cyrillic: Bool? = nil, language: Int? = nil,
            timeout: Int = 3000, settle: DWORD = 0, in control: HWND? = edit) {
    if settle > 0 { pause(settle) }
    var got = ""
    for _ in 0..<(timeout / 50) {
        got = fieldText(control)
        if got == want { break }
        pause(50)
    }
    pause(200)
    let lay = currentLayout().map(lang) ?? 0
    let layOK = cyrillic.map { $0 == (lay != lang(latin)) } ?? true && language.map { $0 == lay } ?? true
    if got == want, layOK {
        say("PASS  \(name)")
    } else {
        failures += 1
        say("FAIL  \(name)\n      want \(want.debugDescription)"
              + (cyrillic.map { $0 ? " on Cyrillic" : " on Latin" } ?? "")
              + (language.map { " on \(String($0, radix: 16))" } ?? "")
              + "\n      got  \(got.debugDescription) on \(String(lay, radix: 16))")
    }
}

func runScenarios() -> Int32 {
    pause(500)
    let all = layouts()
    guard let l = all.first(where: { lang($0) == 0x0409 }),
          all.contains(where: { [0x0419, 0x0422].contains(lang($0)) }) else {
        say("SKIP  need en-US and a Russian or Ukrainian layout; have \(all.map { String(lang($0), radix: 16) })")
        return 1
    }
    latin = l
    let hasRu = all.contains { lang($0) == 0x0419 }
    let spell = CommandLine.arguments.contains("spell")   // the app runs with the spell-check option on
    say("layouts \(all.map { String(lang($0), radix: 16) })" + (spell ? ", spell check on" : ""))
    // (typed on Latin keys, what it reads as in the Cyrillic layout)
    let hello = hasRu ? ("ghbdtn", "привет") : ("ghbdsn", "привіт")
    let word = ("ckjdj", "слово")   // its undo below learns it as kept: later scenarios use `book`
    let book = ("rybuf", "книга")
    // Fresh words for scenarios after those: retyping a just-fixed word after a click
    // reads as reverting the fix (learning by revert, by design) and is then kept.
    let world = hasRu ? ("cdtn", "свет") : ("cdsn", "світ")
    let milk = ("vjkjrj", "молоко")

    reset(); type(hello.0 + " ")
    expect("auto: wrong-layout word is fixed", hello.1 + " ", cyrillic: true)

    reset(); type("hello ")
    expect("auto: right-layout word stays", "hello ", cyrillic: false, settle: 800)

    reset(hello.0, selectAll: true); hotkey()
    expect("hotkey: selection is converted", hello.1, cyrillic: true)

    if hasRu, all.contains(where: { lang($0) == 0x0422 }) {
        // Three layouts: each press takes the next reading, and the press after the last undoes.
        reset("ghbdsn", selectAll: true); hotkey()
        expect("hotkey: best reading first", "привіт", language: 0x0422)
        hotkey()
        expect("hotkey again: next reading", "привыт", language: 0x0419)
        hotkey()
        expect("hotkey third time: conversion is undone", "ghbdsn", cyrillic: false)
    }

    reset(); type(word.0 + " "); expect("auto: fix before the undo", word.1 + " ")
    hotkey()
    expect("hotkey after auto-fix: fix is undone", word.0 + " ", cyrillic: false)

    reset(); type(hello.0 + " ")
    expect("auto: fix before typing on", hello.1 + " ")
    type("rfr"); hotkey()   // "как", typed after the fix: the hotkey converts it, not undo
    expect("hotkey after typing: new word converts", hello.1 + " rfr", cyrillic: false)

    // Another program types mid-word (an unmarked injected key): the app's buffer no
    // longer matches the screen, so the word is left alone instead of misfixed.
    reset(); type(String(hello.0.prefix(3)))
    if let sc = scans[Array(hello.0)[3]] { key(sc, down: true, extra: 0); key(sc, down: false, extra: 0) }
    type(String(hello.0.dropFirst(4)) + " ")
    expect("auto: a key from another program resets the word", hello.0 + " ", settle: 800)

    // Keys typed while a fix runs are held, then replayed in the layout the fix left.
    reset(); type(hello.0 + " rfr ")
    expect("auto: keys typed during a fix land in the new layout", hello.1 + " как ")

    reset(); type("d\t" + book.0 + " ")   // a Tab may move focus: no fix reaches back across it
    expect("auto: short word before a Tab is left alone", "d\t" + book.1 + " ")

    // A password field: the app asks UI Automation off its hook thread and keeps the
    // word out of auto-correct while the answer is on its way and after.
    reset(); click(password); setField("", selectAll: false, in: password); select(latin)
    type(hello.0 + " ")
    pause(400)   // the second word comes after the answer, not while it is pending
    type(hello.0 + " ")
    expect("auto: nothing in a password field", hello.0 + " " + hello.0 + " ", settle: 800, in: password)

    // The auto-correct on/off hotkey is a tap of Right Ctrl (set by the runner): a tap
    // turns auto-correct off; a tap with a click in the middle is no tap.
    func tapRightCtrl(clickInside: Bool = false) {
        key(scanCtrl, down: true, extended: true)
        if clickInside { click() }
        key(scanCtrl, down: false, extended: true)
        pause(300)
    }
    reset(); tapRightCtrl(clickInside: true); type(world.0 + " ")
    expect("modifier tap: a click inside it is no tap", world.1 + " ", cyrillic: true)
    reset(); tapRightCtrl(); type(milk.0 + " ")
    expect("modifier tap: Right Ctrl turns auto-correct off", milk.0 + " ", settle: 800)
    reset(); tapRightCtrl(); type(milk.0 + " ")
    expect("modifier tap: and on again", milk.1 + " ", cyrillic: true)

    if spell {
        // Typos in a wrong-layout word: the trigrams alone leave them or convert them
        // as typed; the dictionary repairs the conversion (one edit away).
        let doubled = String(hello.0.prefix(4)) + String(Array(hello.0)[3]) + String(hello.0.dropFirst(4))
        reset(); type(doubled + " ")
        expect("spell: a doubled letter is repaired", hello.1 + " ", cyrillic: true)
        let a = Array(hello.0), swapped = String([a[0], a[2], a[1]] + a[3...])
        reset(); type(swapped + " ")
        expect("spell: swapped letters are repaired", hello.1 + " ", cyrillic: true)
    }

    reset(); type(hello.0 + "\r")
    expect("enter: word above the new line is fixed", hello.1 + "\n", cyrillic: true)

    say(failures == 0 ? "\nall passed" : "\n\(failures) failed")
    return Int32(failures)
}

// MARK: - window

let wndProc: WNDPROC = { hwnd, msg, wParam, lParam in
    switch Int32(msg) {
    case WM_SIZE:
        var r = RECT()
        GetClientRect(hwnd, &r)
        MoveWindow(edit, 0, 0, r.right, r.bottom - 34, true)
        MoveWindow(password, 0, r.bottom - 30, r.right, 30, true)
        return 0
    case WM_SETFOCUS:
        SetFocus(edit)
        return 0
    case WM_DESTROY:
        PostQuitMessage(0)
        return 0
    default:
        return DefWindowProcW(hwnd, msg, wParam, lParam)
    }
}

uiThread = GetCurrentThreadId()
let className = Array("reLayoutE2E".utf16) + [0]
var wc = WNDCLASSW()
wc.lpfnWndProc = wndProc
wc.hInstance = GetModuleHandleW(nil)
wc.hbrBackground = HBRUSH(bitPattern: UInt(COLOR_WINDOW + 1))
className.withUnsafeBufferPointer { wc.lpszClassName = $0.baseAddress; RegisterClassW(&wc) }
mainWindow = className.withUnsafeBufferPointer { cls in
    "reLayout e2e - hands off the keyboard".withCString(encodedAs: UTF16.self) { title in
        CreateWindowExW(DWORD(WS_EX_TOPMOST), cls.baseAddress, title, DWORD(WS_OVERLAPPEDWINDOW) | DWORD(WS_VISIBLE),
                        200, 200, 560, 240, nil, nil, wc.hInstance, nil)
    }
}
LoadLibraryW(Array("Msftedit.dll".utf16) + [0])
edit = "RICHEDIT50W".withCString(encodedAs: UTF16.self) { cls in
    CreateWindowExW(0, cls, nil, DWORD(WS_CHILD) | DWORD(WS_VISIBLE) | DWORD(WS_VSCROLL) | DWORD(ES_MULTILINE) | DWORD(ES_AUTOVSCROLL),
                    0, 0, 540, 160, mainWindow, nil, wc.hInstance, nil)
}
password = "EDIT".withCString(encodedAs: UTF16.self) { cls in
    CreateWindowExW(DWORD(WS_EX_CLIENTEDGE), cls, nil, DWORD(WS_CHILD) | DWORD(WS_VISIBLE) | DWORD(ES_PASSWORD) | DWORD(ES_AUTOHSCROLL),
                    0, 170, 540, 30, mainWindow, nil, wc.hInstance, nil)
}
SendMessageW(edit, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(GetStockObject(DEFAULT_GUI_FONT))))), 1)
ShowWindow(mainWindow, SW_SHOW)
SetForegroundWindow(mainWindow)
SetFocus(edit)

var worker: HANDLE? = CreateThread(nil, 0, { _ in
    let code = runScenarios()
    ExitProcess(UINT(bitPattern: code))
    return 0
}, nil, 0, nil)
_ = worker

var msg = MSG()
while GetMessageW(&msg, nil, 0, 0) {
    TranslateMessage(&msg)
    DispatchMessageW(&msg)
}
