import WinSDK

// System-tray presence: a hidden window receives the tray callback and shows a
// right-click menu. Menu mirrors the macOS app: a header, the convert hotkey
// hint, a launch-at-login toggle, a shortcut to Windows keyboard settings, an
// About link, and Quit. (Live layout badge / Settings UI come later.)

private let trayCallback = UINT(WM_APP) + 1

private let menuSettings: UINT = 1
private let menuStartup:  UINT = 2
private let menuQuit:     UINT = 3
private let menuLayoutBase: UINT = 200    // installed-layout items use 200, 201, …

private var menuLayouts: [WinLayout] = [] // captured when the menu is shown
private var prevForeground: HWND?         // app that was active before we popped the menu

let aboutURL = "https://github.com/vladforfutdinov/reLayout"

private var trayHwnd: HWND?
private var nid = NOTIFYICONDATAW()
private var classNameW = Array("ReLayoutTrayWnd".utf16) + [0]

// HKEY_CURRENT_USER is a cast macro in WinSDK and isn't surfaced to Swift.
private let kHKCU = HKEY(bitPattern: 0x8000_0001)!
private let runSubKey   = "Software\\Microsoft\\Windows\\CurrentVersion\\Run"
private let runValueKey = "reLayout"

// MARK: - launch at login (HKCU\...\Run value pointing at this exe)

private func exePath() -> String {
    var buf = [WCHAR](repeating: 0, count: 1024)
    _ = GetModuleFileNameW(nil, &buf, DWORD(buf.count))
    return String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF16.self)
}

func startupEnabled() -> Bool {
    var key: HKEY?
    let opened = runSubKey.withCString(encodedAs: UTF16.self) {
        RegOpenKeyExW(kHKCU, $0, 0, REGSAM(0x0001 /* KEY_QUERY_VALUE */), &key)  // 0 == ERROR_SUCCESS
    }
    guard opened == 0, let key else { return false }
    defer { RegCloseKey(key) }
    let found = runValueKey.withCString(encodedAs: UTF16.self) {
        RegQueryValueExW(key, $0, nil, nil, nil, nil)
    }
    return found == 0
}

func setStartup(_ on: Bool) {
    var key: HKEY?
    let opened = runSubKey.withCString(encodedAs: UTF16.self) {
        RegOpenKeyExW(kHKCU, $0, 0, REGSAM(0x0002 /* KEY_SET_VALUE */), &key)
    }
    guard opened == 0, let key else { return }
    defer { RegCloseKey(key) }
    runValueKey.withCString(encodedAs: UTF16.self) { namePtr in
        if on {
            // Quote the path so a Program Files path with spaces survives.
            let value = Array("\"\(exePath())\"".utf16) + [0]
            value.withUnsafeBytes { raw in
                _ = RegSetValueExW(key, namePtr, 0, DWORD(1 /* REG_SZ */),
                                   raw.bindMemory(to: BYTE.self).baseAddress,
                                   DWORD(raw.count))
            }
        } else {
            _ = RegDeleteValueW(key, namePtr)
        }
    }
}

// MARK: - shell helpers

func openExternally(_ s: String) {
    s.withCString(encodedAs: UTF16.self) { file in
        "open".withCString(encodedAs: UTF16.self) { op in
            _ = ShellExecuteW(nil, op, file, nil, nil, Int32(SW_SHOWNORMAL))
        }
    }
}

// MARK: - menu

private func appendItem(_ menu: HMENU?, _ id: UINT, _ title: String, flags: UINT = UINT(MF_STRING)) {
    title.withCString(encodedAs: UTF16.self) { p in
        _ = AppendMenuW(menu, flags, UINT_PTR(id), p)
    }
}

// Localized key name for a virtual-key (e.g. "R", "F2"), via the scan code.
private func keyName(_ vk: UINT) -> String {
    let scan = MapVirtualKeyW(vk, 0 /* MAPVK_VK_TO_VSC */)
    var buf = [WCHAR](repeating: 0, count: 32)
    let n = GetKeyNameTextW(LONG(scan << 16), &buf, Int32(buf.count))
    return n > 0 ? String(decoding: buf.prefix(Int(n)), as: UTF16.self) : "?"
}

