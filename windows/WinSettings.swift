import WinSDK

// A small native Settings window opened from the tray menu. MVP controls:
// launch-at-login checkbox, the convert-hotkey hint, and shortcuts to the
// Windows keyboard settings and the project page. Lives on the app's single
// UI thread, so the main GetMessage loop drives it — no separate loop here.

private let idChkStartup:  Int = 101
private let idBtnKeyboard: Int = 102
private let idBtnAbout:    Int = 103
private let idBtnClose:    Int = 104

private var settingsHwnd: HWND?
private var settingsClassW = Array("ReLayoutSettingsWnd".utf16) + [0]
private var settingsClassRegistered = false

private let guiFont = GetStockObject(DEFAULT_GUI_FONT)
private func applyFont(_ h: HWND?) {
    SendMessageW(h, UINT(WM_SETFONT), unsafeBitCast(guiFont, to: WPARAM.self), LPARAM(1))
}

private func makeControl(_ cls: String, _ text: String, _ style: Int32,
                         _ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32,
                         _ parent: HWND?, _ id: Int) -> HWND? {
    let hInst = GetModuleHandleW(nil)
    return cls.withCString(encodedAs: UTF16.self) { clsP in
        text.withCString(encodedAs: UTF16.self) { txtP in
            let ctl = CreateWindowExW(0, clsP, txtP,
                                      DWORD(UInt32(bitPattern: style)) | DWORD(WS_CHILD) | DWORD(WS_VISIBLE),
                                      x, y, w, h, parent, HMENU(bitPattern: id), hInst, nil)
            applyFont(ctl)
            return ctl
        }
    }
}

private func buildControls(_ hwnd: HWND?) {
    _ = makeControl("STATIC", "reLayout", 0, 20, 16, 320, 22, hwnd, 0)
    _ = makeControl("STATIC", "Convert hotkey:  Ctrl + Alt + R", 0, 20, 44, 320, 20, hwnd, 0)
    let chk = makeControl("BUTTON", "Launch at login",
                          Int32(BS_AUTOCHECKBOX), 20, 78, 220, 22, hwnd, idChkStartup)
    SendMessageW(chk, UINT(BM_SETCHECK), WPARAM(startupEnabled() ? 1 : 0), 0)
    _ = makeControl("BUTTON", "Keyboard settings…", 0, 20, 118, 170, 28, hwnd, idBtnKeyboard)
    _ = makeControl("BUTTON", "About (GitHub)",      0, 200, 118, 150, 28, hwnd, idBtnAbout)
    _ = makeControl("BUTTON", "Close",               0, 250, 162, 100, 30, hwnd, idBtnClose)
}

private func settingsWndProc(_ hwnd: HWND?, _ msg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    switch msg {
    case UINT(WM_CREATE):
        buildControls(hwnd)
    case UINT(WM_COMMAND):
        switch Int(UInt(truncatingIfNeeded: wParam) & 0xFFFF) {
        case idChkStartup:
            let checked = SendMessageW(GetDlgItem(hwnd, Int32(idChkStartup)), UINT(BM_GETCHECK), 0, 0)
            setStartup(checked == LRESULT(BST_CHECKED))
        case idBtnKeyboard: openExternally("ms-settings:keyboard")
        case idBtnAbout:    openExternally(aboutURL)
        case idBtnClose:    DestroyWindow(hwnd)
        default: break
        }
    case UINT(WM_DESTROY):
        settingsHwnd = nil          // NB: do NOT PostQuitMessage — only this window closes
    default:
        break
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam)
}

func openSettings() {
    if let existing = settingsHwnd {           // already open — just focus it
        ShowWindow(existing, SW_SHOW)
        SetForegroundWindow(existing)
        return
    }
    let hInst = GetModuleHandleW(nil)
    if !settingsClassRegistered {
        settingsClassW.withUnsafeBufferPointer { name in
            var wc = WNDCLASSW()
            wc.lpfnWndProc = settingsWndProc
            wc.hInstance = hInst
            wc.lpszClassName = name.baseAddress
            wc.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))   // IDC_ARROW
            wc.hbrBackground = HBRUSH(bitPattern: Int(COLOR_BTNFACE) + 1)
            wc.hIcon = LoadIconW(hInst, UnsafePointer<WCHAR>(bitPattern: 1))          // app icon (id 1)
            _ = RegisterClassW(&wc)
        }
        settingsClassRegistered = true
    }
    let style = DWORD(WS_OVERLAPPED) | DWORD(WS_CAPTION) | DWORD(WS_SYSMENU)
    settingsHwnd = settingsClassW.withUnsafeBufferPointer { name in
        "reLayout — Settings".withCString(encodedAs: UTF16.self) { title in
            CreateWindowExW(0, name.baseAddress, title, style,
                            Int32(CW_USEDEFAULT), Int32(CW_USEDEFAULT), 380, 230,
                            nil, nil, hInst, nil)
        }
    }
    ShowWindow(settingsHwnd, SW_SHOW)
    SetForegroundWindow(settingsHwnd)
}
