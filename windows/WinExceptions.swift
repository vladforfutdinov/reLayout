import WinSDK
import ReLayoutCore
import RelayoutNative

// Per-app features window ("Apps…" in Settings), like the macOS sheet: a list of
// programs (icon and name), each with two check columns — auto-correct, retype
// hotkey; ticked = works there — then "Add current app", "+" (Choose…), "−"
// (Remove) and "Done". Every change is saved at
// once; there is nothing to cancel. A program is stored by its executable name
// ("code.exe") in two lists: the auto-correct one and the hotkey one.

private let idExcList:   Int = 201
private let idExcCurrent: Int = 202
private let idExcChoose: Int = 203
private let idExcRemove: Int = 204
private let idExcDone:   Int = 206
private let idExcColAuto: Int = 208
private let idExcColHotkey: Int = 209

// Columns: program, auto, hotkey. A list view puts a cell image at the cell's left
// edge, so the check boxes are custom-drawn, centred in their cells.
private let colAuto: Int32 = 1, colHotkey: Int32 = 2

private var exceptionsHwnd: HWND?
private var exceptionsClassW = Array("ReLayoutExceptionsWnd".utf16) + [0]
private var exceptionsClassRegistered = false
private var excDpi: Int32 = 96
private var excTooltip: HWND?
/// A program and what is off in it. A row with both cleared stays until the
/// window closes; it is in neither list.
private struct ExcRow { let exe: String; var auto: Bool; var hotkey: Bool }
private var rows: [ExcRow] = []   // list row i shows rows[i]
private var checkImages: (off: Int32, on: Int32)?   // in the list's small image list
private var excColors = ThemeColors.current()
private var excBrush: HBRUSH?
private let excThemeTimer: UINT_PTR = 1

private func esc(_ v: Int32) -> Int32 { scaled(v, dpi: excDpi) }

// MARK: - the last program the user was in ("Exclude current app")

private var lastActiveApp: String?
private var foregroundHook: HWINEVENTHOOK?

/// Remembers the last foreground program other than reLayout and the taskbar, so
/// "Exclude current app" means the app the user came to Settings from.
private let foregroundProc: WINEVENTPROC = { _, _, hwnd, _, _, _, _ in
    var cls = [WCHAR](repeating: 0, count: 64)
    let n = Int(GetClassNameW(hwnd, &cls, Int32(cls.count)))
    let name = String(decoding: cls.prefix(n), as: UTF16.self)
    guard !name.hasPrefix("Shell_"), name != "NotifyIconOverflowWindow",
          let path = processImagePath(of: appWindow(hwnd)) else { return }   // nil for our own windows
    lastActiveApp = exeName(path)
}

func trackForegroundApps() {
    foregroundHook = SetWinEventHook(DWORD(0x0003 /* EVENT_SYSTEM_FOREGROUND */), DWORD(0x0003), nil,
                                     foregroundProc, 0, 0, DWORD(0 /* WINEVENT_OUTOFCONTEXT */))
}

// MARK: - program name and icon

/// Where an excluded executable lives, to show its icon and description: a running
/// copy, else PATH (System32 included). Not found -> a generic icon and the name.
private func locate(_ exe: String) -> String? {
    var ids = [DWORD](repeating: 0, count: 2048)
    var bytes: DWORD = 0
    if K32EnumProcesses(&ids, DWORD(ids.count * MemoryLayout<DWORD>.size), &bytes) {
        for pid in ids.prefix(Int(bytes) / MemoryLayout<DWORD>.size) where pid != 0 {
            guard let h = OpenProcess(DWORD(0x1000 /* PROCESS_QUERY_LIMITED_INFORMATION */), false, pid) else { continue }
            defer { CloseHandle(h) }
            var buf = [WCHAR](repeating: 0, count: 1024)
            var size = DWORD(buf.count)
            if QueryFullProcessImageNameW(h, 0, &buf, &size) {
                let path = String(decoding: buf.prefix(Int(size)), as: UTF16.self)
                if exeName(path) == exe { return path }
            }
        }
    }
    var buf = [WCHAR](repeating: 0, count: 1024)
    let n = exe.withCString(encodedAs: UTF16.self) { SearchPathW(nil, $0, nil, DWORD(buf.count), &buf, nil) }
    return n > 0 && Int(n) < buf.count ? String(decoding: buf.prefix(Int(n)), as: UTF16.self) : nil
}

