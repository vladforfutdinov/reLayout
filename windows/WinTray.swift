import WinSDK

// System-tray presence: a hidden window receives the tray callback and shows a
// right-click menu. Menu mirrors the macOS app: a header, the convert hotkey
// hint, a launch-at-login toggle, a shortcut to Windows keyboard settings, an
// About link, and Quit. (Live layout badge / Settings UI come later.)

private let trayCallback = UINT(WM_APP) + 1

private let menuSettings: UINT = 1
private let menuStartup:  UINT = 2
private let menuQuit:     UINT = 3

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

private func showTrayMenu(_ hwnd: HWND?) {
    guard let menu = CreatePopupMenu() else { return }
    let disabled = UINT(MF_STRING) | UINT(MF_GRAYED)
    appendItem(menu, 0, "reLayout", flags: disabled)
    appendItem(menu, 0, "Convert: Ctrl+Alt+R", flags: disabled)
    _ = AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
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

// Two-letter code for the foreground layout, e.g. "EN", "UK".
// Cheap (no map building) so the 400 ms poll stays light.
private func currentLayoutCode() -> String {
    WinLayout.currentDisplayCode()
}

// Render a 32×32 icon with `text` (white glyph, transparent elsewhere) via a
// 32-bit top-down DIB; alpha is set opaque wherever GDI drew the text.
private func makeTextIcon(_ text: String) -> HICON? {
    let S: Int32 = 32
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

    // Dark rounded tile so the white code stays readable on any taskbar colour.
    // (Pixels left at rgb 0 become transparent via the alpha pass below.)
    let dark = COLORREF(0x0028_2828)
    let brush = CreateSolidBrush(dark)
    let pen   = CreatePen(0 /* PS_SOLID */, 1, dark)
    let oldBrush = SelectObject(hdc, brush)
    let oldPen   = SelectObject(hdc, pen)
    RoundRect(hdc, 0, 0, S, S, 10, 10)
    SelectObject(hdc, oldBrush)
    SelectObject(hdc, oldPen)
    DeleteObject(brush)
    DeleteObject(pen)

    let font: HFONT? = "Segoe UI".withCString(encodedAs: UTF16.self) { f in
        CreateFontW(-26, 0, 0, 0, 600 /* FW_SEMIBOLD */, 0, 0, 0,
                    DWORD(DEFAULT_CHARSET), DWORD(OUT_DEFAULT_PRECIS),
                    DWORD(CLIP_DEFAULT_PRECIS), DWORD(CLEARTYPE_QUALITY),
                    DWORD(DEFAULT_PITCH), f)
    }
    let oldFont = SelectObject(hdc, font)
    SetBkMode(hdc, 1 /* TRANSPARENT */)
    SetTextColor(hdc, COLORREF(0x00FF_FFFF))   // white
    var rc = RECT(left: 0, top: 0, right: S, bottom: S)
    text.withCString(encodedAs: UTF16.self) { p in
        _ = DrawTextW(hdc, p, -1, &rc, UINT(0x25) /* DT_CENTER|DT_VCENTER|DT_SINGLELINE */)
    }
    GdiFlush()

    if let p = bits {
        let px = p.assumingMemoryBound(to: UInt32.self)
        for i in 0..<Int(S * S) {
            let rgb = px[i] & 0x00FF_FFFF
            px[i] = rgb != 0 ? (rgb | 0xFF00_0000) : 0
        }
    }

    SelectObject(hdc, oldFont)
    SelectObject(hdc, oldBmp)
    if let font { DeleteObject(font) }

    // AND mask must be all-zero (the 32-bit alpha channel carries the shape).
    // CreateBitmap with nil bits is UNINITIALISED -> garbled icon; pass zeros.
    let maskBytes = [UInt8](repeating: 0, count: Int(S) * 4)   // 1bpp, 4-byte aligned rows
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
    // Tooltip shown on hover.
    let tip = Array("reLayout — Ctrl+Alt+R".utf16) + [0]
    withUnsafeMutableBytes(of: &nid.szTip) { dst in
        tip.withUnsafeBytes { src in
            memcpy(dst.baseAddress, src.baseAddress, min(dst.count, src.count))
        }
    }
    let added = Shell_NotifyIconW(DWORD(NIM_ADD), &nid)
    applyTrayMode()          // honor saved tray mode (may start the layout-poll timer)
    return added
}

func removeTray() {
    _ = Shell_NotifyIconW(DWORD(NIM_DELETE), &nid)
}
