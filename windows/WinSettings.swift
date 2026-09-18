import WinSDK

// Native Settings window opened from the tray, laid out like the macOS one: logo
// and name, launch at login and language, the hotkey field, auto-correct with its
// options, and a centered version/link/copyright footer. Themed (ComCtl32 v6 via
// the app manifest), Segoe UI, DPI-scaled. Lives on the app's single UI thread.
// The controls are rebuilt, not patched, when the language or the DPI changes.

private let idChkStartup:    Int = 101
private let idLnkAbout:      Int = 104
private let idHotkeyField:   Int = 105
private let idBtnReset:      Int = 107
private let idChkAuto:       Int = 109
private let idChkAutoEnter:  Int = 110
private let idBtnExceptions: Int = 111
private let idCmbLanguage:   Int = 112
private let idAutoInfo:      Int = 113
private let idName:          Int = 114
// Secondary (gray) text: the caption column and the footer.
private let idCapLanguage:   Int = 120
private let idCapHotkey:     Int = 121
private let idVersion:       Int = 122
private let idCopyright:     Int = 123
private let secondaryIDs: Set<Int> = [idCapLanguage, idCapHotkey, idVersion, idCopyright]

private let idCancel: Int = 2   // IDCANCEL: Esc, through IsDialogMessageW
private let WM_REBUILD = UINT(WM_APP) + 20
private let tapTimer: UINT_PTR = 1
private let layoutTimer: UINT_PTR = 2

// The installed layouts the window was built for. Windows sends a background app no
// notice when one is added or removed, so while Settings is open the list is
// re-read every 2 s and on activation; a change rebuilds the window, which
// re-decides whether auto-correct is available (macOS reacts to its
// enabled-input-sources notification instead).
private var builtForLayouts: [UInt] = []

private func installedLayouts() -> [UInt] {
    WinLayout.installedList().map { UInt(bitPattern: $0.hkl) }
}

private func rebuildIfLayoutsChanged(_ hwnd: HWND?) {
    if installedLayouts() != builtForLayouts { PostMessageW(hwnd, WM_REBUILD, 0, 0) }
}

private var settingsHwnd: HWND?
private var settingsClassW = Array("ReLayoutSettingsWnd".utf16) + [0]
private var settingsClassRegistered = false

private var uiDpi: Int32 = 96
private var uiFont: HFONT?
private var nameFont: HFONT?
private var glyphFont: HFONT?
private var logoIcon: HICON?
private var tooltip: HWND?

// A bare-modifier tap waits this long for a second tap, which makes it a double tap
// — the Windows form of the macOS tap sequence recorded in the same field.
private let doubleTapCaptureMs: UINT = 350
private var pendingTapVK: UINT = 0

// NM_CLICK / NM_RETURN as UINT (NM_FIRST is 0, so these are 0u-2 / 0u-4).
private let nmClick  = UINT(bitPattern: -2)
private let nmReturn = UINT(bitPattern: -4)

private func sc(_ v: Int32) -> Int32 { v * uiDpi / 96 }   // scale a 96-dpi coord

// Client width at 96 dpi; the height follows the layout.
private let clientWidth: Int32 = 440
private let margin: Int32 = 20
private var clientHeight: Int32 = 400

private func font(_ face: String, points: Int32, bold: Bool = false) -> HFONT? {
    face.withCString(encodedAs: UTF16.self) { f in
        CreateFontW(-(points * uiDpi / 72), 0, 0, 0, Int32(bold ? FW_BOLD : FW_NORMAL),
                    0, 0, 0,
                    DWORD(DEFAULT_CHARSET), DWORD(OUT_DEFAULT_PRECIS),
                    DWORD(CLIP_DEFAULT_PRECIS), DWORD(CLEARTYPE_QUALITY),
                    DWORD(DEFAULT_PITCH), f)
    }
}

private func freeResources() {
    for f in [uiFont, nameFont, glyphFont] { if let f { DeleteObject(UnsafeMutableRawPointer(f)) } }
    uiFont = nil; nameFont = nil; glyphFont = nil
    if let icon = logoIcon { DestroyIcon(icon); logoIcon = nil }
    if let tip = tooltip { DestroyWindow(tip); tooltip = nil }   // a popup, not a child
}

