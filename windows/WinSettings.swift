import WinSDK

// Native Settings window opened from the tray, laid out like the macOS one: logo
// and name, launch at login and language, the hotkey field, auto-correct with its
// options, and a centered version/link/copyright footer. Themed (ComCtl32 v6 via
// the app manifest), Segoe UI, DPI-scaled. Lives on the app's single UI thread.
// The controls are rebuilt, not patched, when the language or the DPI changes.

private let idChkStartup:    Int = 101
private let idLnkAbout:      Int = 104
private let idHotkeyField:   Int = 105
private let idAutoHotkeyField: Int = 106
private let idBtnReset:      Int = 107
private let idBtnAutoReset:  Int = 108
private let idChkAuto:       Int = 109
private let idChkAutoEnter:  Int = 110
private let idBtnExceptions: Int = 111
private let idCmbLanguage:   Int = 112
private let idAutoInfo:      Int = 113
private let idSimilarInfo:   Int = 118
private let idName:          Int = 114
private let idChkAutoSimilar: Int = 115
private let idChkAutoSpell:  Int = 116
private let idSpellInfo:     Int = 119
private let idBtnLearnedView: Int = 117
// Secondary (gray) text: the caption column and the footer.
private let idCapLanguage:   Int = 120
private let idCapHotkey:     Int = 121
private let idVersion:       Int = 122
private let idCopyright:     Int = 123
private let idCapAutoHotkey: Int = 124
private let idExcSection:    Int = 125
private let secondaryIDs: Set<Int> = [idCapLanguage, idCapHotkey, idCapAutoHotkey, idVersion, idCopyright]

private func hotkeyIDs(_ slot: HotkeySlot) -> (caption: Int, field: Int, reset: Int) {
    switch slot {
    case .retype:     return (idCapHotkey, idHotkeyField, idBtnReset)
    case .autoToggle: return (idCapAutoHotkey, idAutoHotkeyField, idBtnAutoReset)
    }
}

private let idSeparator:     Int = 150
// A check box's title is a separate label with the box's id + labelOffset.
private let labelOffset = 1000

private let idCancel: Int = 2   // IDCANCEL: Esc, through IsDialogMessageW
private let WM_REBUILD = UINT(WM_APP) + 20
private let tapTimer: UINT_PTR = 1
private let layoutTimer: UINT_PTR = 2
private let themeTimer: UINT_PTR = 3

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
    guard installedLayouts() != builtForLayouts else { return }
    PostMessageW(hwnd, WM_REBUILD, 0, 0)
    refreshTrayIcon()   // the auto-correct dot follows availability
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
private var colors = ThemeColors.current()
private var backgroundBrush: HBRUSH?
private var separatorBrush: HBRUSH?

// A bare-modifier tap waits this long for a second tap, which makes it a double tap
// — the Windows form of the macOS tap sequence recorded in the same field.
private let doubleTapCaptureMs: UINT = 350
private var pendingTapVK: UINT = 0
private var pendingTapMods: UINT = 0   // a chord tap waiting for its second (vk `chordVK`)
private var recordingSlot = HotkeySlot.retype

// NM_CLICK / NM_RETURN as UINT (NM_FIRST is 0, so these are 0u-2 / 0u-4).
private let nmClick  = UINT(bitPattern: -2)
private let nmReturn = UINT(bitPattern: -4)

private func sc(_ v: Int32) -> Int32 { v * uiDpi / 96 }   // scale a 96-dpi coord

// Client size at 96 dpi; both follow the content (the widest row), like the macOS
// window, so long translations fit and short ones leave no empty margin.
private var clientWidth: Int32 = 360
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
    for b in [backgroundBrush, separatorBrush] { if let b { DeleteObject(UnsafeMutableRawPointer(b)) } }
    backgroundBrush = nil; separatorBrush = nil
}

