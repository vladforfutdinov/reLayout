import WinSDK

// "Learned words" window, like the macOS sheet: the words the user converted with
// the hotkey after auto-correct had left them (typed -> conversion) and the
// auto-corrections they undid (kept as typed), with "Remove" and "Done". Opened
// from Settings; every change is saved at once.

private let idLrnList:     Int = 301
private let idLrnHint:     Int = 302
private let idLrnRemove:   Int = 303
private let idLrnDone:     Int = 304
private let idLrnColTyped: Int = 305
private let idLrnColOut:   Int = 306

private var learnedHwnd: HWND?
private var learnedClassW = Array("ReLayoutLearnedWnd".utf16) + [0]
private var learnedClassRegistered = false
private var lrnDpi: Int32 = 96
private var shownKeys: [String] = []   // row i shows shownKeys[i]
private var lrnColors = ThemeColors.current()
private var lrnBrush: HBRUSH?
private let lrnThemeTimer: UINT_PTR = 1

private func lsc(_ v: Int32) -> Int32 { v * lrnDpi / 96 }   // scale a 96-dpi coord

// MARK: - list

private func listView(_ hwnd: HWND?) -> HWND? { GetDlgItem(hwnd, Int32(idLrnList)) }

private func setItemText(_ list: HWND?, _ row: Int, _ column: Int32, _ text: String) {
    text.withCString(encodedAs: UTF16.self) { txt in
        var item = LVITEMW()
        item.mask = UINT(0x1 /* LVIF_TEXT */)
        item.iItem = Int32(row)
        item.iSubItem = column
        item.pszText = UnsafeMutablePointer(mutating: txt)
        _ = withUnsafeMutablePointer(to: &item) {
            column == 0
                ? SendMessageW(list, UINT(0x104D /* LVM_INSERTITEMW */), 0, LPARAM(Int(bitPattern: $0)))
                : SendMessageW(list, UINT(0x1074 /* LVM_SETITEMTEXTW */), WPARAM(row), LPARAM(Int(bitPattern: $0)))
        }
    }
}

private func fillList(_ hwnd: HWND?) {
    let list = listView(hwnd)
    SendMessageW(list, UINT(0x1009 /* LVM_DELETEALLITEMS */), 0, 0)
    let words = learnedWords()
    let rows: [(String, String)] = words.convert.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        + words.keep.sorted().map { ($0, L("settings.learned.keep")) }
    shownKeys = rows.map(\.0)
    for (i, row) in rows.enumerated() {
        setItemText(list, i, 0, row.0)
        setItemText(list, i, 1, row.1)
    }
    updateRemoveButton(hwnd)
}

private func selectedRows(_ hwnd: HWND?) -> [Int] {
    let list = listView(hwnd)
    var rows: [Int] = []
    var i = -1
    while true {
        let next = Int(SendMessageW(list, UINT(0x100C /* LVM_GETNEXTITEM */), WPARAM(bitPattern: Int64(i)),
                                    LPARAM(0x2 /* LVNI_SELECTED */)))
        if next < 0 { return rows }
        rows.append(next); i = next
    }
}

private func updateRemoveButton(_ hwnd: HWND?) {
    EnableWindow(GetDlgItem(hwnd, Int32(idLrnRemove)), !selectedRows(hwnd).isEmpty)
}

private func removeSelected(_ hwnd: HWND?) {
    let gone = Set(selectedRows(hwnd).compactMap { shownKeys.indices.contains($0) ? shownKeys[$0] : nil })
    guard !gone.isEmpty else { return }
    forgetLearned(gone)   // saves, and reloads this list through refreshSettingsLearned
}

// MARK: - window

/// Size of `text` in the Settings font, wrapped at `width`, in 96-dpi units.
private func textSize(_ text: String, width: Int32, _ hwnd: HWND?) -> (w: Int32, h: Int32) {
    let dc = GetDC(hwnd)
    defer { ReleaseDC(hwnd, dc) }
    let old = SelectObject(dc, UnsafeMutableRawPointer(settingsFont()))
    defer { SelectObject(dc, old) }
    var r = RECT(left: 0, top: 0, right: lsc(width), bottom: 0)
    let units = Array(text.utf16)
    DrawTextW(dc, units, Int32(units.count), &r, UINT(0x400 /* DT_CALCRECT */ | 0x10 /* DT_WORDBREAK */
                                                      | 0x800 /* DT_NOPREFIX */))
    return (r.right * 96 / lrnDpi, r.bottom * 96 / lrnDpi)
}

