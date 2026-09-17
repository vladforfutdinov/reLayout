import WinSDK
import Foundation

// "Exceptions" window: programs where auto-correct stays off, one executable name
// per line. The macOS app lists running apps with checkboxes; here the list is
// typed, which is the smallest thing that works — the defaults already cover the
// usual terminals and editors.

private let idExcEdit:   Int = 201
private let idExcSave:   Int = 202
private let idExcCancel: Int = 203
private let idExcReset:  Int = 204

private var exceptionsHwnd: HWND?
private var exceptionsClassW = Array("ReLayoutExceptionsWnd".utf16) + [0]
private var exceptionsClassRegistered = false
private var excDpi: Int32 = 96

private func esc(_ v: Int32) -> Int32 { v * excDpi / 96 }   // scale a 96-dpi coord

private func parseApps(_ text: String) -> [String] {
    text.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        .filter { !$0.isEmpty }
}

private func editText(_ hwnd: HWND?) -> String {
    let edit = GetDlgItem(hwnd, Int32(idExcEdit))
    var buf = [WCHAR](repeating: 0, count: Int(GetWindowTextLengthW(edit)) + 1)
    let n = GetWindowTextW(edit, &buf, Int32(buf.count))
    return String(decoding: buf.prefix(Int(n)), as: UTF16.self)
}

private func setEditText(_ hwnd: HWND?, _ apps: [String]) {
    apps.joined(separator: "\r\n").withCString(encodedAs: UTF16.self) {
        _ = SetWindowTextW(GetDlgItem(hwnd, Int32(idExcEdit)), $0)
    }
}

private func makeExcControl(_ cls: String, _ text: String, _ style: Int32,
                            _ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32,
                            _ parent: HWND?, _ id: Int) {
    let hInst = GetModuleHandleW(nil)
    cls.withCString(encodedAs: UTF16.self) { clsP in
        text.withCString(encodedAs: UTF16.self) { txtP in
            let ctl = CreateWindowExW(0, clsP, txtP,
                                      DWORD(UInt32(bitPattern: style)) | DWORD(WS_CHILD) | DWORD(WS_VISIBLE),
                                      esc(x), esc(y), esc(w), esc(h), parent, HMENU(bitPattern: id), hInst, nil)
            SendMessageW(ctl, UINT(WM_SETFONT), unsafeBitCast(settingsFont(), to: WPARAM.self), LPARAM(1))
        }
    }
}

private func exceptionsWndProc(_ hwnd: HWND?, _ msg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    switch msg {
    case UINT(WM_COMMAND):
        switch Int(UInt(truncatingIfNeeded: wParam) & 0xFFFF) {
        case idExcSave:
            saveExcludedApps(parseApps(editText(hwnd)))
            reloadAutoMode()
            DestroyWindow(hwnd)
        case idExcReset:  setEditText(hwnd, defaultExcludedApps)
        case idExcCancel: DestroyWindow(hwnd)
        default: break
        }
    case UINT(WM_DESTROY):
        exceptionsHwnd = nil
    default:
        break
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam)
}

func openExceptions(owner: HWND?) {
    if let existing = exceptionsHwnd {
        ShowWindow(existing, SW_SHOW)
        SetForegroundWindow(existing)
        return
    }
    let hInst = GetModuleHandleW(nil)
    if !exceptionsClassRegistered {
        exceptionsClassW.withUnsafeBufferPointer { name in
            var wc = WNDCLASSW()
            wc.lpfnWndProc = exceptionsWndProc
            wc.hInstance = hInst
            wc.lpszClassName = name.baseAddress
            wc.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))   // IDC_ARROW
            wc.hbrBackground = HBRUSH(bitPattern: Int(COLOR_BTNFACE) + 1)
            wc.hIcon = LoadIconW(hInst, UnsafePointer<WCHAR>(bitPattern: 1))          // app icon (id 1)
            exceptionsClassRegistered = RegisterClassW(&wc) != 0
        }
    }
    guard exceptionsClassRegistered else { return }

    let style = DWORD(WS_OVERLAPPED) | DWORD(WS_CAPTION) | DWORD(WS_SYSMENU)
    exceptionsHwnd = exceptionsClassW.withUnsafeBufferPointer { name in
        "reLayout — Exceptions".withCString(encodedAs: UTF16.self) { title in
            CreateWindowExW(0, name.baseAddress, title, style,
                            Int32(CW_USEDEFAULT), Int32(CW_USEDEFAULT), 440, 400,
                            owner, nil, hInst, nil)
        }
    }
    guard let hwnd = exceptionsHwnd else { return }
    let dpi = GetDpiForWindow(hwnd)
    excDpi = dpi > 0 ? Int32(dpi) : 96

    makeExcControl("STATIC", "Auto-correct stays off in these programs — one executable name per line:",
                   0, 16, 12, 392, 36, hwnd, 0)
    makeExcControl("EDIT", "", Int32(WS_BORDER) | Int32(WS_VSCROLL) | Int32(WS_TABSTOP)
                   | Int32(ES_MULTILINE) | Int32(ES_WANTRETURN) | Int32(ES_AUTOVSCROLL),
                   16, 52, 392, 210, hwnd, idExcEdit)
    makeExcControl("BUTTON", "Restore defaults", Int32(WS_TABSTOP), 16, 274, 140, 30, hwnd, idExcReset)
    makeExcControl("BUTTON", "Cancel", Int32(WS_TABSTOP), 226, 274, 84, 30, hwnd, idExcCancel)
    makeExcControl("BUTTON", "Save", Int32(WS_TABSTOP), 320, 274, 88, 30, hwnd, idExcSave)
    setEditText(hwnd, loadExcludedApps())

    // Grow to fit the scaled client area (the window was created at 96-dpi sizes).
    var wr = RECT(); GetWindowRect(hwnd, &wr)
    var cr = RECT(); GetClientRect(hwnd, &cr)
    SetWindowPos(hwnd, nil, 0, 0,
                 esc(424) + (wr.right - wr.left) - (cr.right - cr.left),
                 esc(320) + (wr.bottom - wr.top) - (cr.bottom - cr.top),
                 UINT(SWP_NOMOVE) | UINT(SWP_NOZORDER))
    ShowWindow(hwnd, SW_SHOW)
    SetForegroundWindow(hwnd)
}