private func makeResources() {
    freeResources()
    uiFont = font("Segoe UI", points: 9)
    nameFont = font("Segoe UI", points: 11, bold: true)
    glyphFont = font("Segoe MDL2 Assets", points: 10)   // Windows 10+ icon font
}

/// The Settings font, shared with the Exceptions window (opened from here).
func settingsFont() -> HFONT? { uiFont }

private func setFont(_ h: HWND?, _ f: HFONT?) {
    SendMessageW(h, UINT(WM_SETFONT), unsafeBitCast(f, to: WPARAM.self), LPARAM(1))
}

@discardableResult
private func makeControl(_ cls: String, _ text: String, _ style: Int32,
                         _ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32,
                         _ parent: HWND?, _ id: Int, exStyle: DWORD = 0) -> HWND? {
    let hInst = GetModuleHandleW(nil)
    return cls.withCString(encodedAs: UTF16.self) { clsP in
        text.withCString(encodedAs: UTF16.self) { txtP in
            let ctl = CreateWindowExW(exStyle, clsP, txtP,
                                      DWORD(UInt32(bitPattern: style)) | DWORD(WS_CHILD) | DWORD(WS_VISIBLE),
                                      sc(x), sc(y), sc(w), sc(h), parent, HMENU(bitPattern: id), hInst, nil)
            setFont(ctl, uiFont)
            return ctl
        }
    }
}

/// Width of `text` in the UI font, in 96-dpi units.
private func textWidth(_ text: String, _ hwnd: HWND?) -> Int32 {
    let dc = GetDC(hwnd)
    defer { ReleaseDC(hwnd, dc) }
    let old = SelectObject(dc, UnsafeMutableRawPointer(uiFont))
    defer { SelectObject(dc, old) }
    var size = SIZE()
    let units = Array(text.utf16)
    GetTextExtentPoint32W(dc, units, Int32(units.count), &size)
    return size.cx * 96 / uiDpi
}

private func setFieldText(_ hwnd: HWND?, _ id: Int, _ s: String) {
    s.withCString(encodedAs: UTF16.self) { _ = SetWindowTextW(GetDlgItem(hwnd, Int32(id)), $0) }
}

private func check(_ ctl: HWND?, _ on: Bool) {
    SendMessageW(ctl, UINT(BM_SETCHECK), WPARAM(on ? 1 : 0), 0)
}

private func isChecked(_ hwnd: HWND?, _ id: Int) -> Bool {
    SendMessageW(GetDlgItem(hwnd, Int32(id)), UINT(BM_GETCHECK), 0, 0) == LRESULT(BST_CHECKED)
}

// Apply a captured/reset hotkey: persist, re-arm the hook, refresh UI + tooltip.
private func applyHotkey(_ hwnd: HWND?, _ mods: UINT, _ vk: UINT, doubleTap: Bool) {
    saveHotkey(mods: mods, vk: vk)
    saveDoubleTap(doubleTap)
    setHotkey(mods, vk)
    setFieldText(hwnd, idHotkeyField, currentHotkeyDisplay())
    updateTrayTooltip()
}

// MARK: - hotkey field (click to record, like the macOS ShortcutField)

private func startRecording(_ hwnd: HWND?) {
    setFieldText(hwnd, idHotkeyField, L("win.pressKey"))
    startHotkeyCapture(onLive: { s in setFieldText(hwnd, idHotkeyField, s) },
                       onDone: { mods, vk in captured(hwnd, mods, vk) })
}

/// A combo is final. A bare-modifier tap waits for a second tap of the same key.
private func captured(_ hwnd: HWND?, _ mods: UINT, _ vk: UINT) {
    KillTimer(hwnd, tapTimer)
    if mods == 0, isModifierVK(vk) {
        if pendingTapVK == vk {
            pendingTapVK = 0
            finishRecording(hwnd, mods, vk, doubleTap: true)
            return
        }
        pendingTapVK = vk
        setFieldText(hwnd, idHotkeyField, hotkeyLabel(0, vk))
        SetTimer(hwnd, tapTimer, doubleTapCaptureMs, nil)
        startHotkeyCapture(onLive: { _ in }, onDone: { m, v in captured(hwnd, m, v) })
        return
    }
    pendingTapVK = 0
    finishRecording(hwnd, mods, vk, doubleTap: false)
}

