import WinSDK

// Native Settings window opened from the tray. Themed (ComCtl32 v6 via the app
// manifest), Segoe UI, DPI-scaled and centered: the convert-hotkey recorder, a
// launch-at-login checkbox, a shortcut to Windows keyboard settings, and an
// About section. Lives on the app's single UI thread (the main GetMessage loop).

private let idChkStartup:  Int = 101
private let idBtnKeyboard: Int = 102
private let idBtnClose:    Int = 103
private let idLnkAbout:    Int = 104
private let idHotkeyField: Int = 105
private let idBtnSet:      Int = 106
private let idBtnReset:    Int = 107
private let idChkDouble:   Int = 108

private var settingsHwnd: HWND?
private var settingsClassW = Array("ReLayoutSettingsWnd".utf16) + [0]
private var settingsClassRegistered = false

private var uiDpi: Int32 = 96
private var uiFont: HFONT?

// NM_CLICK / NM_RETURN as UINT (NM_FIRST is 0, so these are 0u-2 / 0u-4).
private let nmClick  = UINT(bitPattern: -2)
private let nmReturn = UINT(bitPattern: -4)

private func sc(_ v: Int32) -> Int32 { v * uiDpi / 96 }   // scale a 96-dpi coord

private func applyFont(_ h: HWND?) {
    SendMessageW(h, UINT(WM_SETFONT), unsafeBitCast(uiFont, to: WPARAM.self), LPARAM(1))
}

private func makeControl(_ cls: String, _ text: String, _ style: Int32,
                         _ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32,
                         _ parent: HWND?, _ id: Int) -> HWND? {
    let hInst = GetModuleHandleW(nil)
    return cls.withCString(encodedAs: UTF16.self) { clsP in
        text.withCString(encodedAs: UTF16.self) { txtP in
            let ctl = CreateWindowExW(0, clsP, txtP,
                                      DWORD(UInt32(bitPattern: style)) | DWORD(WS_CHILD) | DWORD(WS_VISIBLE),
                                      sc(x), sc(y), sc(w), sc(h), parent, HMENU(bitPattern: id), hInst, nil)
            applyFont(ctl)
            return ctl
        }
    }
}

private func setFieldText(_ hwnd: HWND?, _ id: Int, _ s: String) {
    s.withCString(encodedAs: UTF16.self) { _ = SetWindowTextW(GetDlgItem(hwnd, Int32(id)), $0) }
}

// Apply a captured/reset hotkey: persist, re-arm the hook, refresh UI + tooltip.
private func applyHotkey(_ hwnd: HWND?, _ mods: UINT, _ vk: UINT) {
    saveHotkey(mods: mods, vk: vk)
    setHotkey(mods, vk)
    setFieldText(hwnd, idHotkeyField, hotkeyLabel(mods, vk))
    updateTrayTooltip()
}

private func buildControls(_ hwnd: HWND?) {
    _ = makeControl("STATIC", "Hotkey:", 0, 20, 18, 56, 20, hwnd, 0)
    // Read-only field showing the current hotkey; "Set" captures a new one
    // (including a bare modifier like Left Shift); "Reset" restores the default.
    let cur = loadHotkey()
    _ = makeControl("EDIT", hotkeyLabel(cur.mods, cur.vk),
                    Int32(0x0800) /* ES_READONLY */ | Int32(WS_BORDER) | Int32(WS_TABSTOP),
                    80, 15, 150, 24, hwnd, idHotkeyField)
    _ = makeControl("BUTTON", "Set",   Int32(WS_TABSTOP), 240, 15, 58, 26, hwnd, idBtnSet)
    _ = makeControl("BUTTON", "Reset", Int32(WS_TABSTOP), 304, 15, 58, 26, hwnd, idBtnReset)

    let dbl = makeControl("BUTTON", "Trigger on double-tap",
                          Int32(BS_AUTOCHECKBOX) | Int32(WS_TABSTOP), 20, 48, 280, 22, hwnd, idChkDouble)
    SendMessageW(dbl, UINT(BM_SETCHECK), WPARAM(loadDoubleTap() ? 1 : 0), 0)

    let chk = makeControl("BUTTON", "Launch at login",
                          Int32(BS_AUTOCHECKBOX) | Int32(WS_TABSTOP), 20, 80, 220, 22, hwnd, idChkStartup)
    SendMessageW(chk, UINT(BM_SETCHECK), WPARAM(startupEnabled() ? 1 : 0), 0)

    _ = makeControl("BUTTON", "Keyboard settings…",
                    Int32(WS_TABSTOP), 20, 116, 170, 30, hwnd, idBtnKeyboard)

    // ── About section ──
    _ = makeControl("STATIC", "", 0x0010 /* SS_ETCHEDHORZ */, 20, 160, 342, 1, hwnd, 0)
    _ = makeControl("STATIC", "reLayout  ·  version \(appVersion)", 0, 20, 172, 342, 20, hwnd, 0)
    _ = makeControl("STATIC", "Retype selection in the correct keyboard layout", 0, 20, 192, 342, 20, hwnd, 0)
    _ = makeControl("STATIC", "© 2026 Volodymyr Forfutdinov", 0, 20, 212, 342, 20, hwnd, 0)
    _ = makeControl("SysLink", "<a>github.com/vladforfutdinov/reLayout</a>",
                    Int32(WS_TABSTOP), 20, 234, 342, 22, hwnd, idLnkAbout)

    _ = makeControl("BUTTON", "Close",
                    Int32(WS_TABSTOP), 262, 266, 100, 30, hwnd, idBtnClose)
}