@discardableResult
private func makeLrnControl(_ cls: String, _ text: String, _ style: Int32,
                            _ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32,
                            _ parent: HWND?, _ id: Int, exStyle: DWORD = 0) -> HWND? {
    let hInst = GetModuleHandleW(nil)
    return cls.withCString(encodedAs: UTF16.self) { clsP in
        text.withCString(encodedAs: UTF16.self) { txtP in
            let ctl = CreateWindowExW(exStyle, clsP, txtP,
                                      DWORD(UInt32(bitPattern: style)) | DWORD(WS_CHILD) | DWORD(WS_VISIBLE),
                                      lsc(x), lsc(y), lsc(w), lsc(h), parent, HMENU(bitPattern: id), hInst, nil)
            SendMessageW(ctl, UINT(WM_SETFONT), unsafeBitCast(settingsFont(), to: WPARAM.self), LPARAM(1))
            applyControlTheme(ctl, className: cls, dark: lrnColors.dark)
            return ctl
        }
    }
}

private let lrnClientW: Int32 = 424
private var lrnClientH: Int32 = 340   // follows the hint's wrapped height

private func buildLearned(_ hwnd: HWND?) {
    lrnColors = ThemeColors.current()
    if let b = lrnBrush { DeleteObject(UnsafeMutableRawPointer(b)) }
    lrnBrush = CreateSolidBrush(lrnColors.background)
    applyTitleBarTheme(hwnd, dark: lrnColors.dark)
    let width = lrnClientW - 32
    let hint = L("settings.learned.hint")
    let hintH = textSize(hint, width: width, hwnd).h + 4
    makeLrnControl("STATIC", hint, 0, 16, 16, width, hintH, hwnd, idLrnHint)
    var y = 16 + hintH + 12

    // Column titles as labels over a header-less list, as the exceptions list has
    // none: a list view's header does not follow the dark theme.
    let colW = width / 2
    makeLrnControl("STATIC", L("settings.learned.col.typed"), 0, 20, y, colW - 4, 18, hwnd, idLrnColTyped)
    makeLrnControl("STATIC", L("settings.learned.col.out"), 0, 16 + colW + 4, y, width - colW - 4, 18, hwnd, idLrnColOut)
    y += 20
    let list = makeLrnControl("SysListView32", "",
                              Int32(0x1 /* LVS_REPORT */) | Int32(0x4000 /* LVS_NOCOLUMNHEADER */)
                              | Int32(0x8 /* LVS_SHOWSELALWAYS */) | Int32(WS_TABSTOP),
                              16, y, width, 200, hwnd, idLrnList, exStyle: DWORD(WS_EX_CLIENTEDGE))
    SendMessageW(list, UINT(0x1036 /* LVM_SETEXTENDEDLISTVIEWSTYLE */), 0,
                 LPARAM(0x20 /* LVS_EX_FULLROWSELECT */ | 0x10000 /* LVS_EX_DOUBLEBUFFER */))
    if lrnColors.dark {
        let bg = LPARAM(Int(lrnColors.background)), fg = LPARAM(Int(lrnColors.text))
        SendMessageW(list, UINT(0x1001 /* LVM_SETBKCOLOR */), 0, bg)
        SendMessageW(list, UINT(0x1026 /* LVM_SETTEXTBKCOLOR */), 0, bg)
        SendMessageW(list, UINT(0x1024 /* LVM_SETTEXTCOLOR */), 0, fg)
    }
    for (i, cx) in [lsc(colW), lsc(width - colW) - GetSystemMetrics(SM_CXVSCROLL) - 4].enumerated() {
        var column = LVCOLUMNW()
        column.mask = UINT(0x2 /* LVCF_WIDTH */)
        column.cx = cx
        _ = withUnsafeMutablePointer(to: &column) {
            SendMessageW(list, UINT(0x1061 /* LVM_INSERTCOLUMNW */), WPARAM(i), LPARAM(Int(bitPattern: $0)))
        }
    }
    y += 212

    let removeW = textSize(L("settings.exc.remove"), width: 1000, hwnd).w + 24
    makeLrnControl("BUTTON", L("settings.exc.remove"), Int32(WS_TABSTOP), 16, y, removeW, 28, hwnd, idLrnRemove)
    let doneW = max(textSize(L("settings.exc.done"), width: 1000, hwnd).w + 24, 80)
    makeLrnControl("BUTTON", L("settings.exc.done"), Int32(WS_TABSTOP) | Int32(BS_DEFPUSHBUTTON),
                   lrnClientW - 16 - doneW, y, doneW, 28, hwnd, idLrnDone)
    lrnClientH = y + 28 + 16
    fillList(hwnd)
}

