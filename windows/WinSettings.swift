import WinSDK

// Native Settings window opened from the tray. Themed (ComCtl32 v6 via the app
// manifest), Segoe UI, DPI-scaled and centered: UI language, the convert-hotkey
// recorder, auto-correct and its options, launch at login, a shortcut to Windows
// keyboard settings, and an About section. Lives on the app's single UI thread.
// The controls are rebuilt, not patched, when the language or the DPI changes.

private let idChkStartup:  Int = 101
private let idBtnKeyboard: Int = 102
private let idBtnClose:    Int = 103
private let idLnkAbout:    Int = 104
private let idHotkeyField: Int = 105
private let idBtnSet:      Int = 106
private let idBtnReset:    Int = 107
private let idChkDouble:   Int = 108
private let idChkAuto:     Int = 109
private let idChkAutoEnter: Int = 110
private let idBtnExceptions: Int = 111
private let idCmbLanguage: Int = 112

private var settingsHwnd: HWND?
private var settingsClassW = Array("ReLayoutSettingsWnd".utf16) + [0]
private var settingsClassRegistered = false

private var uiDpi: Int32 = 96
private var uiFont: HFONT?

// NM_CLICK / NM_RETURN as UINT (NM_FIRST is 0, so these are 0u-2 / 0u-4).
private let nmClick  = UINT(bitPattern: -2)
private let nmReturn = UINT(bitPattern: -4)

private func sc(_ v: Int32) -> Int32 { v * uiDpi / 96 }   // scale a 96-dpi coord

// Client area at 96 dpi.
private let clientWidth: Int32 = 440
private let clientHeight: Int32 = 436

private func makeFont() {
    if let f = uiFont { DeleteObject(UnsafeMutableRawPointer(f)) }
    uiFont = "Segoe UI".withCString(encodedAs: UTF16.self) { f in
        CreateFontW(-(9 * uiDpi / 72), 0, 0, 0, Int32(FW_NORMAL),
                    0, 0, 0,
                    DWORD(DEFAULT_CHARSET), DWORD(OUT_DEFAULT_PRECIS),
                    DWORD(CLIP_DEFAULT_PRECIS), DWORD(CLEARTYPE_QUALITY),
                    DWORD(DEFAULT_PITCH), f)
    }
}

/// The Settings font, shared with the Exceptions window (opened from here).
func settingsFont() -> HFONT? { uiFont }

private func applyFont(_ h: HWND?) {
    SendMessageW(h, UINT(WM_SETFONT), unsafeBitCast(uiFont, to: WPARAM.self), LPARAM(1))
}