/// The executable's own description ("Windows Terminal"), else its file name.
private func displayName(_ exe: String, path: String?) -> String {
    guard let path else { return exe }
    return path.withCString(encodedAs: UTF16.self) { file -> String? in
        var handle: DWORD = 0
        let size = GetFileVersionInfoSizeW(file, &handle)
        guard size > 0 else { return nil }
        var data = [UInt8](repeating: 0, count: Int(size))
        guard GetFileVersionInfoW(file, 0, size, &data) else { return nil }
        var ptr: UnsafeMutableRawPointer?
        var len: UINT = 0
        guard "\\VarFileInfo\\Translation".withCString(encodedAs: UTF16.self, { VerQueryValueW(data, $0, &ptr, &len) }),
              let ptr, len >= 4 else { return nil }
        let lang = ptr.load(as: UInt16.self), page = ptr.load(fromByteOffset: 2, as: UInt16.self)
        let hex = { (v: UInt16) -> String in let s = String(v, radix: 16); return String(repeating: "0", count: 4 - s.count) + s }
        let key = "\\StringFileInfo\\\(hex(lang))\(hex(page))\\FileDescription"
        var text: UnsafeMutableRawPointer?
        guard key.withCString(encodedAs: UTF16.self, { VerQueryValueW(data, $0, &text, &len) }),
              let text, len > 1 else { return nil }
        let s = trimmed(String(decoding: UnsafeBufferPointer(start: text.assumingMemoryBound(to: WCHAR.self),
                                                             count: Int(len) - 1), as: UTF16.self))
        return s.isEmpty ? nil : s
    } ?? exe
}

/// Small icon of the file at `path`, or of a generic program.
private func smallIcon(_ path: String?) -> HICON? {
    var info = SHFILEINFOW()
    let flags = UINT(0x100 /* SHGFI_ICON */ | 0x1 /* SHGFI_SMALLICON */)
        | (path == nil ? UINT(0x10 /* SHGFI_USEFILEATTRIBUTES */) : 0)
    let ok = (path ?? "program.exe").withCString(encodedAs: UTF16.self) {
        SHGetFileInfoW($0, DWORD(FILE_ATTRIBUTE_NORMAL), &info, UINT(MemoryLayout<SHFILEINFOW>.size), flags)
    }
    return ok != 0 ? info.hIcon : nil
}

// MARK: - list

private func listView(_ hwnd: HWND?) -> HWND? { GetDlgItem(hwnd, Int32(idExcList)) }

private func fillList(_ hwnd: HWND?) {
    let list = listView(hwnd)
    SendMessageW(list, UINT(0x1009 /* LVM_DELETEALLITEMS */), 0, 0)
    // The list view owns this image list and destroys it with itself.
    let size = GetSystemMetrics(SM_CXSMICON)
    let images = ImageList_Create(size, size, UINT(0x20 /* ILC_COLOR32 */ | 0x1 /* ILC_MASK */), 8, 8)
    let old = SendMessageW(list, UINT(0x1003 /* LVM_SETIMAGELIST */), WPARAM(1 /* LVSIL_SMALL */),
                           LPARAM(Int(bitPattern: UnsafeRawPointer(images))))
    if old != 0 { ImageList_Destroy(HIMAGELIST(bitPattern: Int(old))) }
    checkImages = addCheckImages(hwnd, to: images, dark: excColors.dark)   // drawCheck paints them

    for (i, row) in rows.enumerated() {
        let path = locate(row.exe)
        let name = displayName(row.exe, path: path)
        var image: Int32 = -1
        if let icon = smallIcon(path) {
            image = ImageList_ReplaceIcon(images, -1, icon)
            DestroyIcon(icon)
        }
        let text = name == row.exe ? row.exe : "\(name)  (\(row.exe))"
        text.withCString(encodedAs: UTF16.self) { txt in
            var item = LVITEMW()
            item.mask = UINT(0x1 /* LVIF_TEXT */ | 0x2 /* LVIF_IMAGE */)
            item.iItem = Int32(i)
            item.iImage = image
            item.pszText = UnsafeMutablePointer(mutating: txt)
            _ = withUnsafeMutablePointer(to: &item) {
                SendMessageW(list, UINT(0x104D /* LVM_INSERTITEMW */), 0, LPARAM(Int(bitPattern: $0)))
            }
        }
        setCheck(list, i, colAuto, !row.auto)   // ticked = the feature works
        setCheck(list, i, colHotkey, !row.hotkey)
    }
    updateRemoveButton(hwnd)
}

