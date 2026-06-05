import WinSDK

// Minimal system-tray presence: a hidden window receives the tray callback and
// shows a right-click menu with Quit. (Live layout badge / Settings come later.)

private let trayCallback = UINT(WM_APP) + 1
private let menuQuit: UINT = 1
private var trayHwnd: HWND?
private var nid = NOTIFYICONDATAW()
private var classNameW = Array("ReLayoutTrayWnd".utf16) + [0]

private func showTrayMenu(_ hwnd: HWND?) {
    guard let menu = CreatePopupMenu() else { return }
    "Quit reLayout".withCString(encodedAs: UTF16.self) { p in
        _ = AppendMenuW(menu, UINT(MF_STRING), UINT_PTR(menuQuit), p)
    }
    var pt = POINT()
    GetCursorPos(&pt)
    SetForegroundWindow(hwnd)   // so the menu dismisses on outside click
    _ = TrackPopupMenu(menu, UINT(TPM_RIGHTBUTTON), pt.x, pt.y, 0, hwnd, nil)
    DestroyMenu(menu)
}

// Top-level (capture-free) so it can be used as a C WNDPROC function pointer.
private func trayWndProc(_ hwnd: HWND?, _ msg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    switch msg {
    case trayCallback:
        let ev = UINT(truncatingIfNeeded: lParam) & 0xFFFF
        if ev == UINT(WM_RBUTTONUP) || ev == UINT(WM_LBUTTONUP) { showTrayMenu(hwnd) }
    case UINT(WM_COMMAND):
        if (UINT(truncatingIfNeeded: wParam) & 0xFFFF) == menuQuit { PostQuitMessage(0) }
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
    nid.uFlags = UINT(NIF_ICON) | UINT(NIF_MESSAGE)
    nid.uCallbackMessage = trayCallback
    nid.hIcon = LoadIconW(nil, IDI_APPLICATION)
    return Shell_NotifyIconW(DWORD(NIM_ADD), &nid)
}

func removeTray() {
    _ = Shell_NotifyIconW(DWORD(NIM_DELETE), &nid)
}
