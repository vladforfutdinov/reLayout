import WinSDK

// System-tray presence: a hidden window receives the tray callback and shows a
// right-click menu. Menu mirrors the macOS app: a header, the convert hotkey
// hint, a launch-at-login toggle, a shortcut to Windows keyboard settings, an
// About link, and Quit. (Live layout badge / Settings UI come later.)

private let trayCallback = UINT(WM_APP) + 1

private let menuSettings: UINT = 1
private let menuStartup:  UINT = 2
private let menuQuit:     UINT = 3

// repoSlug lives in Identity.swift (CI-stamped, like Version.swift).
let aboutURL = "https://github.com/\(repoSlug)"

private var trayHwnd: HWND?

/// The app's hidden window; owns the clipboard when it is restored.
func trayWindow() -> HWND? { trayHwnd }
private var nid = NOTIFYICONDATAW()
private var classNameW = Array("ReLayoutTrayWnd".utf16) + [0]

// HKEY_CURRENT_USER is a cast macro in WinSDK and isn't surfaced to Swift.
private let kHKCU = HKEY(bitPattern: 0x8000_0001)!
private let runSubKey   = "Software\\Microsoft\\Windows\\CurrentVersion\\Run"
private let runValueKey = "reLayout"

// MARK: - launch at login (HKCU\...\Run value pointing at this exe)

private func exePath() -> String {
    var buf = [WCHAR](repeating: 0, count: 1024)
    while true {   // a full buffer means the path was cut
        let n = Int(GetModuleFileNameW(nil, &buf, DWORD(buf.count)))
        if n < buf.count { return String(decoding: buf.prefix(n), as: UTF16.self) }
        buf = [WCHAR](repeating: 0, count: buf.count * 2)
    }
}

private var runValue: String { "\"\(exePath())\"" }

/// False for the portable build: it runs from a temp folder that is deleted on
/// exit, so a Run entry would point at nothing. CI puts a `portable` marker
/// file next to the exe inside the self-extracting archive.
func startupAvailable() -> Bool {
    var dir = exePath()
    if let i = dir.lastIndex(of: "\\") { dir = String(dir[..<i]) }
    let attrs = "\(dir)\\portable".withCString(encodedAs: UTF16.self) { GetFileAttributesW($0) }
    return attrs == DWORD.max   // INVALID_FILE_ATTRIBUTES
}

/// True only if the Run value points at this exe (a moved app leaves a stale one).
func startupEnabled() -> Bool {
    var key: HKEY?
    let opened = runSubKey.withCString(encodedAs: UTF16.self) {
        RegOpenKeyExW(kHKCU, $0, 0, REGSAM(0x0001 /* KEY_QUERY_VALUE */), &key)  // 0 == ERROR_SUCCESS
    }
    guard opened == 0, let key else { return false }
    defer { RegCloseKey(key) }
    var buf = [WCHAR](repeating: 0, count: 2048)
    var size = DWORD(buf.count * MemoryLayout<WCHAR>.size)
    let found = runValueKey.withCString(encodedAs: UTF16.self) { name in
        buf.withUnsafeMutableBytes {
            RegQueryValueExW(key, name, nil, nil, $0.bindMemory(to: BYTE.self).baseAddress, &size)
        }
    }
    guard found == 0 else { return false }
    let value = String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF16.self)
    return value.lowercased() == runValue.lowercased()
}

/// Writes or deletes the Run value. Callers re-read `startupEnabled()` for the result.
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
            let value = Array(runValue.utf16) + [0]
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

// Label for the current convert hotkey (shared formatter in WinHotkey).
private func currentHotkeyLabel() -> String {
    let hk = loadHotkey()
    return hotkeyLabel(hk.mods, hk.vk)
}

private func showTrayMenu(_ hwnd: HWND?) {
    guard let menu = CreatePopupMenu() else { return }
    appendItem(menu, menuSettings, "Settings…")
    let startupFlags = UINT(MF_STRING) | (startupEnabled() ? UINT(MF_CHECKED) : UINT(MF_UNCHECKED))
    appendItem(menu, menuStartup, "Launch at login",
               flags: startupFlags | (startupAvailable() ? 0 : UINT(MF_GRAYED)))
    _ = AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
    appendItem(menu, menuQuit, "Quit reLayout")

    var pt = POINT()
    GetCursorPos(&pt)
    SetForegroundWindow(hwnd)   // so the menu dismisses on outside click
    _ = TrackPopupMenu(menu, UINT(TPM_RIGHTBUTTON), pt.x, pt.y, 0, hwnd, nil)
    PostMessageW(hwnd, UINT(WM_NULL), 0, 0)   // else the menu may need a second click to close
    DestroyMenu(menu)
}

private func handleCommand(_ id: UINT) {
    switch id {
    case menuSettings: openSettings()
    case menuStartup:  setStartup(!startupEnabled()); refreshSettingsStartup()
    case menuQuit:     PostQuitMessage(0)
    default:           break
    }
}

// Top-level (capture-free) so it can be used as a C WNDPROC function pointer.
private func trayWndProc(_ hwnd: HWND?, _ msg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    switch msg {
    case taskbarCreated where taskbarCreated != 0:
        addTrayIcon()
    case trayCallback:
        let ev = UINT(truncatingIfNeeded: lParam) & 0xFFFF
        if ev == UINT(WM_RBUTTONUP) || ev == UINT(WM_LBUTTONUP) { showTrayMenu(hwnd) }
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
    addTrayIcon()
    return true
}

/// Explorer broadcasts this after it (re)starts: the icon is gone and must be re-added.
/// At autostart the first NIM_ADD may fail for the same reason.
private let taskbarCreated = "TaskbarCreated".withCString(encodedAs: UTF16.self) { RegisterWindowMessageW($0) }

private func addTrayIcon() {
    _ = Shell_NotifyIconW(DWORD(NIM_ADD), &nid)
}

// Fill nid.szTip from the current hotkey (does not push to the shell on its own).
private func writeTooltip() {
    let tip = Array("reLayout — \(currentHotkeyLabel())".utf16) + [0]
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