private func makeControl(_ cls: String, _ text: String, _ style: Int32,
                         _ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32,
                         _ parent: HWND?, _ id: Int, exStyle: DWORD = 0) -> HWND? {
    let hInst = GetModuleHandleW(nil)
    return cls.withCString(encodedAs: UTF16.self) { clsP in
        text.withCString(encodedAs: UTF16.self) { txtP in
            let ctl = CreateWindowExW(exStyle, clsP, txtP,
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

private func check(_ ctl: HWND?, _ on: Bool) {
    SendMessageW(ctl, UINT(BM_SETCHECK), WPARAM(on ? 1 : 0), 0)
}

private func buildControls(_ hwnd: HWND?) {
    L("settings.title").withCString(encodedAs: UTF16.self) { _ = SetWindowTextW(hwnd, $0) }

    // UI language: "System Default" first, then the shipped ones by their own name.
    _ = makeControl("STATIC", L("settings.language"), 0, 20, 19, 110, 20, hwnd, 0)
    let lang = makeControl("COMBOBOX", "", Int32(0x0003 /* CBS_DROPDOWNLIST */) | Int32(WS_VSCROLL) | Int32(WS_TABSTOP),
                           140, 15, 280, 240, hwnd, idCmbLanguage)
    let names = [L("settings.language.system")] + WinLoc.languages.map(\.name)
    for name in names {
        name.withCString(encodedAs: UTF16.self) {
            _ = SendMessageW(lang, UINT(0x0143 /* CB_ADDSTRING */), 0, LPARAM(Int(bitPattern: $0)))
        }
    }
    let selected = loadLanguage().flatMap { code in WinLoc.languages.firstIndex { $0.code == code } }.map { $0 + 1 } ?? 0
    SendMessageW(lang, UINT(0x014E /* CB_SETCURSEL */), WPARAM(selected), 0)

    // Read-only field showing the current hotkey; "Set" captures a new one
    // (including a bare modifier like Left Shift); "Reset" restores the default.
    _ = makeControl("STATIC", L("settings.hotkey"), 0, 20, 55, 100, 20, hwnd, 0)
    let cur = loadHotkey()
    // Themed sunken edge, like a native field (WS_BORDER draws a flat black frame).
    _ = makeControl("EDIT", hotkeyLabel(cur.mods, cur.vk),
                    Int32(0x0800) /* ES_READONLY */ | Int32(0x0080) /* ES_AUTOHSCROLL */ | Int32(WS_TABSTOP),
                    124, 52, 136, 24, hwnd, idHotkeyField, exStyle: DWORD(WS_EX_CLIENTEDGE))
    _ = makeControl("BUTTON", L("win.set"),   Int32(WS_TABSTOP), 266, 51, 70, 26, hwnd, idBtnSet)
    _ = makeControl("BUTTON", L("win.reset"), Int32(WS_TABSTOP), 342, 51, 78, 26, hwnd, idBtnReset)

    check(makeControl("BUTTON", L("win.doubleTap"),
                      Int32(BS_AUTOCHECKBOX) | Int32(WS_TABSTOP), 20, 88, 400, 22, hwnd, idChkDouble),
          loadDoubleTap())

    // Needs a Cyrillic and a Latin layout: the decision is cross-script only.
    let available = WinLayout.crossScriptAvailable()
    let auto = makeControl("BUTTON", L("settings.autoCorrect"),
                           Int32(BS_AUTOCHECKBOX) | Int32(WS_TABSTOP), 20, 116, 400, 22, hwnd, idChkAuto)
    check(auto, loadAutoMode())
    EnableWindow(auto, available)

    if available {
        // Sub-options of auto-correct: indented, and dead while it is off.
        let onEnter = makeControl("BUTTON", L("settings.autoCorrectEnter"),
                                  Int32(BS_AUTOCHECKBOX) | Int32(WS_TABSTOP), 40, 140, 380, 22, hwnd, idChkAutoEnter)
        check(onEnter, loadAutoEnter())
        EnableWindow(onEnter, loadAutoMode())
        let exceptions = makeControl("BUTTON", L("settings.exceptions"), Int32(WS_TABSTOP),
                                     40, 166, 160, 28, hwnd, idBtnExceptions)
        EnableWindow(exceptions, loadAutoMode())
    } else {
        // Why it is off, in place of its dead sub-options. Not a tooltip: Windows
        // shows none on a disabled control.
        let installed = WinLayout.installedList().map(\.displayName).joined(separator: ", ")
        _ = makeControl("STATIC", L("settings.autoCorrectUnavailable", installed), 0, 40, 140, 380, 56, hwnd, 0)
    }

    let startup = makeControl("BUTTON", L("settings.openAtLogin"),
                              Int32(BS_AUTOCHECKBOX) | Int32(WS_TABSTOP), 20, 206, 400, 22, hwnd, idChkStartup)
    check(startup, startupEnabled())
    if !startupAvailable() { EnableWindow(startup, false) }

    _ = makeControl("BUTTON", L("win.keyboardSettings"), Int32(WS_TABSTOP), 20, 240, 200, 30, hwnd, idBtnKeyboard)

    // ── About section ──
    _ = makeControl("STATIC", "", 0x0010 /* SS_ETCHEDHORZ */, 20, 284, 400, 1, hwnd, 0)
    _ = makeControl("STATIC", "reLayout  ·  \(L("win.version", appVersion))", 0, 20, 296, 400, 20, hwnd, 0)
    _ = makeControl("STATIC", L("win.tagline"), 0, 20, 316, 400, 20, hwnd, 0)
    _ = makeControl("STATIC", "© 2026 Volodymyr Forfutdinov", 0, 20, 336, 400, 20, hwnd, 0)
    _ = makeControl("SysLink", "<a>github.com/\(repoSlug)</a>",
                    Int32(WS_TABSTOP), 20, 358, 400, 22, hwnd, idLnkAbout)

    _ = makeControl("BUTTON", L("win.close"), Int32(WS_TABSTOP), 320, 392, 100, 30, hwnd, idBtnClose)
}

/// Destroys every control and builds them again — for a language or DPI change.
private func rebuildControls(_ hwnd: HWND?) {
    cancelHotkeyCapture()   // its callbacks target the field being destroyed
    var child = GetWindow(hwnd, UINT(GW_CHILD))
    while let c = child {
        child = GetWindow(c, UINT(GW_HWNDNEXT))
        DestroyWindow(c)
    }
    makeFont()
    buildControls(hwnd)
}

/// Sizes the window to the scaled client area, keeping its position.
private func fitClientArea(_ hwnd: HWND?) {
    var wr = RECT(); GetWindowRect(hwnd, &wr)
    var cr = RECT(); GetClientRect(hwnd, &cr)
    SetWindowPos(hwnd, nil, 0, 0,
                 sc(clientWidth) + (wr.right - wr.left) - (cr.right - cr.left),
                 sc(clientHeight) + (wr.bottom - wr.top) - (cr.bottom - cr.top),
                 UINT(SWP_NOMOVE) | UINT(SWP_NOZORDER))
}

private func sizeAndCenter(_ hwnd: HWND?) {
    // Grow to fit the scaled client area, using the actual (already DPI-correct)
    // non-client delta — avoids AdjustWindowRectExForDpi's BOOL parameter.
    var wr = RECT(); GetWindowRect(hwnd, &wr)
    var cr = RECT(); GetClientRect(hwnd, &cr)
    let ncw = (wr.right - wr.left) - (cr.right - cr.left)
    let nch = (wr.bottom - wr.top) - (cr.bottom - cr.top)
    let w = sc(clientWidth) + ncw
    let h = sc(clientHeight) + nch
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
        makeFont()
        buildControls(hwnd)
        sizeAndCenter(hwnd)
    case UINT(0x02E0 /* WM_DPICHANGED */):
        // Moved to a monitor with another scale: rebuild at the new DPI and take the
        // position Windows suggests.
        uiDpi = Int32((UInt(truncatingIfNeeded: wParam) >> 16) & 0xFFFF)
        rebuildControls(hwnd)
        if let suggested = UnsafeRawPointer(bitPattern: Int(lParam))?.assumingMemoryBound(to: RECT.self).pointee {
            SetWindowPos(hwnd, nil, suggested.left, suggested.top, 0, 0, UINT(SWP_NOSIZE) | UINT(SWP_NOZORDER))
        }
        fitClientArea(hwnd)
        return 0
    case UINT(WM_COMMAND):
        let notification = (UInt(truncatingIfNeeded: wParam) >> 16) & 0xFFFF
        switch Int(UInt(truncatingIfNeeded: wParam) & 0xFFFF) {
        case idCmbLanguage where notification == 1 /* CBN_SELCHANGE */:
            let index = Int(SendMessageW(GetDlgItem(hwnd, Int32(idCmbLanguage)), UINT(0x0147 /* CB_GETCURSEL */), 0, 0))
            saveLanguage(index > 0 && index <= WinLoc.languages.count ? WinLoc.languages[index - 1].code : nil)
            WinLoc.load()
            rebuildControls(hwnd)
        case idChkStartup:
            let checked = SendMessageW(GetDlgItem(hwnd, Int32(idChkStartup)), UINT(BM_GETCHECK), 0, 0)
            setStartup(checked == LRESULT(BST_CHECKED))
            refreshSettingsStartup()   // shows a failed registry write as unchecked
        case idChkAuto:
            let checked = SendMessageW(GetDlgItem(hwnd, Int32(idChkAuto)), UINT(BM_GETCHECK), 0, 0)
            saveAutoMode(checked == LRESULT(BST_CHECKED))
            reloadAutoMode()
            EnableWindow(GetDlgItem(hwnd, Int32(idChkAutoEnter)), checked == LRESULT(BST_CHECKED))
            EnableWindow(GetDlgItem(hwnd, Int32(idBtnExceptions)), checked == LRESULT(BST_CHECKED))
        case idChkAutoEnter:
            let checked = SendMessageW(GetDlgItem(hwnd, Int32(idChkAutoEnter)), UINT(BM_GETCHECK), 0, 0)
            saveAutoEnter(checked == LRESULT(BST_CHECKED))
            reloadAutoMode()
        case idChkDouble:
            let checked = SendMessageW(GetDlgItem(hwnd, Int32(idChkDouble)), UINT(BM_GETCHECK), 0, 0)
            saveDoubleTap(checked == LRESULT(BST_CHECKED))
        case idBtnExceptions: openExceptions(owner: hwnd)
        case idBtnKeyboard: openExternally("ms-settings:keyboard")
        case idBtnSet:
            setFieldText(hwnd, idHotkeyField, L("win.pressKey"))
            startHotkeyCapture(onLive: { s in setFieldText(hwnd, idHotkeyField, s) },
                               onDone: { mods, vk in applyHotkey(hwnd, mods, vk) })
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
    case UINT(WM_NCDESTROY):        // children are gone, the font is free
        if let f = uiFont { DeleteObject(UnsafeMutableRawPointer(f)); uiFont = nil }
    default:
        break
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam)
}

/// The open Settings window, for keyboard navigation in the message loop.
func settingsWindow() -> HWND? { settingsHwnd }

/// Syncs the open Settings window's launch-at-login checkbox with the registry.
func refreshSettingsStartup() {
    guard let hwnd = settingsHwnd else { return }
    SendMessageW(GetDlgItem(hwnd, Int32(idChkStartup)), UINT(BM_SETCHECK), WPARAM(startupEnabled() ? 1 : 0), 0)
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
            settingsClassRegistered = RegisterClassW(&wc) != 0
        }
    }
    guard settingsClassRegistered else { return }

    let style = DWORD(WS_OVERLAPPED) | DWORD(WS_CAPTION) | DWORD(WS_SYSMENU)
    settingsHwnd = settingsClassW.withUnsafeBufferPointer { name in
        L("settings.title").withCString(encodedAs: UTF16.self) { title in
            CreateWindowExW(0, name.baseAddress, title, style,
                            Int32(CW_USEDEFAULT), Int32(CW_USEDEFAULT), 400, 240,
                            nil, nil, hInst, nil)
        }
    }
    ShowWindow(settingsHwnd, SW_SHOW)
    SetForegroundWindow(settingsHwnd)
}