/// Shows a check cell's state: the box is drawn from `rows` (`drawCheck`), so with
/// check images this only repaints the row; without them the cell gets a check mark.
private func setCheck(_ list: HWND?, _ row: Int, _ column: Int32, _ on: Bool) {
    guard checkImages == nil else {
        SendMessageW(list, UINT(0x1015 /* LVM_REDRAWITEMS */), WPARAM(row), LPARAM(row))
        return
    }
    (on ? "\u{2713}" : "").withCString(encodedAs: UTF16.self) { txt in
        var item = LVITEMW()
        item.mask = UINT(0x1 /* LVIF_TEXT */)
        item.iItem = Int32(row)
        item.iSubItem = column
        item.pszText = UnsafeMutablePointer(mutating: txt)
        _ = withUnsafeMutablePointer(to: &item) {
            SendMessageW(list, UINT(0x104C /* LVM_SETITEMW */), 0, LPARAM(Int(bitPattern: $0)))
        }
    }
}

/// NM_CUSTOMDRAW of the list: the list paints each cell (background, selection),
/// then the check cells get their box centred on top; the hovered row is coloured.
private func drawCheck(_ list: HWND?, _ raw: UnsafeMutableRawPointer) -> LRESULT {
    let cd = raw.assumingMemoryBound(to: NMLVCUSTOMDRAW.self).pointee
    let column = cd.iSubItem, row = Int(cd.nmcd.dwItemSpec)
    switch cd.nmcd.dwDrawStage {
    case DWORD(0x1 /* CDDS_PREPAINT */):
        return LRESULT(0x20 /* CDRF_NOTIFYITEMDRAW */) | (excColors.dark ? LRESULT(0x10 /* CDRF_NOTIFYPOSTPAINT */) : 0)
    case DWORD(0x2 /* CDDS_POSTPAINT */):
        coverColumnLines(list, cd.nmcd.hdc, background: excColors.background)
        return 0
    case DWORD(0x10001 /* CDDS_ITEMPREPAINT */): return LRESULT(0x20 /* CDRF_NOTIFYSUBITEMDRAW */) | paintHover(list, raw)
    case DWORD(0x30001 /* CDDS_SUBITEM | CDDS_ITEMPREPAINT */):
        return (column == colAuto || column == colHotkey ? LRESULT(0x10 /* CDRF_NOTIFYPOSTPAINT */) : 0) | paintHover(list, raw)
    case DWORD(0x30002 /* CDDS_SUBITEM | CDDS_ITEMPOSTPAINT */):
        guard let images = checkImages, rows.indices.contains(row) else { return 0 }
        let on = column == colAuto ? !rows[row].auto : !rows[row].hotkey
        drawCentredImage(list, cd.nmcd.hdc, row: row, column: column, image: on ? images.on : images.off)
        return 0
    default: return 0
    }
}

private func loadRows() -> [ExcRow] {
    let e = AppExceptions(auto: loadExcludedApps(), hotkey: loadHotkeyExcludedApps())
    return e.rows.map { ExcRow(exe: $0, auto: e.autoOff($0), hotkey: e.hotkeyOff($0)) }
}

