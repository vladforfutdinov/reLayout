import WinSDK

// Win32 plumbing the Settings, Exceptions and Learned windows share. Each window
// keeps its own dpi, font, colors and brush and passes them in.

/// A 96-dpi coordinate scaled to `dpi`.
func scaled(_ v: Int32, dpi: Int32) -> Int32 { v * dpi / 96 }

/// `GetDpiForWindow`, 96 when it reports none.
func windowDpi(_ hwnd: HWND?) -> Int32 {
    let dpi = GetDpiForWindow(hwnd)
    return dpi > 0 ? Int32(dpi) : 96
}

/// A ClearType font of `face` at `points`, scaled to `dpi`.
func makeFont(_ face: String, points: Int32, bold: Bool = false, dpi: Int32) -> HFONT? {
    face.withCString(encodedAs: UTF16.self) { f in
        CreateFontW(-(points * dpi / 72), 0, 0, 0, Int32(bold ? FW_BOLD : FW_NORMAL),
                    0, 0, 0,
                    DWORD(DEFAULT_CHARSET), DWORD(OUT_DEFAULT_PRECIS),
                    DWORD(CLIP_DEFAULT_PRECIS), DWORD(CLEARTYPE_QUALITY),
                    DWORD(DEFAULT_PITCH), f)
    }
}

// The UI font at a given dpi, for the Exceptions and Learned windows. Kept for the
// process's life: Settings rebuilds (and frees) its own font on a theme, language
// or dpi change while those windows may still use theirs.
private var uiFonts: [Int32: HFONT] = [:]

/// The Settings UI font at `dpi`, never freed (see `uiFonts`).
func uiFont(dpi: Int32) -> HFONT? {
    if let f = uiFonts[dpi] { return f }
    let f = makeFont("Segoe UI", points: 9, dpi: dpi)
    uiFonts[dpi] = f
    return f
}

func setFont(_ h: HWND?, _ f: HFONT?) {
    SendMessageW(h, UINT(WM_SETFONT), unsafeBitCast(f, to: WPARAM.self), LPARAM(1))
}

/// A visible child control in `font`, themed for `dark`; the geometry is in 96-dpi
/// units, scaled to `dpi`.
@discardableResult
func createControl(_ cls: String, _ text: String, _ style: Int32,
                   _ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32,
                   _ parent: HWND?, _ id: Int, exStyle: DWORD = 0,
                   dpi: Int32, font: HFONT?, dark: Bool) -> HWND? {
    let hInst = GetModuleHandleW(nil)
    return cls.withCString(encodedAs: UTF16.self) { clsP in
        text.withCString(encodedAs: UTF16.self) { txtP in
            let ctl = CreateWindowExW(exStyle, clsP, txtP,
                                      DWORD(UInt32(bitPattern: style)) | DWORD(WS_CHILD) | DWORD(WS_VISIBLE),
                                      scaled(x, dpi: dpi), scaled(y, dpi: dpi), scaled(w, dpi: dpi), scaled(h, dpi: dpi),
                                      parent, HMENU(bitPattern: id), hInst, nil)
            setFont(ctl, font)
            applyControlTheme(ctl, className: cls, dark: dark)
            return ctl
        }
    }
}

/// Width of `text` in `font`, in 96-dpi units.
func uiTextWidth(_ text: String, _ hwnd: HWND?, font: HFONT?, dpi: Int32) -> Int32 {
    let dc = GetDC(hwnd)
    defer { ReleaseDC(hwnd, dc) }
    let old = SelectObject(dc, UnsafeMutableRawPointer(font))
    defer { SelectObject(dc, old) }
    var size = SIZE()
    let units = Array(text.utf16)
    GetTextExtentPoint32W(dc, units, Int32(units.count), &size)
    return size.cx * 96 / dpi
}

/// Size in device pixels of `text` in `font`, wrapped at `wrapWidth` device pixels.
func measureWrapped(_ text: String, wrapWidth: Int32, _ hwnd: HWND?, font: HFONT?) -> SIZE {
    let dc = GetDC(hwnd)
    defer { ReleaseDC(hwnd, dc) }
    let old = SelectObject(dc, UnsafeMutableRawPointer(font))
    defer { SelectObject(dc, old) }
    var r = RECT(left: 0, top: 0, right: wrapWidth, bottom: 0)
    let units = Array(text.utf16)
    DrawTextW(dc, units, Int32(units.count), &r, UINT(0x400 /* DT_CALCRECT */ | 0x10 /* DT_WORDBREAK */
                                                      | 0x800 /* DT_NOPREFIX */))
    return SIZE(cx: r.right, cy: r.bottom)
}

/// WM_CTLCOLORSTATIC / WM_CTLCOLORBTN result: `text` on the theme's background,
/// transparent over `brush`.
func paintControl(_ wParam: WPARAM, text: COLORREF, _ colors: ThemeColors, _ brush: HBRUSH?) -> LRESULT {
    let dc = HDC(bitPattern: UInt(wParam))
    SetTextColor(dc, text)
    SetBkColor(dc, colors.background)
    SetBkMode(dc, TRANSPARENT)
    return LRESULT(Int(bitPattern: brush))
}

/// WM_CTLCOLOREDIT / WM_CTLCOLORLISTBOX result in the dark theme.
func paintEdit(_ wParam: WPARAM, _ colors: ThemeColors, _ brush: HBRUSH?) -> LRESULT {
    let dc = HDC(bitPattern: UInt(wParam))
    SetTextColor(dc, colors.text)
    SetBkColor(dc, colors.background)
    return LRESULT(Int(bitPattern: brush))
}