private func finishRecording(_ hwnd: HWND?, _ mods: UINT, _ vk: UINT, doubleTap: Bool) {
    cancelHotkeyCapture()
    applyHotkey(hwnd, mods, vk, doubleTap: doubleTap)
    SetFocus(hwnd)   // leave the field, so the next click records again
}

// MARK: - layout

private func buildControls(_ hwnd: HWND?) {
    L("settings.title").withCString(encodedAs: UTF16.self) { _ = SetWindowTextW(hwnd, $0) }
    let content = clientWidth - 2 * margin
    var y: Int32 = margin

    // ── header: logo + name ──
    let logo = makeControl("STATIC", "", Int32(0x0003 /* SS_ICON */) | Int32(0x0200 /* SS_CENTERIMAGE */),
                           (clientWidth - 64) / 2, y, 64, 64, hwnd, 0)
    logoIcon = LoadImageW(GetModuleHandleW(nil), UnsafePointer<WCHAR>(bitPattern: 1), UINT(IMAGE_ICON),
                          sc(64), sc(64), 0).map { HICON(OpaquePointer($0)) }
    SendMessageW(logo, UINT(0x0170 /* STM_SETICON */), unsafeBitCast(logoIcon, to: WPARAM.self), 0)
    y += 70
    let name = makeControl("STATIC", "reLayout", Int32(0x0001 /* SS_CENTER */), margin, y, content, 24, hwnd, idName)
    setFont(name, nameFont)
    y += 36
    makeControl("STATIC", "", 0x0010 /* SS_ETCHEDHORZ */, margin, y, content, 1, hwnd, 0)
    y += 14

    // ── section A: launch at login + language ──
    let startup = makeControl("BUTTON", L("settings.openAtLogin"),
                              Int32(BS_AUTOCHECKBOX) | Int32(WS_TABSTOP), margin, y, content, 22, hwnd, idChkStartup)
    check(startup, startupEnabled())
    if !startupAvailable() { EnableWindow(startup, false) }
    y += 32

    // Right-aligned caption column shared by "Language:" and "Hotkey:".
    let captionW = max(textWidth(L("settings.language"), hwnd), textWidth(L("settings.hotkey"), hwnd)) + 4
    let fieldX = margin + captionW + 10
    let fieldW = clientWidth - margin - fieldX

    makeControl("STATIC", L("settings.language"), Int32(0x0002 /* SS_RIGHT */),
                margin, y + 4, captionW, 20, hwnd, idCapLanguage)
    let lang = makeControl("COMBOBOX", "", Int32(0x0003 /* CBS_DROPDOWNLIST */) | Int32(WS_VSCROLL) | Int32(WS_TABSTOP),
                           fieldX, y, fieldW, 240, hwnd, idCmbLanguage)
    for n in [L("settings.language.system")] + WinLoc.languages.map(\.name) {
        n.withCString(encodedAs: UTF16.self) {
            _ = SendMessageW(lang, UINT(0x0143 /* CB_ADDSTRING */), 0, LPARAM(Int(bitPattern: $0)))
        }
    }
    let selected = loadLanguage().flatMap { code in WinLoc.languages.firstIndex { $0.code == code } }.map { $0 + 1 } ?? 0
    SendMessageW(lang, UINT(0x014E /* CB_SETCURSEL */), WPARAM(selected), 0)
    y += 38
    makeControl("STATIC", "", 0x0010 /* SS_ETCHEDHORZ */, margin, y, content, 1, hwnd, 0)
    y += 14

    // ── section B: hotkey — click the field to record; ↺ restores the default ──
    makeControl("STATIC", L("settings.hotkey"), Int32(0x0002 /* SS_RIGHT */),
                margin, y + 4, captionW, 20, hwnd, idCapHotkey)
    makeControl("EDIT", currentHotkeyDisplay(),
                Int32(0x0800) /* ES_READONLY */ | Int32(0x0001) /* ES_CENTER */ | Int32(WS_TABSTOP),
                fieldX, y, fieldW - 34, 24, hwnd, idHotkeyField, exStyle: DWORD(WS_EX_CLIENTEDGE))
    let reset = makeControl("BUTTON", "\u{E7A7}" /* Undo glyph */, Int32(WS_TABSTOP),
                            clientWidth - margin - 28, y - 1, 28, 26, hwnd, idBtnReset)
    setFont(reset, glyphFont)
    addTooltip(&tooltip, hwnd, reset, L("settings.restoreDefault"))
    y += 38
    makeControl("STATIC", "", 0x0010 /* SS_ETCHEDHORZ */, margin, y, content, 1, hwnd, 0)
    y += 14

    // ── section C: auto-correct (ⓘ explains why it is off), Exceptions…, on Enter ──
    builtForLayouts = installedLayouts()
    let available = WinLayout.crossScriptAvailable()
    let autoTitle = L("settings.autoCorrect")
    let autoW = textWidth(autoTitle, hwnd) + 24   // + the check box itself
    let auto = makeControl("BUTTON", autoTitle, Int32(BS_AUTOCHECKBOX) | Int32(WS_TABSTOP),
                           margin, y, autoW, 22, hwnd, idChkAuto)
    check(auto, available && loadAutoMode())
    EnableWindow(auto, available)
    if !available {
        let info = makeControl("STATIC", "\u{E946}" /* Info glyph */, 0,
                               margin + autoW + 2, y + 2, 20, 20, hwnd, idAutoInfo)
        setFont(info, glyphFont)
        let installed = WinLayout.installedList().map(\.displayName).joined(separator: ", ")
        addTooltip(&tooltip, hwnd, info, L("settings.autoCorrectUnavailable", installed), overWindow: true)
    }
    let excTitle = L("settings.exceptions")
    let excW = textWidth(excTitle, hwnd) + 24
    let exceptions = makeControl("BUTTON", excTitle, Int32(WS_TABSTOP),
                                 clientWidth - margin - excW, y - 2, excW, 26, hwnd, idBtnExceptions)
    EnableWindow(exceptions, available)
    y += 28
    let onEnter = makeControl("BUTTON", L("settings.autoCorrectEnter"),
                              Int32(BS_AUTOCHECKBOX) | Int32(WS_TABSTOP), margin + 20, y, content - 20, 22,
                              hwnd, idChkAutoEnter)
    check(onEnter, loadAutoEnter())
    EnableWindow(onEnter, available && loadAutoMode())
    y += 42

    // ── footer: version, link, copyright — centered, secondary ──
    let version = L("win.version", appVersion)
    makeControl("STATIC", version.prefix(1).uppercased() + version.dropFirst(), Int32(0x0001 /* SS_CENTER */),
                margin, y, content, 18, hwnd, idVersion)
    y += 20
    if !repoSlug.isEmpty {
        let url = "github.com/\(repoSlug)"
        let linkW = textWidth(url, hwnd) + 8
        makeControl("SysLink", "<a>\(url)</a>", Int32(WS_TABSTOP),
                    (clientWidth - linkW) / 2, y, linkW, 18, hwnd, idLnkAbout)
        y += 20
    }
    makeControl("STATIC", "© 2026 Volodymyr Forfutdinov", Int32(0x0001 /* SS_CENTER */),
                margin, y, content, 18, hwnd, idCopyright)
    y += 18

    clientHeight = y + margin
}