private func saveRows() {
    saveExcludedApps(rows.filter(\.auto).map(\.exe))
    saveHotkeyExcludedApps(rows.filter(\.hotkey).map(\.exe))
    reloadAutoMode()
}

/// A click in a check column flips that cell.
private func clickCell(_ hwnd: HWND?) {
    let list = listView(hwnd)
    guard let (row, column) = clickedCell(list), rows.indices.contains(row),
          column == colAuto || column == colHotkey else { return }
    let on: Bool
    if column == colAuto { rows[row].auto.toggle(); on = rows[row].auto }
    else { rows[row].hotkey.toggle(); on = rows[row].hotkey }
    setCheck(list, row, column, !on)
    saveRows()
}

private func selectedRows(_ hwnd: HWND?) -> [Int] {
    selectedListRows(listView(hwnd))
}

private func updateRemoveButton(_ hwnd: HWND?) {
    EnableWindow(GetDlgItem(hwnd, Int32(idExcRemove)), !selectedRows(hwnd).isEmpty)
}

/// An added program starts with both features off (as the engine's `AppExceptions.add`).
private func addApps(_ hwnd: HWND?, _ exes: [String]) {
    for exe in exes {
        if let i = rows.firstIndex(where: { $0.exe == exe }) { rows[i].auto = true; rows[i].hotkey = true }
        else { rows.append(ExcRow(exe: exe, auto: true, hotkey: true)) }
    }
    saveRows()
    fillList(hwnd)
}

private func removeSelected(_ hwnd: HWND?) {
    let gone = Set(selectedRows(hwnd).compactMap { rows.indices.contains($0) ? rows[$0].exe : nil })
    guard !gone.isEmpty else { return }
    rows.removeAll { gone.contains($0.exe) }
    saveRows()
    fillList(hwnd)
}

/// A program picked in the standard Open dialog, as its executable name.
private func chooseProgram(_ hwnd: HWND?) -> String? {
    var file = [WCHAR](repeating: 0, count: 1024)
    let filter = Array("Programs\0*.exe\0\0".utf16)
    return filter.withUnsafeBufferPointer { f -> String? in
        var ofn = OPENFILENAMEW()
        ofn.lStructSize = DWORD(MemoryLayout<OPENFILENAMEW>.size)
        ofn.hwndOwner = hwnd
        ofn.lpstrFilter = f.baseAddress
        ofn.nMaxFile = DWORD(file.count)
        ofn.Flags = DWORD(0x1000 /* OFN_FILEMUSTEXIST */ | 0x800 /* OFN_PATHMUSTEXIST */ | 0x8 /* OFN_NOCHANGEDIR */)
        return file.withUnsafeMutableBufferPointer { buf -> String? in
            ofn.lpstrFile = buf.baseAddress
            guard GetOpenFileNameW(&ofn) else { return nil }
            return exeName(String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF16.self))
        }
    }
}

// MARK: - window

private func textWidth(_ text: String, _ hwnd: HWND?) -> Int32 {
    uiTextWidth(text, hwnd, font: uiFont(dpi: excDpi), dpi: excDpi)
}

@discardableResult
private func makeExcControl(_ cls: String, _ text: String, _ style: Int32,
                            _ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32,
                            _ parent: HWND?, _ id: Int, exStyle: DWORD = 0) -> HWND? {
    createControl(cls, text, style, x, y, w, h, parent, id, exStyle: exStyle,
                  dpi: excDpi, font: uiFont(dpi: excDpi), dark: excColors.dark)
}

private let clientW: Int32 = 480
private let clientH: Int32 = 294