private func learnedWndProc(_ hwnd: HWND?, _ msg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    switch msg {
    case UINT(WM_COMMAND):
        switch Int(UInt(truncatingIfNeeded: wParam) & 0xFFFF) {
        case idLrnRemove: removeSelected(hwnd)
        case idLrnDone, 2 /* IDCANCEL: Esc */: DestroyWindow(hwnd)
        default: break
        }
    case UINT(WM_NOTIFY):
        if let raw = UnsafeRawPointer(bitPattern: Int(lParam)) {
            let hdr = raw.assumingMemoryBound(to: NMHDR.self).pointee
            guard hdr.idFrom == UINT_PTR(idLrnList) else { break }
            if hdr.code == UINT(bitPattern: -101) /* LVN_ITEMCHANGED */ { updateRemoveButton(hwnd) }
            if hdr.code == UINT(bitPattern: -155) /* LVN_KEYDOWN */ {
                let key = raw.assumingMemoryBound(to: NMLVKEYDOWN.self).pointee.wVKey
                if key == WORD(VK_DELETE) { removeSelected(hwnd) }
            }
        }
    case UINT(WM_CTLCOLORSTATIC), UINT(WM_CTLCOLORBTN):
        let ctl = HWND(bitPattern: Int(lParam))
        let dc = HDC(bitPattern: UInt(wParam))
        let id = Int(GetDlgCtrlID(ctl))
        SetTextColor(dc, id == idLrnColTyped || id == idLrnColOut ? lrnColors.secondary : lrnColors.text)
        SetBkColor(dc, lrnColors.background)
        SetBkMode(dc, TRANSPARENT)
        return LRESULT(Int(bitPattern: lrnBrush))
    case UINT(WM_ERASEBKGND):
        var r = RECT()
        GetClientRect(hwnd, &r)
        FillRect(HDC(bitPattern: UInt(wParam)), &r, lrnBrush)
        return 1
    case UINT(WM_SETTINGCHANGE):
        // A theme switch arrives as a burst of broadcasts: check once, after it.
        SetTimer(hwnd, lrnThemeTimer, 300, nil)
    case UINT(WM_TIMER) where wParam == WPARAM(lrnThemeTimer):
        KillTimer(hwnd, lrnThemeTimer)
        guard appsUseDarkTheme() != lrnColors.dark else { return 0 }
        rebuildWithoutFlicker(hwnd) {
            var child = GetWindow(hwnd, UINT(GW_CHILD))
            while let c = child { child = GetWindow(c, UINT(GW_HWNDNEXT)); DestroyWindow(c) }
            buildLearned(hwnd)
        }
        return 0
    case UINT(WM_DESTROY):
        learnedHwnd = nil
        if let b = lrnBrush { DeleteObject(UnsafeMutableRawPointer(b)); lrnBrush = nil }
    default:
        break
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam)
}

/// The open Learned words window, for keyboard navigation in the message loop.
func learnedWindow() -> HWND? { learnedHwnd }

/// Reloads the open Learned words window's list after the stores changed.
func refreshLearnedWindow() {
    if let hwnd = learnedHwnd { fillList(hwnd) }
}

func openLearned(owner: HWND?) {
    if let existing = learnedHwnd {
        ShowWindow(existing, SW_SHOW)
        SetForegroundWindow(existing)
        return
    }
    let hInst = GetModuleHandleW(nil)
    if !learnedClassRegistered {
        learnedClassW.withUnsafeBufferPointer { name in
            var wc = WNDCLASSW()
            wc.lpfnWndProc = learnedWndProc
            wc.hInstance = hInst
            wc.lpszClassName = name.baseAddress
            wc.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))   // IDC_ARROW
            wc.hbrBackground = HBRUSH(bitPattern: Int(COLOR_BTNFACE) + 1)
            wc.hIcon = LoadIconW(hInst, UnsafePointer<WCHAR>(bitPattern: 1))          // app icon (id 1)
            learnedClassRegistered = RegisterClassW(&wc) != 0
        }
    }
    guard learnedClassRegistered else { return }

    let style = DWORD(WS_OVERLAPPED) | DWORD(WS_CAPTION) | DWORD(WS_SYSMENU)
    learnedHwnd = learnedClassW.withUnsafeBufferPointer { name in
        L("settings.learned.title").withCString(encodedAs: UTF16.self) { title in
            CreateWindowExW(0, name.baseAddress, title, style,
                            Int32(CW_USEDEFAULT), Int32(CW_USEDEFAULT), 440, 400,
                            owner, nil, hInst, nil)
        }
    }
    guard let hwnd = learnedHwnd else { return }
    let dpi = GetDpiForWindow(hwnd)
    lrnDpi = dpi > 0 ? Int32(dpi) : 96
    buildLearned(hwnd)

    // Size to the scaled client area, centered over the owner (Settings).
    var wr = RECT(); GetWindowRect(hwnd, &wr)
    var cr = RECT(); GetClientRect(hwnd, &cr)
    let w = lsc(lrnClientW) + (wr.right - wr.left) - (cr.right - cr.left)
    let h = lsc(lrnClientH) + (wr.bottom - wr.top) - (cr.bottom - cr.top)
    var or = RECT(); GetWindowRect(owner, &or)
    SetWindowPos(hwnd, nil, or.left + ((or.right - or.left) - w) / 2, or.top + ((or.bottom - or.top) - h) / 2,
                 w, h, UINT(SWP_NOZORDER))
    ShowWindow(hwnd, SW_SHOW)
    SetForegroundWindow(hwnd)
}