private func makeResources() {
    freeResources()
    uiFont = font("Segoe UI", points: 9)
    nameFont = font("Segoe UI", points: 11, bold: true)
    glyphFont = font("Segoe MDL2 Assets", points: 10)   // Windows 10+ icon font
    colors = ThemeColors.current()
    backgroundBrush = CreateSolidBrush(colors.background)
    separatorBrush = CreateSolidBrush(colors.separator)
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
            applyControlTheme(ctl, className: cls, dark: colors.dark)
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

/// Height of `text` in the UI font, wrapped at `width`, in 96-dpi units.
private func textHeight(_ text: String, width: Int32, _ hwnd: HWND?) -> Int32 {
    let dc = GetDC(hwnd)
    defer { ReleaseDC(hwnd, dc) }
    let old = SelectObject(dc, UnsafeMutableRawPointer(uiFont))
    defer { SelectObject(dc, old) }
    var r = RECT(left: 0, top: 0, right: sc(width), bottom: 0)
    let units = Array(text.utf16)
    DrawTextW(dc, units, Int32(units.count), &r, UINT(0x400 /* DT_CALCRECT */ | 0x10 /* DT_WORDBREAK */
                                                      | 0x800 /* DT_NOPREFIX */))
    return (r.bottom * 96 + uiDpi - 1) / uiDpi
}

private func setFieldText(_ hwnd: HWND?, _ id: Int, _ s: String) {
    s.withCString(encodedAs: UTF16.self) { _ = SetWindowTextW(GetDlgItem(hwnd, Int32(id)), $0) }
}

/// A check box whose title is a separate label: a themed check box draws its text
/// black even in dark mode, a static label takes the theme's color. Clicking the
/// label clicks the box (WM_COMMAND).
@discardableResult
private func makeCheck(_ title: String, _ x: Int32, _ y: Int32, _ w: Int32, _ hwnd: HWND?, _ id: Int,
                       on: Bool, enabled: Bool) -> HWND? {
    let box = makeControl("BUTTON", "", Int32(BS_AUTOCHECKBOX) | Int32(WS_TABSTOP), x, y + 2, 18, 18, hwnd, id)
    // The box has no text of its own (the label is a static), so its focus cue is a
    // stray dotted sliver beside it: hide it.
    SendMessageW(box, 0x0128 /* WM_UPDATEUISTATE */, WPARAM(0x0001_0001) /* UIS_SET, UISF_HIDEFOCUS */, 0)
    check(box, on)
    makeControl("STATIC", title, Int32(0x0100 /* SS_NOTIFY */), x + 22, y + 3, w - 22, 20, hwnd, id + labelOffset)
    enableCheck(hwnd, id, enabled)
    return box
}

/// Only the box is disabled: a disabled static draws etched text and ignores
/// WM_CTLCOLORSTATIC, which looks smeared in dark mode. The label turns gray there.
private func enableCheck(_ hwnd: HWND?, _ id: Int, _ on: Bool) {
    EnableWindow(GetDlgItem(hwnd, Int32(id)), on)
    InvalidateRect(GetDlgItem(hwnd, Int32(id + labelOffset)), nil, true)
}

/// A 1 px rule in the theme's separator color (an etched line reads wrong in dark).
private func separator(_ hwnd: HWND?, _ y: Int32, _ width: Int32) {
    makeControl("STATIC", "", 0, margin, y, width, 1, hwnd, idSeparator)
}

private func check(_ ctl: HWND?, _ on: Bool) {
    SendMessageW(ctl, UINT(BM_SETCHECK), WPARAM(on ? 1 : 0), 0)
}

private func isChecked(_ hwnd: HWND?, _ id: Int) -> Bool {
    SendMessageW(GetDlgItem(hwnd, Int32(id)), UINT(BM_GETCHECK), 0, 0) == LRESULT(BST_CHECKED)
}

/// Saves and arms `hk` for `slot`, then shows the slot's hotkey. The other slot's
/// keys are refused with a beep: one press would fire both.
private func assignHotkey(_ hwnd: HWND?, _ slot: HotkeySlot, _ hk: Hotkey) {
    if hk.clashes(with: loadHotkey(slot.other)) {
        _ = MessageBeep(UINT(MB_ICONWARNING))
    } else {
        saveHotkey(slot, hk)
        setHotkey(slot, hk)
        updateTrayTooltip()
    }
    setFieldText(hwnd, hotkeyIDs(slot).field, hotkeyDisplay(slot))
}

// MARK: - hotkey fields (click to record, like the macOS ShortcutField)

/// Ends a recording, including a tap still waiting for its second.
private func stopRecording(_ hwnd: HWND?) {
    cancelHotkeyCapture()
    KillTimer(hwnd, tapTimer)
    pendingTapVK = 0
}

private func startRecording(_ hwnd: HWND?, _ slot: HotkeySlot) {
    if pendingTapVK != 0 {   // a tap still waiting for its second: drop it
        stopRecording(hwnd)
        setFieldText(hwnd, hotkeyIDs(recordingSlot).field, hotkeyDisplay(recordingSlot))
    }
    recordingSlot = slot
    let field = hotkeyIDs(slot).field
    setFieldText(hwnd, field, L("win.pressKey"))
    startHotkeyCapture(onLive: { s in setFieldText(hwnd, field, s) },
                       onDone: { mods, vk in captured(hwnd, mods, vk) })
}

/// A combo is final. A bare-modifier tap waits for a second tap of the same key.
private func captured(_ hwnd: HWND?, _ mods: UINT, _ vk: UINT) {
    KillTimer(hwnd, tapTimer)
    if (mods == 0 && isModifierVK(vk)) || vk == chordVK {
        if pendingTapVK == vk, pendingTapMods == mods {
            pendingTapVK = 0
            finishRecording(hwnd, mods, vk, doubleTap: true)
            return
        }
        pendingTapVK = vk; pendingTapMods = mods
        setFieldText(hwnd, hotkeyIDs(recordingSlot).field, hotkeyLabel(mods, vk))
        SetTimer(hwnd, tapTimer, doubleTapCaptureMs, nil)
        startHotkeyCapture(onLive: { _ in }, onDone: { m, v in captured(hwnd, m, v) })
        return
    }
    pendingTapVK = 0
    finishRecording(hwnd, mods, vk, doubleTap: false)
}

private func finishRecording(_ hwnd: HWND?, _ mods: UINT, _ vk: UINT, doubleTap: Bool) {
    cancelHotkeyCapture()
    assignHotkey(hwnd, recordingSlot, Hotkey(mods: mods, vk: vk, doubleTap: doubleTap))
    SetFocus(hwnd)   // leave the button; the next click records again
}

// MARK: - layout

private func buildControls(_ hwnd: HWND?) {
    L("settings.title").withCString(encodedAs: UTF16.self) { _ = SetWindowTextW(hwnd, $0) }
    applyTitleBarTheme(hwnd, dark: colors.dark)
    // Widest row decides the width: auto-correct + ⓘ, the indented options and
    // learned words, Exceptions… beside a few words of its (wrapping) label, the
    // caption column + a usable field, the footer link.
    let captionW = ["settings.language", "settings.hotkey", "settings.autoHotkey"]
        .map { textWidth(L($0), hwnd) }.max()! + 4
    let autoTitle = L("settings.autoCorrect")
    let autoW = textWidth(autoTitle, hwnd) + 24   // + the check box itself
    let excTitle = L("settings.exceptions")
    let excW = textWidth(excTitle, hwnd) + 24
    let similarTitle = L("settings.autoCorrectSimilar")
    let spellTitle = L("settings.autoCorrectSpell")
    let learnedW = textWidth(L("settings.learned", "0000"), hwnd) + 4   // room for the count to grow
    let learnedViewTitle = L("settings.learned.view")
    let learnedViewW = textWidth(learnedViewTitle, hwnd) + 24
    let rows: [Int32] = [
        autoW + 24,
        160 + 16 + excW,
        20 + textWidth(L("settings.autoCorrectEnter"), hwnd) + 24,
        20 + textWidth(similarTitle, hwnd) + 24 + 22,
        20 + textWidth(spellTitle, hwnd) + 24 + 22,
        20 + learnedW + 8 + learnedViewW,
        textWidth(L("settings.openAtLogin"), hwnd) + 24,
        captionW + 10 + 200,
        textWidth("github.com/\(repoSlug)", hwnd) + 8,
    ]
    clientWidth = max(rows.max() ?? 0, 280) + 2 * margin
    let content = clientWidth - 2 * margin
    var y: Int32 = margin

    // ── header: logo + name ──
    let logo = makeControl("STATIC", "", Int32(0x0003 /* SS_ICON */) | Int32(0x0200 /* SS_CENTERIMAGE */),
                           (clientWidth - 64) / 2, y, 64, 64, hwnd, 0)
    // The app-icon tile in contrast to the window: dark in light mode, light in dark.
    logoIcon = LoadImageW(GetModuleHandleW(nil), UnsafePointer<WCHAR>(bitPattern: colors.dark ? 5 : 4),
                          UINT(IMAGE_ICON), sc(64), sc(64), 0).map { HICON(OpaquePointer($0)) }
    SendMessageW(logo, UINT(0x0170 /* STM_SETICON */), unsafeBitCast(logoIcon, to: WPARAM.self), 0)
    y += 70
    let name = makeControl("STATIC", "reLayout", Int32(0x0001 /* SS_CENTER */), margin, y, content, 24, hwnd, idName)
    setFont(name, nameFont)
    y += 36
    separator(hwnd, y, content)
    y += 14

    // ── section A: launch at login + language ──
    makeCheck(L("settings.openAtLogin"), margin, y, content, hwnd, idChkStartup,
              on: startupEnabled(), enabled: startupAvailable())
    y += 32

    // Left-aligned caption column shared by "Language:" and the hotkeys, as on macOS.
    let fieldX = margin + captionW + 10
    let fieldW = clientWidth - margin - fieldX

    makeControl("STATIC", L("settings.language"), 0,
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
    separator(hwnd, y, content)
    y += 14

    // ── section B: hotkeys — click one (or Space) to record; ↺ restores its default ──
    // A button, not an edit box: nothing to select, no text caret, reachable by Tab.
    // BS_NOTIFY reports losing focus, which ends a recording.
    for (slot, caption) in [(HotkeySlot.retype, L("settings.hotkey")), (HotkeySlot.autoToggle, L("settings.autoHotkey"))] {
        let ids = hotkeyIDs(slot)
        makeControl("STATIC", caption, 0,
                    margin, y + 4, captionW, 20, hwnd, ids.caption)
        makeControl("BUTTON", hotkeyDisplay(slot), Int32(0x4000 /* BS_NOTIFY */) | Int32(WS_TABSTOP),
                    fieldX, y - 1, fieldW - 34, 26, hwnd, ids.field)
        let reset = makeControl("BUTTON", "\u{E7A7}" /* Undo glyph */, Int32(WS_TABSTOP),
                                clientWidth - margin - 28, y - 1, 28, 26, hwnd, ids.reset)
        setFont(reset, glyphFont)
        addTooltip(&tooltip, hwnd, reset, L("settings.restoreDefault"))
        y += slot == .retype ? 32 : 38
    }
    separator(hwnd, y, content)
    y += 14

    // ── section C: auto-correct (ⓘ explains why it is off), on Enter, options ──
    // A sub-option the system rules out (no layouts for it) shows off; one disabled
    // only because auto-correct is off shows its stored state.
    builtForLayouts = installedLayouts()
    let available = WinLayout.crossScriptAvailable()
    makeCheck(autoTitle, margin, y, autoW, hwnd, idChkAuto, on: available && loadAutoMode(), enabled: available)
    if !available {
        let info = makeControl("STATIC", "\u{E946}" /* Info glyph */, Int32(0x0200 /* SS_CENTERIMAGE */),
                               margin + autoW + 2, y + 3, 20, 16, hwnd, idAutoInfo)
        setFont(info, glyphFont)
        let installed = WinLayout.installedList().map(\.displayName).joined(separator: ", ")
        addTooltip(&tooltip, hwnd, info, L("settings.autoCorrectUnavailable", installed), overWindow: true)
    }
    y += 28
    makeCheck(L("settings.autoCorrectEnter"), margin + 20, y, content - 20, hwnd, idChkAutoEnter,
              on: available && loadAutoEnter(), enabled: available && loadAutoMode())
    y += 28
    // The ⓘ stays live while the checkbox is disabled: it says why.
    let similarW = textWidth(similarTitle, hwnd) + 24
    makeCheck(similarTitle, margin + 20, y, similarW, hwnd, idChkAutoSimilar,
              on: available && similarAvailable() && loadAutoSameScript(),
              enabled: available && loadAutoMode() && similarAvailable())
    // Centred on the label's text line (y + 3, one line tall), not top-aligned:
    // the icon font's glyph sits high in its cell.
    let similarInfo = makeControl("STATIC", "\u{E946}" /* Info glyph */, Int32(0x0200 /* SS_CENTERIMAGE */),
                                  margin + 20 + similarW + 2, y + 3, 20, 16, hwnd, idSimilarInfo)
    setFont(similarInfo, glyphFont)
    addTooltip(&tooltip, hwnd, similarInfo, L("settings.autoCorrectSimilar.tip"), overWindow: true)
    y += 28
    let spellW = textWidth(spellTitle, hwnd) + 24
    let spellPossible = available && spellAvailable()
    makeCheck(spellTitle, margin + 20, y, spellW, hwnd, idChkAutoSpell,
              on: spellPossible && loadAutoSpell(), enabled: spellPossible && loadAutoMode())
    let spellInfo = makeControl("STATIC", "\u{E946}" /* Info glyph */, Int32(0x0200 /* SS_CENTERIMAGE */),
                                margin + 20 + spellW + 2, y + 3, 20, 16, hwnd, idSpellInfo)
    setFont(spellInfo, glyphFont)
    addTooltip(&tooltip, hwnd, spellInfo, L("settings.autoCorrectSpell.tip"), overWindow: true)
    y += 30
    // The count takes the View button's id + labelOffset, so it grays with the button.
    makeControl("STATIC", L("settings.learned", "\(learnedCount())"), 0,
                margin + 20, y + 4, learnedW, 20, hwnd, idBtnLearnedView + labelOffset)
    // Flush right, like the buttons of the other sections.
    let learnedView = makeControl("BUTTON", learnedViewTitle, Int32(WS_TABSTOP),
                                  clientWidth - margin - learnedViewW, y - 2, learnedViewW, 26, hwnd, idBtnLearnedView)
    EnableWindow(learnedView, available && loadAutoMode())
    y += 38
    separator(hwnd, y, content)
    y += 14

    // ── section D: Exceptions… — always enabled, it covers the hotkey too ──
    let excLabel = L("settings.exc.section")
    let excLabelW = content - excW - 16
    let excLabelH = textHeight(excLabel, width: excLabelW, hwnd)
    let excRowH = max(excLabelH, 26)
    makeControl("STATIC", excLabel, 0, margin, y + (excRowH - excLabelH) / 2, excLabelW, excLabelH, hwnd, idExcSection)
    makeControl("BUTTON", excTitle, Int32(WS_TABSTOP),
                clientWidth - margin - excW, y + (excRowH - 26) / 2, excW, 26, hwnd, idBtnExceptions)
    y += excRowH + 16

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
    stopRecording(hwnd)   // its callbacks target the field being destroyed
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
        rebuildWithoutFlicker(hwnd) {
            rebuildControls(hwnd)
            fitClientArea(hwnd, center: false)
        }
        return 0
    case UINT(WM_CTLCOLORSTATIC), UINT(WM_CTLCOLORBTN):
        // Theme colors: gray for captions, the footer and disabled titles.
        let ctl = HWND(bitPattern: Int(lParam))
        let dc = HDC(bitPattern: UInt(wParam))
        let id = Int(GetDlgCtrlID(ctl))
        if id == idSeparator { return LRESULT(Int(bitPattern: separatorBrush)) }
        let enabled = IsWindowEnabled(id > labelOffset ? GetDlgItem(hwnd, Int32(id - labelOffset)) : ctl)
        SetTextColor(dc, secondaryIDs.contains(id) || !enabled ? colors.secondary : colors.text)
        SetBkColor(dc, colors.background)
        SetBkMode(dc, TRANSPARENT)
        return LRESULT(Int(bitPattern: backgroundBrush))
    case UINT(WM_CTLCOLORLISTBOX), UINT(WM_CTLCOLOREDIT) where colors.dark:   // the language list
        let dc = HDC(bitPattern: UInt(wParam))
        SetTextColor(dc, colors.text)
        SetBkColor(dc, colors.background)
        return LRESULT(Int(bitPattern: backgroundBrush))
    case UINT(WM_ERASEBKGND):
        var r = RECT()
        GetClientRect(hwnd, &r)
        FillRect(HDC(bitPattern: UInt(wParam)), &r, backgroundBrush)
        return 1
    case UINT(WM_SETTINGCHANGE):
        // A theme switch arrives as a burst of broadcasts, some before the registry
        // holds the new value: check once, shortly after the last one.
        SetTimer(hwnd, themeTimer, 300, nil)
    case UINT(WM_TIMER) where wParam == WPARAM(themeTimer):
        KillTimer(hwnd, themeTimer)
        if appsUseDarkTheme() != colors.dark { PostMessageW(hwnd, WM_REBUILD, 0, 0) }
        return 0
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
        if vk != 0 { finishRecording(hwnd, pendingTapMods, vk, doubleTap: false) }
        return 0
    case UINT(WM_COMMAND):
        let notification = (UInt(truncatingIfNeeded: wParam) >> 16) & 0xFFFF
        switch Int(UInt(truncatingIfNeeded: wParam) & 0xFFFF) {
        case let label where label > labelOffset && notification == 0 /* STN_CLICKED */:
            // A check box's title was clicked: click the box.
            let box = GetDlgItem(hwnd, Int32(label - labelOffset))
            if IsWindowEnabled(box) { SendMessageW(box, UINT(0x00F5 /* BM_CLICK */), 0, 0) }
        case idCmbLanguage where notification == 1 /* CBN_SELCHANGE */:
            let index = Int(SendMessageW(GetDlgItem(hwnd, Int32(idCmbLanguage)), UINT(0x0147 /* CB_GETCURSEL */), 0, 0))
            saveLanguage(index > 0 && index <= WinLoc.languages.count ? WinLoc.languages[index - 1].code : nil)
            WinLoc.load()
            // Not here: the combo box is still inside its own notification, and
            // destroying it now crashes when it returns. Rebuild once it is done.
            PostMessageW(hwnd, WM_REBUILD, 0, 0)
        case let field where field == idHotkeyField || field == idAutoHotkeyField:
            let slot: HotkeySlot = field == idHotkeyField ? .retype : .autoToggle
            if notification == 0 /* BN_CLICKED */ {
                startRecording(hwnd, slot)
            } else if notification == 7 /* BN_KILLFOCUS */, pendingTapVK == 0 {
                // Focus left without a key: stop recording, show the hotkey again.
                cancelHotkeyCapture()
                setFieldText(hwnd, field, hotkeyDisplay(slot))
            }
        case idChkStartup:
            setStartup(isChecked(hwnd, idChkStartup))
            refreshSettingsStartup()   // shows a failed registry write as unchecked
        case idChkAuto:
            setAutoMode(isChecked(hwnd, idChkAuto))
        case idChkAutoEnter:
            saveAutoEnter(isChecked(hwnd, idChkAutoEnter))
            reloadAutoMode()
        case idChkAutoSimilar:
            saveAutoSameScript(isChecked(hwnd, idChkAutoSimilar))
            reloadAutoMode()
        case idChkAutoSpell:
            saveAutoSpell(isChecked(hwnd, idChkAutoSpell))
            reloadAutoMode()
        case idBtnLearnedView: openLearned(owner: hwnd)
        case idBtnExceptions: openExceptions(owner: hwnd)
        case idBtnReset:
            stopRecording(hwnd)
            assignHotkey(hwnd, .retype, defaultHotkey(.retype))
        case idBtnAutoReset:
            stopRecording(hwnd)
            assignHotkey(hwnd, .autoToggle, defaultHotkey(.autoToggle))
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
        stopRecording(hwnd)         // don't leave a capture targeting a dead window
        KillTimer(hwnd, layoutTimer)
        KillTimer(hwnd, themeTimer)
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

/// Syncs the open Settings window's auto-correct checkbox and the options under it.
func refreshSettingsAuto() {
    refreshSettingsLearned()
    guard let hwnd = settingsHwnd else { return }
    let on = autoModeActive()
    check(GetDlgItem(hwnd, Int32(idChkAuto)), on)
    enableCheck(hwnd, idChkAutoEnter, on)
    enableCheck(hwnd, idChkAutoSimilar, on && similarAvailable())
    enableCheck(hwnd, idChkAutoSpell, on && spellAvailable())
}

/// Syncs the open Settings window's learned-words count and View button, and the
/// Learned words window's list.
func refreshSettingsLearned() {
    refreshLearnedWindow()
    guard let hwnd = settingsHwnd else { return }
    setFieldText(hwnd, idBtnLearnedView + labelOffset, L("settings.learned", "\(learnedCount())"))
    enableCheck(hwnd, idBtnLearnedView, WinLayout.crossScriptAvailable() && loadAutoMode())
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
    SetFocus(settingsHwnd)
}