// Human label for the current convert hotkey, e.g. "Ctrl+Alt+R".
private func hotkeyLabel() -> String {
    let hk = loadHotkey()
    var parts: [String] = []
    if hk.mods & UINT(MOD_CONTROL) != 0 { parts.append("Ctrl") }
    if hk.mods & UINT(MOD_ALT)     != 0 { parts.append("Alt") }
    if hk.mods & UINT(MOD_SHIFT)   != 0 { parts.append("Shift") }
    if hk.mods & UINT(MOD_WIN)     != 0 { parts.append("Win") }
    parts.append(keyName(hk.vk))
    return parts.joined(separator: "+")
}

private func showTrayMenu(_ hwnd: HWND?) {
    guard let menu = CreatePopupMenu() else { return }

    // Layout chooser mirroring the system input switcher: every installed layout,
    // a checkmark on the active one, click to switch the previously-active app.
    prevForeground = GetForegroundWindow()
    menuLayouts = WinLayout.installedList()
    let tid = GetWindowThreadProcessId(prevForeground, nil)
    let curLow = unsafeBitCast(GetKeyboardLayout(tid), to: UInt.self) & 0xFFFF
    for (i, lay) in menuLayouts.enumerated() {
        let on = (unsafeBitCast(lay.hkl, to: UInt.self) & 0xFFFF) == curLow
        let flags = UINT(MF_STRING) | (on ? UINT(MF_CHECKED) : UINT(MF_UNCHECKED))
        appendItem(menu, menuLayoutBase + UINT(i), lay.displayName, flags: flags)
    }
    if !menuLayouts.isEmpty { _ = AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil) }

    appendItem(menu, menuSettings, "Settings…")
    let startupFlags = UINT(MF_STRING) | (startupEnabled() ? UINT(MF_CHECKED) : UINT(MF_UNCHECKED))
    appendItem(menu, menuStartup, "Launch at login", flags: startupFlags)
    _ = AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
    appendItem(menu, menuQuit, "Quit reLayout")

    var pt = POINT()
    GetCursorPos(&pt)
    SetForegroundWindow(hwnd)   // so the menu dismisses on outside click
    _ = TrackPopupMenu(menu, UINT(TPM_RIGHTBUTTON), pt.x, pt.y, 0, hwnd, nil)
    DestroyMenu(menu)
}

private func handleCommand(_ id: UINT) {
    // Layout chooser item -> switch the previously-active app to that layout.
    if id >= menuLayoutBase, Int(id - menuLayoutBase) < menuLayouts.count {
        switchLayout(to: menuLayouts[Int(id - menuLayoutBase)], target: prevForeground)
        return
    }
    switch id {
    case menuSettings: openSettings()
    case menuStartup:  setStartup(!startupEnabled())
    case menuQuit:     PostQuitMessage(0)
    default:           break
    }
}

// MARK: - tray icon mode (static logo vs live layout code)

private let trayTimerID = UINT_PTR(1)
private var trayMode = 0           // 0 = static logo, 1 = live layout code
private var lastTrayCode = ""
private var dynamicIcon: HICON?    // current text icon, owned (DestroyIcon on swap)

private func appIcon() -> HICON? {
    LoadIconW(GetModuleHandleW(nil), UnsafePointer<WCHAR>(bitPattern: 1))
        ?? LoadIconW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
}

// True when the taskbar uses the light theme (so the layout-code icon should be
// drawn in dark text, matching the system input indicator).
private func taskbarUsesLightTheme() -> Bool {
    var data: DWORD = 0
    var cb = DWORD(MemoryLayout<DWORD>.size)
    let r = "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize".withCString(encodedAs: UTF16.self) { sp in
        "SystemUsesLightTheme".withCString(encodedAs: UTF16.self) { vp in
            withUnsafeMutablePointer(to: &data) { dp in
                dp.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<DWORD>.size) { bp in
                    RegGetValueW(kHKCU, sp, vp, DWORD(0x18 /* RRF_RT_REG_DWORD */), nil, bp, &cb)
                }
            }
        }
    }
    return r == 0 && data == 1
}