/// Destroys every control and builds them again — for a language or DPI change.
private func rebuildControls(_ hwnd: HWND?) {
    cancelHotkeyCapture()   // its callbacks target the field being destroyed
    KillTimer(hwnd, tapTimer)
    pendingTapVK = 0
    var child = GetWindow(hwnd, UINT(GW_CHILD))
    while let c = child {
        child = GetWindow(c, UINT(GW_HWNDNEXT))
        DestroyWindow(c)
    }
    makeResources()
    buildControls(hwnd)
}

/// Sizes the window to the scaled client area; centers it on its monitor if asked.
private func fitClientArea(_ hwnd: HWND?, center: Bool) {
    var wr = RECT(); GetWindowRect(hwnd, &wr)
    var cr = RECT(); GetClientRect(hwnd, &cr)
    let w = sc(clientWidth) + (wr.right - wr.left) - (cr.right - cr.left)
    let h = sc(clientHeight) + (wr.bottom - wr.top) - (cr.bottom - cr.top)
    guard center else {
        SetWindowPos(hwnd, nil, 0, 0, w, h, UINT(SWP_NOMOVE) | UINT(SWP_NOZORDER))
        return
    }
    var mi = MONITORINFO(); mi.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
    GetMonitorInfoW(MonitorFromWindow(hwnd, DWORD(MONITOR_DEFAULTTONEAREST)), &mi)
    let x = mi.rcWork.left + ((mi.rcWork.right - mi.rcWork.left) - w) / 2
    let y = mi.rcWork.top  + ((mi.rcWork.bottom - mi.rcWork.top) - h) / 2
    SetWindowPos(hwnd, nil, x, y, w, h, UINT(SWP_NOZORDER))
}