private func sizeAndCenter(_ hwnd: HWND?) {
    // Grow to fit the scaled client area, using the actual (already DPI-correct)
    // non-client delta — avoids AdjustWindowRectExForDpi's BOOL parameter.
    var wr = RECT(); GetWindowRect(hwnd, &wr)
    var cr = RECT(); GetClientRect(hwnd, &cr)
    let ncw = (wr.right - wr.left) - (cr.right - cr.left)
    let nch = (wr.bottom - wr.top) - (cr.bottom - cr.top)
    let w = sc(380) + ncw
    let h = sc(310) + nch
    var mi = MONITORINFO(); mi.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
    GetMonitorInfoW(MonitorFromWindow(hwnd, DWORD(MONITOR_DEFAULTTONEAREST)), &mi)
    let x = mi.rcWork.left + ((mi.rcWork.right - mi.rcWork.left) - w) / 2
    let y = mi.rcWork.top  + ((mi.rcWork.bottom - mi.rcWork.top) - h) / 2
    SetWindowPos(hwnd, nil, x, y, w, h, UINT(SWP_NOZORDER))
}

private func settingsWndProc(_ hwnd: HWND?, _ msg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    switch msg {
    case UINT(WM_CREATE):
        let dpi = GetDpiForWindow(hwnd)
        uiDpi = dpi > 0 ? Int32(dpi) : 96
        let face = "Segoe UI"
        uiFont = face.withCString(encodedAs: UTF16.self) { f in
            CreateFontW(-(9 * uiDpi / 72), 0, 0, 0, Int32(FW_NORMAL),
                        0, 0, 0,
                        DWORD(DEFAULT_CHARSET), DWORD(OUT_DEFAULT_PRECIS),
                        DWORD(CLIP_DEFAULT_PRECIS), DWORD(CLEARTYPE_QUALITY),
                        DWORD(DEFAULT_PITCH), f)
        }
        buildControls(hwnd)
        sizeAndCenter(hwnd)
    case UINT(WM_COMMAND):
        switch Int(UInt(truncatingIfNeeded: wParam) & 0xFFFF) {
        case idChkStartup:
            let checked = SendMessageW(GetDlgItem(hwnd, Int32(idChkStartup)), UINT(BM_GETCHECK), 0, 0)
            setStartup(checked == LRESULT(BST_CHECKED))
        case idChkDouble:
            let checked = SendMessageW(GetDlgItem(hwnd, Int32(idChkDouble)), UINT(BM_GETCHECK), 0, 0)
            saveDoubleTap(checked == LRESULT(BST_CHECKED))
        case idBtnKeyboard: openExternally("ms-settings:keyboard")
        case idBtnSet:
            setFieldText(hwnd, idHotkeyField, "Press hotkey…")
            startHotkeyCapture { mods, vk in applyHotkey(hwnd, mods, vk) }
        case idBtnReset:    applyHotkey(hwnd, defaultHotkey.mods, defaultHotkey.vk)
        case idBtnClose:    DestroyWindow(hwnd)
        default: break
        }
    case UINT(WM_NOTIFY):
        if let raw = UnsafeRawPointer(bitPattern: Int(lParam)) {
            let hdr = raw.assumingMemoryBound(to: NMHDR.self).pointee
            if hdr.idFrom == UINT_PTR(idLnkAbout), hdr.code == nmClick || hdr.code == nmReturn {
                openExternally(aboutURL)
            }
        }
    case UINT(WM_DESTROY):
        cancelHotkeyCapture()       // don't leave a capture targeting a dead window
        settingsHwnd = nil          // NB: do NOT PostQuitMessage — only this window closes
    default:
        break
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam)
}

func openSettings() {
    if let existing = settingsHwnd {            // already open — just focus it
        ShowWindow(existing, SW_SHOW)
        SetForegroundWindow(existing)
        return
    }
    let hInst = GetModuleHandleW(nil)

    // SysLink lives in ComCtl32 — make sure its class is registered.
    var icc = INITCOMMONCONTROLSEX()
    icc.dwSize = DWORD(MemoryLayout<INITCOMMONCONTROLSEX>.size)
    icc.dwICC  = DWORD(ICC_LINK_CLASS) | DWORD(ICC_HOTKEY_CLASS) | DWORD(ICC_STANDARD_CLASSES)
    InitCommonControlsEx(&icc)

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
                            Int32(CW_USEDEFAULT), Int32(CW_USEDEFAULT), 400, 240,
                            nil, nil, hInst, nil)
        }
    }
    ShowWindow(settingsHwnd, SW_SHOW)
    SetForegroundWindow(settingsHwnd)
}
