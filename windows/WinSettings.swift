import WinSDK

// Native Settings window opened from the tray. Themed (ComCtl32 v6 via the app
// manifest), Segoe UI, DPI-scaled and centered. Content mirrors the macOS
// Settings: a live "Layouts" line, the convert-hotkey hint, a launch-at-login
// checkbox, a shortcut to Windows keyboard settings, and an About link.
// Lives on the app's single UI thread, so the main GetMessage loop drives it.

private let idChkStartup:  Int = 101
private let idBtnKeyboard: Int = 102
private let idBtnClose:    Int = 103
private let idLnkAbout:    Int = 104
private let idHotkey:      Int = 105
private let idBtnReset:    Int = 106
private let idBtnApply:    Int = 107
private let idCombo:       Int = 108

// ComboBox messages (winuser.h) — not surfaced to Swift.
private let CB_ADDSTRING_ = UINT(0x0143)
private let CB_SETCURSEL_ = UINT(0x014E)
private let CB_GETCURSEL_ = UINT(0x0147)

private func cbAdd(_ combo: HWND?, _ s: String) {
    s.withCString(encodedAs: UTF16.self) { p in
        _ = SendMessageW(combo, CB_ADDSTRING_, 0, LPARAM(Int(bitPattern: UnsafeRawPointer(p))))
    }
}

// Hotkey control messages (commctrl.h) — not surfaced to Swift.
private let HKM_SETHOTKEY = UINT(WM_USER) + 1
private let HKM_GETHOTKEY = UINT(WM_USER) + 2

// HOTKEYF_* (control) <-> MOD_* (RegisterHotKey) bit conversions.
private func modToHotkeyf(_ mods: UINT) -> UInt {
    var f: UInt = 0
    if mods & UINT(MOD_ALT)     != 0 { f |= 4 }   // HOTKEYF_ALT
    if mods & UINT(MOD_CONTROL) != 0 { f |= 2 }   // HOTKEYF_CONTROL
    if mods & UINT(MOD_SHIFT)   != 0 { f |= 1 }   // HOTKEYF_SHIFT
    return f
}
private func hotkeyfToMod(_ f: UInt) -> UINT {
    var m: UINT = 0
    if f & 4 != 0 { m |= UINT(MOD_ALT) }
    if f & 2 != 0 { m |= UINT(MOD_CONTROL) }
    if f & 1 != 0 { m |= UINT(MOD_SHIFT) }
    return m
}

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

private func layoutsLine() -> String {
    let names = WinLayout.installedList().map { $0.displayName }
    return names.isEmpty ? "Layouts:  —" : "Layouts:  " + names.joined(separator: "  ·  ")
}

private func setHotkeyControl(_ hwnd: HWND?, _ mods: UINT, _ vk: UINT) {
    let f = modToHotkeyf(mods)
    SendMessageW(GetDlgItem(hwnd, Int32(idHotkey)), HKM_SETHOTKEY, WPARAM(UInt(vk) | (f << 8)), 0)
}

private func applyHotkeyFromControl(_ hwnd: HWND?) {
    let raw = SendMessageW(GetDlgItem(hwnd, Int32(idHotkey)), HKM_GETHOTKEY, 0, 0)  // LRESULT
    let vk  = UINT(raw & 0xFF)
    let f   = UInt((raw >> 8) & 0xFF)
    guard vk != 0 else { return }            // no main key chosen — ignore
    let mods = hotkeyfToMod(f)
    saveHotkey(mods: mods, vk: vk)
    _ = registerConvertHotkey(mods, vk)
}