// Two-letter code for the foreground layout, e.g. "EN", "UK".
// Cheap (no map building) so the 400 ms poll stays light.
private func currentLayoutCode() -> String {
    WinLayout.currentDisplayCode()
}

// Render the layout code as a tray icon that fills its square cell with no
// padding — drawn at the exact small-icon size (no shell downscaling) using the
// system UI font: full cell height, condensed width so the 3-letter code fits
// edge to edge. Text colour follows the taskbar theme; corners stay transparent.
private func makeTextIcon(_ text: String) -> HICON? {
    let S = max(Int32(16), GetSystemMetrics(49 /* SM_CXSMICON */))   // actual tray cell size
    let nChars = max(Int32(1), Int32(Array(text.utf16).count))

    guard let screen = GetDC(nil) else { return nil }
    defer { ReleaseDC(nil, screen) }
    guard let hdc = CreateCompatibleDC(screen) else { return nil }
    defer { DeleteDC(hdc) }

    var bmi = BITMAPINFO()
    bmi.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
    bmi.bmiHeader.biWidth = S
    bmi.bmiHeader.biHeight = -S            // top-down
    bmi.bmiHeader.biPlanes = 1
    bmi.bmiHeader.biBitCount = 32
    bmi.bmiHeader.biCompression = 0        // BI_RGB
    var bits: UnsafeMutableRawPointer?
    guard let dib = CreateDIBSection(hdc, &bmi, 0 /* DIB_RGB_COLORS */, &bits, nil, 0) else { return nil }
    let oldBmp = SelectObject(hdc, dib)

    // System UI font: full cell height, width condensed to fit nChars across the
    // cell so the glyphs fill the square (no internal padding).
    var ncm = NONCLIENTMETRICSW()
    ncm.cbSize = DWORD(MemoryLayout<NONCLIENTMETRICSW>.size)
    _ = SystemParametersInfoW(UINT(0x0029 /* SPI_GETNONCLIENTMETRICS */), ncm.cbSize, &ncm, 0)
    var lf = ncm.lfMessageFont
    lf.lfWeight = 600                      // semibold
    lf.lfHeight = -S                       // fill the cell vertically
    lf.lfWidth  = S / nChars               // condense so nChars span the width
    let font = CreateFontIndirectW(&lf)
    let oldFont = SelectObject(hdc, font)

    SetBkMode(hdc, 1 /* TRANSPARENT */)
    SetTextColor(hdc, COLORREF(0x00FF_FFFF))           // white — used as alpha coverage
    var rc = RECT(left: 0, top: 0, right: S, bottom: S)
    text.withCString(encodedAs: UTF16.self) { p in
        _ = DrawTextW(hdc, p, -1, &rc, UINT(0x125) /* DT_CENTER|DT_VCENTER|DT_SINGLELINE|DT_NOCLIP */)
    }
    GdiFlush()

    // Recolour: alpha = white coverage, RGB = theme text colour (straight alpha).
    let dark: UInt32 = taskbarUsesLightTheme() ? 0x0020_2020 : 0x00FF_FFFF
    if let p = bits {
        let px = p.assumingMemoryBound(to: UInt32.self)
        for i in 0..<Int(S * S) {
            let cov = px[i] & 0xFF
            px[i] = cov == 0 ? 0 : ((cov << 24) | dark)
        }
    }

    SelectObject(hdc, oldFont)
    SelectObject(hdc, oldBmp)
    if let font { DeleteObject(font) }

    // AND mask must be all-zero (the 32-bit alpha channel carries the shape).
    // CreateBitmap with nil bits is UNINITIALISED -> garbled icon; pass zeros.
    let stride = ((Int(S) + 15) / 16) * 2              // 1bpp rows are WORD-aligned
    let maskBytes = [UInt8](repeating: 0, count: stride * Int(S))
    var ii = ICONINFO()
    ii.fIcon = true
    ii.hbmColor = dib
    ii.hbmMask = maskBytes.withUnsafeBytes { CreateBitmap(S, S, 1, 1, $0.baseAddress) }
    let icon = CreateIconIndirect(&ii)
    if let m = ii.hbmMask { DeleteObject(m) }
    DeleteObject(dib)
    return icon
}

