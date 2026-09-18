import WinSDK
import Foundation

// "Auto-correct exceptions" window, like the macOS sheet: a list of programs (icon
// and name) where auto-correct stays off, "Exclude current app", "Choose…",
// "Remove" and "Done". Every change is saved at once; there is nothing to cancel.
// A program is stored by its executable name ("code.exe").

private let idExcList:   Int = 201
private let idExcCurrent: Int = 202
private let idExcChoose: Int = 203
private let idExcRemove: Int = 204
private let idExcInfo:   Int = 205
private let idExcDone:   Int = 206
private let idExcTitle:  Int = 207

private var exceptionsHwnd: HWND?
private var exceptionsClassW = Array("ReLayoutExceptionsWnd".utf16) + [0]
private var exceptionsClassRegistered = false
private var excDpi: Int32 = 96
private var excTooltip: HWND?
private var excGlyphFont: HFONT?
private var shownApps: [String] = []   // row i shows shownApps[i]

private func esc(_ v: Int32) -> Int32 { v * excDpi / 96 }   // scale a 96-dpi coord

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
          let path = processImagePath(of: hwnd) else { return }   // nil for our own windows
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
        let key = String(format: "\\StringFileInfo\\%04x%04x\\FileDescription", lang, page)
        var text: UnsafeMutableRawPointer?
        guard key.withCString(encodedAs: UTF16.self, { VerQueryValueW(data, $0, &text, &len) }),
              let text, len > 1 else { return nil }
        let s = String(decoding: UnsafeBufferPointer(start: text.assumingMemoryBound(to: WCHAR.self), count: Int(len) - 1),
                       as: UTF16.self).trimmingCharacters(in: .whitespaces)
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

    shownApps = loadExcludedApps()
    let rows = shownApps.map { exe -> (name: String, exe: String, path: String?) in
        let path = locate(exe)
        return (displayName(exe, path: path), exe, path)
    }
    for (i, row) in rows.enumerated() {
        var image: Int32 = -1
        if let icon = smallIcon(row.path) {
            image = ImageList_ReplaceIcon(images, -1, icon)
            DestroyIcon(icon)
        }
        let text = row.name == row.exe ? row.exe : "\(row.name)  (\(row.exe))"
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
    EnableWindow(GetDlgItem(hwnd, Int32(idExcRemove)), !selectedRows(hwnd).isEmpty)
}

private func addApps(_ hwnd: HWND?, _ exes: [String]) {
    var apps = loadExcludedApps()
    for exe in exes where !apps.contains(exe) { apps.append(exe) }
    saveExcludedApps(apps)
    reloadAutoMode()
    fillList(hwnd)
}

private func removeSelected(_ hwnd: HWND?) {
    let gone = Set(selectedRows(hwnd).compactMap { shownApps.indices.contains($0) ? shownApps[$0] : nil })
    guard !gone.isEmpty else { return }
    saveExcludedApps(loadExcludedApps().filter { !gone.contains($0) })
    reloadAutoMode()
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
    let dc = GetDC(hwnd)
    defer { ReleaseDC(hwnd, dc) }
    let old = SelectObject(dc, UnsafeMutableRawPointer(settingsFont()))
    defer { SelectObject(dc, old) }
    var size = SIZE()
    let units = Array(text.utf16)
    GetTextExtentPoint32W(dc, units, Int32(units.count), &size)
    return size.cx * 96 / excDpi
}

@discardableResult
private func makeExcControl(_ cls: String, _ text: String, _ style: Int32,
                            _ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32,
                            _ parent: HWND?, _ id: Int, exStyle: DWORD = 0) -> HWND? {
    let hInst = GetModuleHandleW(nil)
    return cls.withCString(encodedAs: UTF16.self) { clsP in
        text.withCString(encodedAs: UTF16.self) { txtP in
            let ctl = CreateWindowExW(exStyle, clsP, txtP,
                                      DWORD(UInt32(bitPattern: style)) | DWORD(WS_CHILD) | DWORD(WS_VISIBLE),
                                      esc(x), esc(y), esc(w), esc(h), parent, HMENU(bitPattern: id), hInst, nil)
            SendMessageW(ctl, UINT(WM_SETFONT), unsafeBitCast(settingsFont(), to: WPARAM.self), LPARAM(1))
            return ctl
        }
    }
}

private func excFont(_ face: String, points: Int32) -> HFONT? {
    face.withCString(encodedAs: UTF16.self) {
        CreateFontW(-(points * excDpi / 72), 0, 0, 0, Int32(FW_NORMAL), 0, 0, 0,
                    DWORD(DEFAULT_CHARSET), DWORD(OUT_DEFAULT_PRECIS), DWORD(CLIP_DEFAULT_PRECIS),
                    DWORD(CLEARTYPE_QUALITY), DWORD(DEFAULT_PITCH), $0)
    }
}

private let clientW: Int32 = 424
private let clientH: Int32 = 322