private func buildExceptions(_ hwnd: HWND?) {
    excColors = ThemeColors.current()
    if let b = excBrush { DeleteObject(UnsafeMutableRawPointer(b)) }
    excBrush = CreateSolidBrush(excColors.background)
    applyTitleBarTheme(hwnd, dark: excColors.dark)
    excTooltip = nil

    // Check column titles as labels over a header-less list (a list view's header
    // does not follow the dark theme), as in Learned words: each starts where the
    // list draws its column's content — list border (2) + the cell inset (4). The
    // program column gives up the scroll bar's width, so the check columns stay
    // under their titles.
    let listW = clientW - 32
    let autoTitle = L("settings.exc.auto"), hotkeyTitle = L("settings.exc.hotkey")
    let autoW = max(textWidth(autoTitle, hwnd) + 12, 36), hotkeyW = max(textWidth(hotkeyTitle, hwnd) + 12, 36)
    let nameCx = esc(listW - autoW - hotkeyW) - GetSystemMetrics(SM_CXVSCROLL) - 4
    let autoX = 16 + 2 + nameCx * 96 / excDpi   // list border, then the program column
    let autoLabel = makeExcControl("STATIC", autoTitle, Int32(0x0001 /* SS_CENTER */), autoX, 16, autoW, 18,
                                   hwnd, idExcColAuto)
    addTooltip(&excTooltip, hwnd, autoLabel, L("settings.exc.auto.tip"), overWindow: true)
    let hotkeyLabel = makeExcControl("STATIC", hotkeyTitle, Int32(0x0001 /* SS_CENTER */), autoX + autoW, 16,
                                     hotkeyW, 18, hwnd, idExcColHotkey)
    addTooltip(&excTooltip, hwnd, hotkeyLabel, L("settings.exc.hotkey.tip"), overWindow: true)

    let list = makeExcControl("SysListView32", "",
                              Int32(0x1 /* LVS_REPORT */) | Int32(0x4000 /* LVS_NOCOLUMNHEADER */)
                              | Int32(0x8 /* LVS_SHOWSELALWAYS */) | Int32(WS_TABSTOP),
                              16, 36, listW, 200, hwnd, idExcList, exStyle: DWORD(WS_EX_CLIENTEDGE))
    SendMessageW(list, UINT(0x1036 /* LVM_SETEXTENDEDLISTVIEWSTYLE */), 0,
                 LPARAM(0x20 /* LVS_EX_FULLROWSELECT */ | 0x10000 /* LVS_EX_DOUBLEBUFFER */))
    applyListColors(list, excColors)
    if !excColors.dark { trackHover(list) }
    insertColumns(list, widths: [nameCx, esc(autoW), esc(hotkeyW)])

    // "+" (Choose…) / "−" (remove the selection), then "Exclude current app"; Done
    // on the right, as on macOS.
    makeExcControl("BUTTON", "+", Int32(WS_TABSTOP), 16, 248, 28, 28, hwnd, idExcChoose)
    makeExcControl("BUTTON", "\u{2212}", Int32(WS_TABSTOP), 16 + 28 + 4, 248, 28, 28, hwnd, idExcRemove)
    makeExcControl("BUTTON", L("settings.exc.addCurrent"), Int32(WS_TABSTOP), 16 + 28 + 4 + 28 + 16, 248,
                   textWidth(L("settings.exc.addCurrent"), hwnd) + 24, 28, hwnd, idExcCurrent)
    let doneW = max(textWidth(L("settings.exc.done"), hwnd) + 24, 80)
    makeExcControl("BUTTON", L("settings.exc.done"), Int32(WS_TABSTOP) | Int32(BS_DEFPUSHBUTTON),
                   clientW - 16 - doneW, 248, doneW, 28, hwnd, idExcDone)
    fillList(hwnd)
}