// MARK: - window procedure

private func settingsWndProc(_ hwnd: HWND?, _ msg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    switch msg {
    case UINT(WM_CREATE):
        let dpi = GetDpiForWindow(hwnd)
        uiDpi = dpi > 0 ? Int32(dpi) : 96
        makeResources()
        buildControls(hwnd)
        fitClientArea(hwnd, center: true)
        SetTimer(hwnd, layoutTimer, 2000, nil)
    case UINT(0x02E0 /* WM_DPICHANGED */):
        // Moved to a monitor with another scale: rebuild at the new DPI and take the
        // position Windows suggests.
        uiDpi = Int32((UInt(truncatingIfNeeded: wParam) >> 16) & 0xFFFF)
        rebuildControls(hwnd)
        if let suggested = UnsafeRawPointer(bitPattern: Int(lParam))?.assumingMemoryBound(to: RECT.self).pointee {
            SetWindowPos(hwnd, nil, suggested.left, suggested.top, 0, 0, UINT(SWP_NOSIZE) | UINT(SWP_NOZORDER))
        }
        fitClientArea(hwnd, center: false)
        return 0
    case WM_REBUILD:
        rebuildControls(hwnd)
        fitClientArea(hwnd, center: false)
        return 0
    case UINT(WM_CTLCOLORSTATIC):
        // Captions and footer in the secondary color, like the macOS form.
        let ctl = HWND(bitPattern: Int(lParam))
        let dc = HDC(bitPattern: UInt(wParam))
        let id = Int(GetDlgCtrlID(ctl))
        if id == idHotkeyField { break }   // a read-only edit asks too: keep its default look
        if secondaryIDs.contains(id) {
            SetTextColor(dc, GetSysColor(COLOR_GRAYTEXT))
        }
        SetBkMode(dc, TRANSPARENT)
        return LRESULT(Int(bitPattern: GetSysColorBrush(COLOR_BTNFACE)))
    case UINT(WM_TIMER) where wParam == WPARAM(layoutTimer):
        rebuildIfLayoutsChanged(hwnd)
        return 0
    case UINT(WM_ACTIVATE) where (UInt(truncatingIfNeeded: wParam) & 0xFFFF) != 0 /* WA_INACTIVE */:
        rebuildIfLayoutsChanged(hwnd)   // back from Windows' keyboard settings
    case UINT(WM_TIMER) where wParam == WPARAM(tapTimer):
        // No second tap came: a single bare-modifier tap.
        KillTimer(hwnd, tapTimer)
        let vk = pendingTapVK
        pendingTapVK = 0
        if vk != 0 { finishRecording(hwnd, 0, vk, doubleTap: false) }
        return 0
    case UINT(WM_COMMAND):
        let notification = (UInt(truncatingIfNeeded: wParam) >> 16) & 0xFFFF
        switch Int(UInt(truncatingIfNeeded: wParam) & 0xFFFF) {
        case idCmbLanguage where notification == 1 /* CBN_SELCHANGE */:
            let index = Int(SendMessageW(GetDlgItem(hwnd, Int32(idCmbLanguage)), UINT(0x0147 /* CB_GETCURSEL */), 0, 0))
            saveLanguage(index > 0 && index <= WinLoc.languages.count ? WinLoc.languages[index - 1].code : nil)
            WinLoc.load()
            // Not here: the combo box is still inside its own notification, and
            // destroying it now crashes when it returns. Rebuild once it is done.
            PostMessageW(hwnd, WM_REBUILD, 0, 0)
        case idHotkeyField where notification == 0x0100 /* EN_SETFOCUS */:
            startRecording(hwnd)
        case idHotkeyField where notification == 0x0200 /* EN_KILLFOCUS */:
            // Focus left without a key: stop recording, show the hotkey again.
            if pendingTapVK == 0 {
                cancelHotkeyCapture()
                setFieldText(hwnd, idHotkeyField, currentHotkeyDisplay())
            }
        case idChkStartup:
            setStartup(isChecked(hwnd, idChkStartup))
            refreshSettingsStartup()   // shows a failed registry write as unchecked
        case idChkAuto:
            let on = isChecked(hwnd, idChkAuto)
            saveAutoMode(on)
            reloadAutoMode()
            EnableWindow(GetDlgItem(hwnd, Int32(idChkAutoEnter)), on)
        case idChkAutoEnter:
            saveAutoEnter(isChecked(hwnd, idChkAutoEnter))
            reloadAutoMode()
        case idBtnExceptions: openExceptions(owner: hwnd)
        case idBtnReset:
            cancelHotkeyCapture()
            applyHotkey(hwnd, defaultHotkey.mods, defaultHotkey.vk, doubleTap: false)
        case idCancel: DestroyWindow(hwnd)
        default: break
        }
    case UINT(WM_NOTIFY):
        if let raw = UnsafeRawPointer(bitPattern: Int(lParam)) {
            let hdr = raw.assumingMemoryBound(to: NMHDR.self).pointee
            if hdr.idFrom == UINT_PTR(idLnkAbout), hdr.code == nmClick || hdr.code == nmReturn {
                openExternally(aboutURL)
            }
        }
    case UINT(WM_DESTROY):
        cancelHotkeyCapture()       // don't leave a capture targeting a dead window
        KillTimer(hwnd, tapTimer)
        KillTimer(hwnd, layoutTimer)
        pendingTapVK = 0
        settingsHwnd = nil          // NB: do NOT PostQuitMessage — only this window closes
    case UINT(WM_NCDESTROY):        // children are gone: fonts, icon and tooltip are free
        freeResources()
    default:
        break
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam)
}

