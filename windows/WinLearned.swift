import WinSDK
import ReLayoutCore

// "Learned words" window, like the macOS sheet: the user's convert verdicts
// (typed -> conversion), the auto-corrections they undid (kept as typed) and the
// candidates still being counted. A row's check box says whether its verdict is in
// force; "+" adds a word by hand, "−" drops the selected rows. Opened from
// Settings; every change is saved at once.

private let idLrnList:     Int = 301
private let idLrnHint:     Int = 302
private let idLrnMinus:    Int = 303
private let idLrnDone:     Int = 304
private let idLrnColTyped: Int = 305
private let idLrnColOut:   Int = 306
private let idLrnPlus:     Int = 307
private let idLrnClean:    Int = 308
private let idLrnReset:    Int = 309
private let idLrnEdit:     Int = 310

// Posted to the window: the list view must not lose items inside its own notification.
private let WM_LRN_TOGGLE = UINT(WM_APP) + 30
private let WM_LRN_COMMIT = UINT(WM_APP) + 32

private var learnedHwnd: HWND?
private var learnedClassW = Array("ReLayoutLearnedWnd".utf16) + [0]
private var learnedClassRegistered = false
private var lrnDpi: Int32 = 96
private var lrnColors = ThemeColors.current()
private var lrnBrush: HBRUSH?
private let lrnThemeTimer: UINT_PTR = 1

private enum RowKind { case convert, keep, candidate, new }
private var shownRows: [(typed: String, out: String, kind: RowKind)] = []   // row i shows shownRows[i]
private var filling = false      // check boxes set by fillList are not the user's clicks
private var newPending = false   // the "+" row, until committed or dropped
private var newTyped = ""
private var outEdit: HWND?       // the editor over the new row's cell
private var editColumn: Int32 = colTyped
// Column 0 holds only the check box; text sits in its own columns so the titles
// above can line up with it.
private let colTyped: Int32 = 1, colOut: Int32 = 2

private func lsc(_ v: Int32) -> Int32 { scaled(v, dpi: lrnDpi) }

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

/// The row's check box: state image 2 = checked, 1 = clear, 0 = none.
private func setCheckImage(_ list: HWND?, _ row: Int, _ image: UINT) {
    var item = LVITEMW()
    item.stateMask = UINT(0xF000 /* LVIS_STATEIMAGEMASK */)
    item.state = image << 12
    _ = withUnsafeMutablePointer(to: &item) {
        SendMessageW(list, UINT(0x102B /* LVM_SETITEMSTATE */), WPARAM(row), LPARAM(Int(bitPattern: $0)))
    }
}

private func fillList(_ hwnd: HWND?) {
    filling = true
    defer { filling = false }
    let list = listView(hwnd)
    SendMessageW(list, UINT(0x1009 /* LVM_DELETEALLITEMS */), 0, 0)
    let words = learnedWords()
    var rows = words.convert.sorted { $0.key < $1.key }.map { (typed: $0.key, out: $0.value, kind: RowKind.convert) }
    rows += words.keep.sorted().map { (typed: $0, out: "", kind: RowKind.keep) }
    rows += words.candidates.sorted { $0.key < $1.key }.map { (typed: $0.key, out: $0.value, kind: RowKind.candidate) }
    if newPending { rows.append((typed: "", out: "", kind: .new)) }
    shownRows = rows
    for (i, row) in shownRows.enumerated() {
        setItemText(list, i, 0, "")
        setItemText(list, i, colTyped, row.typed)
        // An empty conversion is a keep (or a keep candidate's).
        setItemText(list, i, colOut, row.out.isEmpty && row.kind != .new ? L("settings.learned.keep") : row.out)
        setCheckImage(list, i, row.kind == .new ? 0 : row.kind == .candidate ? 1 : 2)
    }
    updateMinusButton(hwnd)
}

private func selectedRows(_ hwnd: HWND?) -> [Int] {
    selectedListRows(listView(hwnd))
}

private func updateMinusButton(_ hwnd: HWND?) {
    EnableWindow(GetDlgItem(hwnd, Int32(idLrnMinus)), !selectedRows(hwnd).isEmpty)
}

private func removeSelected(_ hwnd: HWND?) {
    let rows = selectedRows(hwnd).compactMap { shownRows.indices.contains($0) ? shownRows[$0] : nil }
    guard !rows.isEmpty else { return }
    if rows.contains(where: { $0.kind == .new }) { newPending = false }
    let keys = Set(rows.filter { $0.kind != .new }.map(\.typed))
    if keys.isEmpty { fillList(hwnd) } else { forgetLearned(keys) }   // saves, and reloads this list
}

