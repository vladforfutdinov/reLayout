import WinSDK

// Tooltips for the Settings and Exceptions windows. The tooltip window is owned by
// `parent`, so it goes away with it; `tooltip` holds it for reuse and cleanup.

/// Shows `text` while the mouse is over `control`. A control that takes the mouse
/// (a button) is its own tool; a static one is passed as a rectangle of the window,
/// since the static lets the mouse through to it.
/// - Parameter tooltip: the window's tooltip control, created on first use.
func addTooltip(_ tooltip: inout HWND?, _ parent: HWND?, _ control: HWND?, _ text: String, overWindow: Bool = false) {
    if tooltip == nil {
        tooltip = "tooltips_class32".withCString(encodedAs: UTF16.self) { cls in
            CreateWindowExW(DWORD(WS_EX_TOPMOST), cls, nil,
                            DWORD(WS_POPUP) | DWORD(0x01 /* TTS_ALWAYSTIP */),
                            0, 0, 0, 0, parent, nil, GetModuleHandleW(nil), nil)
        }
        SendMessageW(tooltip, UINT(0x0418 /* TTM_SETMAXTIPWIDTH */), 0, LPARAM(320 * Int32(GetDpiForWindow(parent)) / 96))
    }
    guard let tip = tooltip, let control else { return }
    text.withCString(encodedAs: UTF16.self) { txt in
        var info = TTTOOLINFOW()
        info.cbSize = UINT(MemoryLayout<TTTOOLINFOW>.size)
        info.hwnd = parent
        if overWindow {
            info.uFlags = UINT(0x0010 /* TTF_SUBCLASS */)
            info.uId = UINT_PTR(UInt(bitPattern: Int(GetDlgCtrlID(control))))
            var r = RECT()
            GetWindowRect(control, &r)
            withUnsafeMutablePointer(to: &r) {
                $0.withMemoryRebound(to: POINT.self, capacity: 2) { _ = MapWindowPoints(nil, parent, $0, 2) }
            }
            info.rect = r
        } else {
            info.uFlags = UINT(0x0001 /* TTF_IDISHWND */ | 0x0010 /* TTF_SUBCLASS */)
            info.uId = UINT_PTR(UInt(bitPattern: control))
        }
        info.lpszText = UnsafeMutablePointer(mutating: txt)
        _ = withUnsafeMutablePointer(to: &info) {
            SendMessageW(tip, UINT(0x0432 /* TTM_ADDTOOLW */), 0, LPARAM(Int(bitPattern: $0)))
        }
    }
}