/// The open Settings window, for keyboard navigation in the message loop.
func settingsWindow() -> HWND? { settingsHwnd }

/// Syncs the open Settings window's launch-at-login checkbox with the registry.
func refreshSettingsStartup() {
    guard let hwnd = settingsHwnd else { return }
    check(GetDlgItem(hwnd, Int32(idChkStartup)), startupEnabled())
}

func openSettings() {
    if let existing = settingsHwnd {            // already open — just focus it
        ShowWindow(existing, SW_SHOW)
        SetForegroundWindow(existing)
        return
    }
    let hInst = GetModuleHandleW(nil)

    // SysLink and tooltips live in ComCtl32 — make sure their classes are registered.
    var icc = INITCOMMONCONTROLSEX()
    icc.dwSize = DWORD(MemoryLayout<INITCOMMONCONTROLSEX>.size)
    icc.dwICC  = DWORD(ICC_LINK_CLASS) | DWORD(ICC_WIN95_CLASSES) | DWORD(ICC_STANDARD_CLASSES)
    InitCommonControlsEx(&icc)

    if !settingsClassRegistered {
        settingsClassW.withUnsafeBufferPointer { name in
            var wc = WNDCLASSW()
            wc.lpfnWndProc = settingsWndProc
            wc.hInstance = hInst
            wc.lpszClassName = name.baseAddress
            wc.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))   // IDC_ARROW
            wc.hbrBackground = HBRUSH(bitPattern: Int(COLOR_BTNFACE) + 1)
            wc.hIcon = LoadIconW(hInst, UnsafePointer<WCHAR>(bitPattern: 1))          // app icon (id 1)
            settingsClassRegistered = RegisterClassW(&wc) != 0
        }
    }
    guard settingsClassRegistered else { return }

    let style = DWORD(WS_OVERLAPPED) | DWORD(WS_CAPTION) | DWORD(WS_SYSMENU)
    settingsHwnd = settingsClassW.withUnsafeBufferPointer { name in
        L("settings.title").withCString(encodedAs: UTF16.self) { title in
            CreateWindowExW(0, name.baseAddress, title, style,
                            Int32(CW_USEDEFAULT), Int32(CW_USEDEFAULT), 400, 240,
                            nil, nil, hInst, nil)
        }
    }
    ShowWindow(settingsHwnd, SW_SHOW)
    SetForegroundWindow(settingsHwnd)
    SetFocus(settingsHwnd)   // not the hotkey field: focusing it would start recording
}