/// The check box was clicked: a candidate becomes a verdict (a keep when its
/// conversion is empty), a verdict goes back to a candidate.
private func toggle(_ row: Int) {
    guard shownRows.indices.contains(row) else { return }
    let r = shownRows[row]
    switch r.kind {
    case .candidate: promoteLearned(r.typed, to: r.out)
    case .convert, .keep: demoteLearned(r.typed)
    case .new: break
    }
}

/// An OK/Cancel warning over the window; true on OK.
private func confirmed(_ hwnd: HWND?, _ text: String) -> Bool {
    text.withCString(encodedAs: UTF16.self) { t in
        "reLayout".withCString(encodedAs: UTF16.self) { c in
            MessageBoxW(hwnd, t, c, UINT(MB_OKCANCEL) | UINT(MB_ICONWARNING))
        }
    } == IDOK
}

private func setCue(_ edit: HWND?, _ text: String) {
    text.withCString(encodedAs: UTF16.self) {
        _ = SendMessageW(edit, UINT(0x1501 /* EM_SETCUEBANNER */), 1, LPARAM(Int(bitPattern: $0)))
    }
}

/// "+": an empty row at the end, its "Typed" cell in edit.
private func addRow(_ hwnd: HWND?) {
    guard !newPending else { return }
    newPending = true
    fillList(hwnd)
    let list = listView(hwnd), row = shownRows.count - 1
    SetFocus(list)
    SendMessageW(list, UINT(0x1013 /* LVM_ENSUREVISIBLE */), WPARAM(row), 0)
    beginEdit(hwnd, colTyped)
}

/// An edit box over the new row's `column` cell: "Typed" first, then "Becomes".
private func beginEdit(_ hwnd: HWND?, _ column: Int32) {
    editColumn = column
    let list = listView(hwnd), row = shownRows.count - 1
    var r = RECT(left: 0 /* LVIR_BOUNDS */, top: column, right: 0, bottom: 0)
    _ = withUnsafeMutablePointer(to: &r) {
        SendMessageW(list, UINT(0x1038 /* LVM_GETSUBITEMRECT */), WPARAM(row), LPARAM(Int(bitPattern: $0)))
    }
    withUnsafeMutablePointer(to: &r) {
        $0.withMemoryRebound(to: POINT.self, capacity: 2) { _ = MapWindowPoints(list, hwnd, $0, 2) }
    }
    outEdit = "EDIT".withCString(encodedAs: UTF16.self) { cls in
        CreateWindowExW(0, cls, nil, DWORD(WS_CHILD) | DWORD(WS_VISIBLE) | DWORD(WS_BORDER) | DWORD(0x80 /* ES_AUTOHSCROLL */),
                        r.left, r.top, r.right - r.left, r.bottom - r.top,
                        hwnd, HMENU(bitPattern: idLrnEdit), GetModuleHandleW(nil), nil)
    }
    guard let edit = outEdit else { newPending = false; fillList(hwnd); return }
    SetWindowPos(edit, nil /* HWND_TOP: over the list */, 0, 0, 0, 0, UINT(SWP_NOMOVE) | UINT(SWP_NOSIZE))
    setFont(edit, uiFont(dpi: lrnDpi))
    // Left empty, "Becomes" keeps the word as typed.
    setCue(edit, column == colTyped ? L("settings.learned.col.typed") : L("settings.learned.keep"))
    SetFocus(edit)
}

/// Ends the edit in the new row. "Typed" moves on to "Becomes" (an empty one drops
/// the row); "Becomes" commits a convert verdict, or a keep when empty. Esc drops it.
private func endEdit(_ hwnd: HWND?, commit: Bool) {
    guard let edit = outEdit else { return }
    outEdit = nil   // destroying it sends EN_KILLFOCUS, ignored: no longer `outEdit`
    var buf = [WCHAR](repeating: 0, count: 256)
    let n = Int(GetWindowTextW(edit, &buf, Int32(buf.count)))
    let text = learnedKey(String(decoding: buf.prefix(n), as: UTF16.self))
    DestroyWindow(edit)
    if editColumn == colTyped, commit, !text.isEmpty {
        newTyped = text
        setItemText(listView(hwnd), shownRows.count - 1, colTyped, text)
        beginEdit(hwnd, colOut)
        return
    }
    newPending = false
    SetFocus(listView(hwnd))
    if commit, editColumn == colOut { promoteLearned(newTyped, to: text) } else { fillList(hwnd) }
}

// MARK: - window

/// Size of `text` in the Settings font, wrapped at `width`, in 96-dpi units.
private func textSize(_ text: String, width: Int32, _ hwnd: HWND?) -> (w: Int32, h: Int32) {
    let size = measureWrapped(text, wrapWidth: lsc(width), hwnd, font: uiFont(dpi: lrnDpi))
    return (size.cx * 96 / lrnDpi, size.cy * 96 / lrnDpi)
}