private func setTrayIcon(_ icon: HICON?) {
    nid.hIcon = icon
    _ = Shell_NotifyIconW(DWORD(NIM_MODIFY), &nid)
}

private func refreshTrayIcon() {
    guard trayMode == 1 else { return }
    let code = currentLayoutCode()
    guard code != lastTrayCode else { return }
    lastTrayCode = code
    let newIcon = makeTextIcon(code)
    setTrayIcon(newIcon)
    if let old = dynamicIcon { DestroyIcon(old) }
    dynamicIcon = newIcon
}

// Apply the saved tray mode: start polling for layout changes, or revert to the
// static logo. Called at startup and when the Settings combo changes.
func applyTrayMode() {
    trayMode = loadTrayMode()
    guard let hwnd = trayHwnd else { return }
    if trayMode == 1 {
        lastTrayCode = ""
        refreshTrayIcon()
        _ = SetTimer(hwnd, trayTimerID, 400, nil)
    } else {
        _ = KillTimer(hwnd, trayTimerID)
        setTrayIcon(appIcon())
        if let old = dynamicIcon { DestroyIcon(old); dynamicIcon = nil }
        lastTrayCode = ""
    }
}

// Top-level (capture-free) so it can be used as a C WNDPROC function pointer.
private func trayWndProc(_ hwnd: HWND?, _ msg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    switch msg {
    case trayCallback:
        let ev = UINT(truncatingIfNeeded: lParam) & 0xFFFF
        if ev == UINT(WM_RBUTTONUP) || ev == UINT(WM_LBUTTONUP) { showTrayMenu(hwnd) }
    case UINT(WM_TIMER):
        refreshTrayIcon()
    case UINT(WM_COMMAND):
        handleCommand(UINT(truncatingIfNeeded: wParam) & 0xFFFF)
    case UINT(WM_DESTROY):
        PostQuitMessage(0)
    default:
        break
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam)
}

func setupTray() -> Bool {
    let hInst = GetModuleHandleW(nil)
    let created = classNameW.withUnsafeBufferPointer { name -> Bool in
        var wc = WNDCLASSW()
        wc.lpfnWndProc = trayWndProc
        wc.hInstance = hInst
        wc.lpszClassName = name.baseAddress
        _ = RegisterClassW(&wc)
        trayHwnd = CreateWindowExW(0, name.baseAddress, nil, 0, 0, 0, 0, 0, nil, nil, hInst, nil)
        return trayHwnd != nil
    }
    guard created, let hwnd = trayHwnd else { return false }
    nid.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
    nid.hWnd = hwnd
    nid.uID = 1
    nid.uFlags = UINT(NIF_ICON) | UINT(NIF_MESSAGE) | UINT(NIF_TIP)
    nid.uCallbackMessage = trayCallback
    // Our embedded app icon (resource id 1 from relayout.rc); fall back to the
    // system application icon if the resource is somehow missing.
    nid.hIcon = LoadIconW(GetModuleHandleW(nil), UnsafePointer<WCHAR>(bitPattern: 1))
             ?? LoadIconW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
    writeTooltip()                              // hover tooltip = "reLayout — <hotkey>"
    let added = Shell_NotifyIconW(DWORD(NIM_ADD), &nid)
    applyTrayMode()          // honor saved tray mode (may start the layout-poll timer)
    return added
}

// Fill nid.szTip from the current hotkey (does not push to the shell on its own).
private func writeTooltip() {
    let tip = Array("reLayout — \(hotkeyLabel())".utf16) + [0]
    withUnsafeMutableBytes(of: &nid.szTip) { dst in
        memset(dst.baseAddress, 0, dst.count)
        tip.withUnsafeBytes { src in
            memcpy(dst.baseAddress, src.baseAddress, min(dst.count, src.count))
        }
    }
}

// Refresh the hover tooltip after the hotkey changes (called from Settings).
func updateTrayTooltip() {
    guard trayHwnd != nil else { return }
    writeTooltip()
    _ = Shell_NotifyIconW(DWORD(NIM_MODIFY), &nid)
}

func removeTray() {
    _ = Shell_NotifyIconW(DWORD(NIM_DELETE), &nid)
}