private func exceptionsWndProc(_ hwnd: HWND?, _ msg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    switch msg {
    case UINT(WM_COMMAND):
        switch Int(UInt(truncatingIfNeeded: wParam) & 0xFFFF) {
        case idExcCurrent:
            guard let app = lastActiveApp else { MessageBeep(UINT(MB_OK)); break }
            addApps(hwnd, [app])
        case idExcChoose:
            if let app = chooseProgram(hwnd) { addApps(hwnd, [app]) }
        case idExcRemove: removeSelected(hwnd)
        case idExcDone, 2 /* IDCANCEL: Esc */: endModal(hwnd); DestroyWindow(hwnd)
        default: break
        }
    case UINT(WM_NOTIFY):
        if let raw = UnsafeRawPointer(bitPattern: Int(lParam)) {
            let hdr = raw.assumingMemoryBound(to: NMHDR.self).pointee
            guard hdr.idFrom == UINT_PTR(idExcList) else { break }
            if hdr.code == UINT(bitPattern: -12) /* NM_CUSTOMDRAW */ { return drawCheck(hdr.hwndFrom, UnsafeMutableRawPointer(mutating: raw)) }
            if hdr.code == UINT(bitPattern: -101) /* LVN_ITEMCHANGED */ { updateRemoveButton(hwnd) }
            if hdr.code == UINT(bitPattern: -2) /* NM_CLICK */ || hdr.code == UINT(bitPattern: -3) /* NM_DBLCLK */ {
                clickCell(hwnd)
            }
            if hdr.code == UINT(bitPattern: -155) /* LVN_KEYDOWN */ {
                let key = raw.assumingMemoryBound(to: NMLVKEYDOWN.self).pointee.wVKey
                if key == WORD(VK_DELETE) { removeSelected(hwnd) }
            }
        }
    case UINT(WM_CTLCOLORSTATIC), UINT(WM_CTLCOLORBTN):
        let id = Int(GetDlgCtrlID(HWND(bitPattern: Int(lParam))))
        return paintControl(wParam, text: id == idExcColAuto || id == idExcColHotkey ? excColors.secondary : excColors.text,
                            excColors, excBrush)
    case UINT(WM_ERASEBKGND):
        return fillBackground(hwnd, wParam, excBrush)
    case UINT(WM_SETTINGCHANGE):
        // A theme switch arrives as a burst of broadcasts: check once, after it.
        SetTimer(hwnd, excThemeTimer, 300, nil)
    case UINT(WM_TIMER) where wParam == WPARAM(excThemeTimer):
        KillTimer(hwnd, excThemeTimer)
        guard appsUseDarkTheme() != excColors.dark else { return 0 }
        rebuildWithoutFlicker(hwnd) {
            destroyChildren(hwnd)
            if let tip = excTooltip { DestroyWindow(tip) }
            buildExceptions(hwnd)
        }
        return 0
    case UINT(WM_NCHITTEST):
        return fixedHitTest(hwnd, wParam, lParam)
    case UINT(WM_CLOSE):   // the title bar's ✕, Alt+F4
        endModal(hwnd)
    case UINT(WM_DESTROY):
        endModal(hwnd)
        exceptionsHwnd = nil
        if let b = excBrush { DeleteObject(UnsafeMutableRawPointer(b)); excBrush = nil }
        excTooltip = nil   // owned by the window: destroyed with it
    default:
        break
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam)
}

/// The open Exceptions window, for keyboard navigation in the message loop.
func exceptionsWindow() -> HWND? { exceptionsHwnd }

func openExceptions(owner: HWND?) {
    if let existing = exceptionsHwnd {
        showAndFocus(existing)
        return
    }
    if !exceptionsClassRegistered { exceptionsClassRegistered = registerWindowClass(exceptionsClassW, proc: exceptionsWndProc) }
    guard exceptionsClassRegistered else { return }

    exceptionsHwnd = createWindow(exceptionsClassW, title: L("settings.exc.title"), width: 440, height: 400, owner: owner)
    guard let hwnd = exceptionsHwnd else { return }
    excDpi = windowDpi(hwnd)
    rows = loadRows()
    buildExceptions(hwnd)

    // Size to the scaled client area, centered over the owner (Settings).
    sizeCenteredOverOwner(hwnd, owner: owner, clientWidth: esc(clientW), clientHeight: esc(clientH))
    beginModal(hwnd)
    showAndFocus(hwnd)
}