@discardableResult
private func makeLrnControl(_ cls: String, _ text: String, _ style: Int32,
                            _ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32,
                            _ parent: HWND?, _ id: Int, exStyle: DWORD = 0) -> HWND? {
    createControl(cls, text, style, x, y, w, h, parent, id, exStyle: exStyle,
                  dpi: lrnDpi, font: uiFont(dpi: lrnDpi), dark: lrnColors.dark)
}

private var lrnClientW: Int32 = 424   // widened when the bottom buttons need it
private var lrnClientH: Int32 = 340   // follows the hint's wrapped height

private func buildLearned(_ hwnd: HWND?) {
    lrnColors = ThemeColors.current()
    if let b = lrnBrush { DeleteObject(UnsafeMutableRawPointer(b)) }
    lrnBrush = CreateSolidBrush(lrnColors.background)
    applyTitleBarTheme(hwnd, dark: lrnColors.dark)
    let cleanW = textSize(L("settings.learned.clean"), width: 1000, hwnd).w + 24
    let resetW = textSize(L("settings.learned.reset"), width: 1000, hwnd).w + 24
    let doneW = max(textSize(L("settings.exc.done"), width: 1000, hwnd).w + 24, 80)
    lrnClientW = max(424, 16 + 28 + 4 + 28 + 16 + cleanW + 8 + resetW + 24 + doneW + 16)
    let width = lrnClientW - 32
    let hint = L("settings.learned.hint")
    let hintH = textSize(hint, width: width, hwnd).h + 4
    makeLrnControl("STATIC", hint, 0, 16, 16, width, hintH, hwnd, idLrnHint)
    var y = 16 + hintH + 12

    // Column titles as labels over a header-less list, as the exceptions list has
    // none: a list view's header does not follow the dark theme. Each sits where the
    // list draws its column's text: list border (2) + the cells' text inset (4).
    let checkW: Int32 = 28, typedW = (width - checkW) / 2
    let textX: Int32 = 16 + 2 + checkW + 4
    makeLrnControl("STATIC", L("settings.learned.col.typed"), 0, textX, y, typedW - 4, 18, hwnd, idLrnColTyped)
    makeLrnControl("STATIC", L("settings.learned.col.out"), 0, textX + typedW, y, width - checkW - typedW - 6, 18,
                   hwnd, idLrnColOut)
    y += 20
    let list = makeLrnControl("SysListView32", "",
                              Int32(0x1 /* LVS_REPORT */) | Int32(0x4000 /* LVS_NOCOLUMNHEADER */)
                              | Int32(0x8 /* LVS_SHOWSELALWAYS */)
                              | Int32(WS_TABSTOP) | Int32(WS_CLIPSIBLINGS),
                              16, y, width, 200, hwnd, idLrnList, exStyle: DWORD(WS_EX_CLIENTEDGE))
    SendMessageW(list, UINT(0x1036 /* LVM_SETEXTENDEDLISTVIEWSTYLE */), 0,
                 LPARAM(0x20 /* LVS_EX_FULLROWSELECT */ | 0x10000 /* LVS_EX_DOUBLEBUFFER */ | 0x4 /* LVS_EX_CHECKBOXES */))
    applyListColors(list, lrnColors)
    insertColumns(list, widths: [lsc(checkW), lsc(typedW), lsc(width - checkW - typedW) - GetSystemMetrics(SM_CXVSCROLL) - 4])
    y += 212

    // "+" / "−" (the macOS segmented pair), then Clean and Reset bottom-left; Done bottom-right.
    makeLrnControl("BUTTON", "+", Int32(WS_TABSTOP), 16, y, 28, 28, hwnd, idLrnPlus)
    makeLrnControl("BUTTON", "\u{2212}", Int32(WS_TABSTOP), 16 + 28 + 4, y, 28, 28, hwnd, idLrnMinus)
    let cleanX: Int32 = 16 + 28 + 4 + 28 + 16
    makeLrnControl("BUTTON", L("settings.learned.clean"), Int32(WS_TABSTOP), cleanX, y, cleanW, 28, hwnd, idLrnClean)
    makeLrnControl("BUTTON", L("settings.learned.reset"), Int32(WS_TABSTOP),
                   cleanX + cleanW + 8, y, resetW, 28, hwnd, idLrnReset)
    makeLrnControl("BUTTON", L("settings.exc.done"), Int32(WS_TABSTOP) | Int32(BS_DEFPUSHBUTTON),
                   lrnClientW - 16 - doneW, y, doneW, 28, hwnd, idLrnDone)
    lrnClientH = y + 28 + 16
    fillList(hwnd)
}