/// WM_ERASEBKGND: fills the client area with `brush`.
func fillBackground(_ hwnd: HWND?, _ wParam: WPARAM, _ brush: HBRUSH?) -> LRESULT {
    var r = RECT()
    GetClientRect(hwnd, &r)
    FillRect(HDC(bitPattern: UInt(wParam)), &r, brush)
    return 1
}

/// The theme's background and text colors for a list view, in the dark theme only.
func applyListColors(_ list: HWND?, _ colors: ThemeColors) {
    guard colors.dark else { return }
    let bg = LPARAM(Int(colors.background)), fg = LPARAM(Int(colors.text))
    SendMessageW(list, UINT(0x1001 /* LVM_SETBKCOLOR */), 0, bg)
    SendMessageW(list, UINT(0x1026 /* LVM_SETTEXTBKCOLOR */), 0, bg)
    SendMessageW(list, UINT(0x1024 /* LVM_SETTEXTCOLOR */), 0, fg)
}

/// Appends a column of each width (device pixels) to a report-view list.
func insertColumns(_ list: HWND?, widths: [Int32]) {
    for (i, cx) in widths.enumerated() {
        var column = LVCOLUMNW()
        column.mask = UINT(0x2 /* LVCF_WIDTH */)
        column.cx = cx
        _ = withUnsafeMutablePointer(to: &column) {
            SendMessageW(list, UINT(0x1061 /* LVM_INSERTCOLUMNW */), WPARAM(i), LPARAM(Int(bitPattern: $0)))
        }
    }
}

/// Indexes of the list's selected rows, ascending.
func selectedListRows(_ list: HWND?) -> [Int] {
    var rows: [Int] = []
    var i = -1
    while true {
        let next = Int(SendMessageW(list, UINT(0x100C /* LVM_GETNEXTITEM */), WPARAM(bitPattern: Int64(i)),
                                    LPARAM(0x2 /* LVNI_SELECTED */)))
        if next < 0 { return rows }
        rows.append(next); i = next
    }
}

/// Destroys every child control of `hwnd`.
func destroyChildren(_ hwnd: HWND?) {
    var child = GetWindow(hwnd, UINT(GW_CHILD))
    while let c = child { child = GetWindow(c, UINT(GW_HWNDNEXT)); DestroyWindow(c) }
}

/// Registers the window class `className` (a NUL-terminated UTF-16 name) with the
/// arrow cursor and the app icon.
/// - Returns: whether the class is registered.
func registerWindowClass(_ className: [UInt16],
                         proc: @convention(c) (HWND?, UINT, WPARAM, LPARAM) -> LRESULT) -> Bool {
    let hInst = GetModuleHandleW(nil)
    return className.withUnsafeBufferPointer { name -> Bool in
        var wc = WNDCLASSW()
        wc.lpfnWndProc = proc
        wc.hInstance = hInst
        wc.lpszClassName = name.baseAddress
        wc.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))   // IDC_ARROW
        wc.hbrBackground = HBRUSH(bitPattern: Int(COLOR_BTNFACE) + 1)
        wc.hIcon = LoadIconW(hInst, UnsafePointer<WCHAR>(bitPattern: 1))          // app icon (id 1)
        return RegisterClassW(&wc) != 0
    }
}

/// A captioned window of `className` at the default position, `owner` its owner.
func createWindow(_ className: [UInt16], title: String, width: Int32, height: Int32, owner: HWND?) -> HWND? {
    let style = DWORD(WS_OVERLAPPED) | DWORD(WS_CAPTION) | DWORD(WS_SYSMENU)
    let hInst = GetModuleHandleW(nil)
    return className.withUnsafeBufferPointer { name in
        title.withCString(encodedAs: UTF16.self) { title in
            CreateWindowExW(0, name.baseAddress, title, style,
                            Int32(CW_USEDEFAULT), Int32(CW_USEDEFAULT), width, height,
                            owner, nil, hInst, nil)
        }
    }
}

func showAndFocus(_ hwnd: HWND?) {
    ShowWindow(hwnd, SW_SHOW)
    SetForegroundWindow(hwnd)
}

/// The window size (borders and title bar included) whose client area is
/// `clientWidth` x `clientHeight` device pixels.
func outerSize(_ hwnd: HWND?, clientWidth: Int32, clientHeight: Int32) -> (w: Int32, h: Int32) {
    var wr = RECT(); GetWindowRect(hwnd, &wr)
    var cr = RECT(); GetClientRect(hwnd, &cr)
    return (clientWidth + (wr.right - wr.left) - (cr.right - cr.left),
            clientHeight + (wr.bottom - wr.top) - (cr.bottom - cr.top))
}

/// Sizes `hwnd` to the client area (device pixels) and centers it over `owner`.
func sizeCenteredOverOwner(_ hwnd: HWND?, owner: HWND?, clientWidth: Int32, clientHeight: Int32) {
    let (w, h) = outerSize(hwnd, clientWidth: clientWidth, clientHeight: clientHeight)
    var or = RECT(); GetWindowRect(owner, &or)
    SetWindowPos(hwnd, nil, or.left + ((or.right - or.left) - w) / 2, or.top + ((or.bottom - or.top) - h) / 2,
                 w, h, UINT(SWP_NOZORDER))
}