private func buildControls(_ hwnd: HWND?) {
    _ = makeControl("STATIC", layoutsLine(), 0, 20, 16, 340, 20, hwnd, 0)

    _ = makeControl("STATIC", "Hotkey:", 0, 20, 50, 56, 20, hwnd, 0)
    _ = makeControl("msctls_hotkey32", "", Int32(WS_TABSTOP), 80, 48, 150, 24, hwnd, idHotkey)
    let cur = loadHotkey()
    setHotkeyControl(hwnd, cur.mods, cur.vk)
    _ = makeControl("BUTTON", "Reset", Int32(WS_TABSTOP), 240, 47, 58, 26, hwnd, idBtnReset)
    _ = makeControl("BUTTON", "Apply", Int32(WS_TABSTOP), 304, 47, 58, 26, hwnd, idBtnApply)

    _ = makeControl("STATIC", "Tray icon:", 0, 20, 88, 56, 20, hwnd, 0)
    let combo = makeControl("COMBOBOX", "",
                            Int32(0x0003) /* CBS_DROPDOWNLIST */ | Int32(WS_VSCROLL) | Int32(WS_TABSTOP),
                            80, 84, 170, 160, hwnd, idCombo)
    cbAdd(combo, "Static logo")
    cbAdd(combo, "Layout code")
    SendMessageW(combo, CB_SETCURSEL_, WPARAM(loadTrayMode()), 0)

    let chk = makeControl("BUTTON", "Launch at login",
                          Int32(BS_AUTOCHECKBOX) | Int32(WS_TABSTOP), 20, 124, 220, 22, hwnd, idChkStartup)
    SendMessageW(chk, UINT(BM_SETCHECK), WPARAM(startupEnabled() ? 1 : 0), 0)

    _ = makeControl("BUTTON", "Keyboard settings…",
                    Int32(WS_TABSTOP), 20, 160, 170, 30, hwnd, idBtnKeyboard)

    // ── About section (folded in from the old standalone About link) ──
    _ = makeControl("STATIC", "", 0x0010 /* SS_ETCHEDHORZ */, 20, 202, 342, 1, hwnd, 0)
    _ = makeControl("STATIC", "reLayout  ·  version \(appVersion)", 0, 20, 214, 342, 20, hwnd, 0)
    _ = makeControl("STATIC", "Retype selection in the correct keyboard layout", 0, 20, 234, 342, 20, hwnd, 0)
    _ = makeControl("STATIC", "© 2026 Volodymyr Forfutdinov", 0, 20, 254, 342, 20, hwnd, 0)
    _ = makeControl("SysLink", "<a>github.com/vladforfutdinov/reLayout</a>",
                    Int32(WS_TABSTOP), 20, 276, 342, 22, hwnd, idLnkAbout)

    _ = makeControl("BUTTON", "Close",
                    Int32(WS_TABSTOP), 262, 308, 100, 30, hwnd, idBtnClose)
}

private func sizeAndCenter(_ hwnd: HWND?) {
    // Grow to fit the scaled client area, using the actual (already DPI-correct)
    // non-client delta — avoids AdjustWindowRectExForDpi's BOOL parameter.
    var wr = RECT(); GetWindowRect(hwnd, &wr)
    var cr = RECT(); GetClientRect(hwnd, &cr)
    let ncw = (wr.right - wr.left) - (cr.right - cr.left)
    let nch = (wr.bottom - wr.top) - (cr.bottom - cr.top)
    let w = sc(380) + ncw
    let h = sc(352) + nch
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
        let w = UInt(truncatingIfNeeded: wParam)
        let code = Int((w >> 16) & 0xFFFF)
        switch Int(w & 0xFFFF) {
        case idChkStartup:
            let checked = SendMessageW(GetDlgItem(hwnd, Int32(idChkStartup)), UINT(BM_GETCHECK), 0, 0)
            setStartup(checked == LRESULT(BST_CHECKED))
        case idBtnKeyboard: openExternally("ms-settings:keyboard")
        case idBtnReset:    setHotkeyControl(hwnd, defaultHotkey.mods, defaultHotkey.vk); applyHotkeyFromControl(hwnd)
        case idBtnApply:    applyHotkeyFromControl(hwnd)
        case idBtnClose:    DestroyWindow(hwnd)
        case idCombo where code == 1:   // CBN_SELCHANGE
            let sel = SendMessageW(GetDlgItem(hwnd, Int32(idCombo)), CB_GETCURSEL_, 0, 0)
            saveTrayMode(Int(sel))
            applyTrayMode()
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