private func learnedWndProc(_ hwnd: HWND?, _ msg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    switch msg {
    case UINT(WM_COMMAND):
        let notification = (UInt(truncatingIfNeeded: wParam) >> 16) & 0xFFFF
        switch Int(UInt(truncatingIfNeeded: wParam) & 0xFFFF) {
        case idLrnPlus: addRow(hwnd)
        case idLrnMinus: removeSelected(hwnd)
        case idLrnClean:
            if confirmed(hwnd, L("settings.learned.cleanConfirm", "\(learnedWords().candidates.count)")
                         + "\n\n" + L("settings.learned.cleanInfo")) { cleanLearnCandidates() }
        case idLrnReset:
            // Irreversible user data: confirmed first.
            if confirmed(hwnd, L("settings.learned.confirm", "\(learnedCount())")
                         + "\n\n" + L("settings.learned.confirmInfo")) { forgetLearned() }
        case idLrnEdit where notification == 0x0200 /* EN_KILLFOCUS */
            && HWND(bitPattern: Int(lParam)) == outEdit:
            PostMessageW(hwnd, WM_LRN_COMMIT, 0, 0)
        case 1 /* IDOK: Enter */: endEdit(hwnd, commit: true)
        case 2 /* IDCANCEL: Esc */ where outEdit != nil: endEdit(hwnd, commit: false)
        case idLrnDone, 2 /* IDCANCEL: Esc */: DestroyWindow(hwnd)
        default: break
        }
    case WM_LRN_TOGGLE:
        toggle(Int(wParam))
        return 0
    case WM_LRN_COMMIT:
        endEdit(hwnd, commit: true)
        return 0
    case UINT(WM_NOTIFY):
        guard let raw = UnsafeRawPointer(bitPattern: Int(lParam)) else { break }
        let hdr = raw.assumingMemoryBound(to: NMHDR.self).pointee
        guard hdr.idFrom == UINT_PTR(idLrnList) else { break }
        switch hdr.code {
        case UINT(bitPattern: -101) /* LVN_ITEMCHANGED */:
            let nm = raw.assumingMemoryBound(to: NMLISTVIEW.self).pointee
            let image = UINT(0xF000 /* LVIS_STATEIMAGEMASK */)
            if !filling, nm.iItem >= 0, nm.uChanged & UINT(0x8 /* LVIF_STATE */) != 0,
               (nm.uNewState ^ nm.uOldState) & image != 0, nm.uOldState & image != 0 {
                PostMessageW(hwnd, WM_LRN_TOGGLE, WPARAM(nm.iItem), 0)
            }
            updateMinusButton(hwnd)
        case UINT(bitPattern: -155) /* LVN_KEYDOWN */:
            let key = raw.assumingMemoryBound(to: NMLVKEYDOWN.self).pointee.wVKey
            if key == WORD(VK_DELETE) { removeSelected(hwnd) }
        default: break
        }
    case UINT(WM_CTLCOLORSTATIC), UINT(WM_CTLCOLORBTN):
        let id = Int(GetDlgCtrlID(HWND(bitPattern: Int(lParam))))
        return paintControl(wParam, text: id == idLrnColTyped || id == idLrnColOut ? lrnColors.secondary : lrnColors.text,
                            lrnColors, lrnBrush)
    case UINT(WM_CTLCOLOREDIT) where lrnColors.dark:   // the "Becomes" editor
        return paintEdit(wParam, lrnColors, lrnBrush)
    case UINT(WM_ERASEBKGND):
        return fillBackground(hwnd, wParam, lrnBrush)
    case UINT(WM_SETTINGCHANGE):
        // A theme switch arrives as a burst of broadcasts: check once, after it.
        SetTimer(hwnd, lrnThemeTimer, 300, nil)
    case UINT(WM_TIMER) where wParam == WPARAM(lrnThemeTimer):
        KillTimer(hwnd, lrnThemeTimer)
        guard appsUseDarkTheme() != lrnColors.dark else { return 0 }
        rebuildWithoutFlicker(hwnd) {
            outEdit = nil
            newPending = false
            destroyChildren(hwnd)
            buildLearned(hwnd)
        }
        return 0
    case UINT(WM_DESTROY):
        learnedHwnd = nil
        outEdit = nil
        newPending = false
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
        showAndFocus(existing)
        return
    }
    if !learnedClassRegistered { learnedClassRegistered = registerWindowClass(learnedClassW, proc: learnedWndProc) }
    guard learnedClassRegistered else { return }

    learnedHwnd = createWindow(learnedClassW, title: L("settings.learned.title"), width: 440, height: 400, owner: owner)
    guard let hwnd = learnedHwnd else { return }
    lrnDpi = windowDpi(hwnd)
    buildLearned(hwnd)

    // Size to the scaled client area, centered over the owner (Settings).
    sizeCenteredOverOwner(hwnd, owner: owner, clientWidth: lsc(lrnClientW), clientHeight: lsc(lrnClientH))
    showAndFocus(hwnd)
}