private func buildExceptions(_ hwnd: HWND?) {
    // The window caption already names it; this line says what the list does.
    let title = L("settings.exc.hint")
    makeExcControl("STATIC", title, 0, 16, 16, 360, 20, hwnd, idExcTitle)

    // Why a fresh install already lists programs (terminals, editors, VMs).
    let titleW = min(textWidth(title, hwnd) + 6, 340)
    let info = makeExcControl("STATIC", "\u{E946}" /* Info glyph */, 0, 16 + titleW, 16, 20, 20, hwnd, idExcInfo)
    excGlyphFont = excFont("Segoe MDL2 Assets", points: 10)
    SendMessageW(info, UINT(WM_SETFONT), unsafeBitCast(excGlyphFont, to: WPARAM.self), LPARAM(1))
    excTooltip = nil
    addTooltip(&excTooltip, hwnd, info, L("settings.exc.info"), overWindow: true)

    let list = makeExcControl("SysListView32", "",
                              Int32(0x1 /* LVS_REPORT */) | Int32(0x4000 /* LVS_NOCOLUMNHEADER */)
                              | Int32(0x8 /* LVS_SHOWSELALWAYS */) | Int32(WS_TABSTOP),
                              16, 44, clientW - 32, 220, hwnd, idExcList, exStyle: DWORD(WS_EX_CLIENTEDGE))
    SendMessageW(list, UINT(0x1036 /* LVM_SETEXTENDEDLISTVIEWSTYLE */), 0,
                 LPARAM(0x20 /* LVS_EX_FULLROWSELECT */ | 0x10000 /* LVS_EX_DOUBLEBUFFER */))
    var column = LVCOLUMNW()
    column.mask = UINT(0x2 /* LVCF_WIDTH */)
    column.cx = esc(clientW - 32) - GetSystemMetrics(SM_CXVSCROLL) - 4
    _ = withUnsafeMutablePointer(to: &column) {
        SendMessageW(list, UINT(0x1061 /* LVM_INSERTCOLUMNW */), 0, LPARAM(Int(bitPattern: $0)))
    }

    // Buttons: the three actions on the left, Done on the right, as on macOS.
    var x: Int32 = 16
    for (id, key) in [(idExcCurrent, "settings.exc.addCurrent"), (idExcChoose, "settings.exc.choose"),
                      (idExcRemove, "settings.exc.remove")] {
        let w = textWidth(L(key), hwnd) + 24
        makeExcControl("BUTTON", L(key), Int32(WS_TABSTOP), x, 276, w, 28, hwnd, id)
        x += w + 8
    }
    let doneW = max(textWidth(L("settings.exc.done"), hwnd) + 24, 80)
    makeExcControl("BUTTON", L("settings.exc.done"), Int32(WS_TABSTOP) | Int32(BS_DEFPUSHBUTTON),
                   clientW - 16 - doneW, 276, doneW, 28, hwnd, idExcDone)
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
        case idExcDone, 2 /* IDCANCEL: Esc */: DestroyWindow(hwnd)
        default: break
        }
    case UINT(WM_NOTIFY):
        if let raw = UnsafeRawPointer(bitPattern: Int(lParam)) {
            let hdr = raw.assumingMemoryBound(to: NMHDR.self).pointee
            guard hdr.idFrom == UINT_PTR(idExcList) else { break }
            if hdr.code == UINT(bitPattern: -101) /* LVN_ITEMCHANGED */ { updateRemoveButton(hwnd) }
            if hdr.code == UINT(bitPattern: -155) /* LVN_KEYDOWN */ {
                let key = raw.assumingMemoryBound(to: NMLVKEYDOWN.self).pointee.wVKey
                if key == WORD(VK_DELETE) { removeSelected(hwnd) }
            }
        }
    case UINT(WM_DESTROY):
        exceptionsHwnd = nil
        excTooltip = nil   // owned by the window: destroyed with it
        if let f = excGlyphFont { DeleteObject(UnsafeMutableRawPointer(f)); excGlyphFont = nil }
    default:
        break
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam)
}

/// The open Exceptions window, for keyboard navigation in the message loop.
func exceptionsWindow() -> HWND? { exceptionsHwnd }

func openExceptions(owner: HWND?) {
    if let existing = exceptionsHwnd {
        ShowWindow(existing, SW_SHOW)
        SetForegroundWindow(existing)
        return
    }
    let hInst = GetModuleHandleW(nil)
    if !exceptionsClassRegistered {
        exceptionsClassW.withUnsafeBufferPointer { name in
            var wc = WNDCLASSW()
            wc.lpfnWndProc = exceptionsWndProc
            wc.hInstance = hInst
            wc.lpszClassName = name.baseAddress
            wc.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))   // IDC_ARROW
            wc.hbrBackground = HBRUSH(bitPattern: Int(COLOR_BTNFACE) + 1)
            wc.hIcon = LoadIconW(hInst, UnsafePointer<WCHAR>(bitPattern: 1))          // app icon (id 1)
            exceptionsClassRegistered = RegisterClassW(&wc) != 0
        }
    }
    guard exceptionsClassRegistered else { return }

    let style = DWORD(WS_OVERLAPPED) | DWORD(WS_CAPTION) | DWORD(WS_SYSMENU)
    exceptionsHwnd = exceptionsClassW.withUnsafeBufferPointer { name in
        L("settings.exc.title").withCString(encodedAs: UTF16.self) { title in
            CreateWindowExW(0, name.baseAddress, title, style,
                            Int32(CW_USEDEFAULT), Int32(CW_USEDEFAULT), 440, 400,
                            owner, nil, hInst, nil)
        }
    }
    guard let hwnd = exceptionsHwnd else { return }
    let dpi = GetDpiForWindow(hwnd)
    excDpi = dpi > 0 ? Int32(dpi) : 96
    buildExceptions(hwnd)

    // Size to the scaled client area, centered over the owner (Settings).
    var wr = RECT(); GetWindowRect(hwnd, &wr)
    var cr = RECT(); GetClientRect(hwnd, &cr)
    let w = esc(clientW) + (wr.right - wr.left) - (cr.right - cr.left)
    let h = esc(clientH) + (wr.bottom - wr.top) - (cr.bottom - cr.top)
    var or = RECT(); GetWindowRect(owner, &or)
    SetWindowPos(hwnd, nil, or.left + ((or.right - or.left) - w) / 2, or.top + ((or.bottom - or.top) - h) / 2,
                 w, h, UINT(SWP_NOZORDER))
    ShowWindow(hwnd, SW_SHOW)
    SetForegroundWindow(hwnd)
}
