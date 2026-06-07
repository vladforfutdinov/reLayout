import WinSDK
import ReLayoutCore

// reLayout — Windows MVP. Hotkey -> read selection (clipboard) -> convert with the
// shared engine -> type the result -> switch layout. No tray/GUI yet; runs from a
// console. Selection-read is the Ctrl+C fallback for now (UI Automation later).

// Last conversion, kept so a second hotkey press within the undo window reverts
// it (re-select what we typed, put the original back, restore the layout).
private struct LastConvert {
    let original: String
    let converted: String
    let src: WinLayout
    let at: DWORD          // GetTickCount() at conversion time
}
private var lastConvert: LastConvert?
private let undoWindowMs: DWORD = 1500

// Source = current (foreground) layout. Target = the other-script enabled layout,
// else simply the other one. A repeat press within ~1.5 s undoes instead.
func performRetype() {
    // Undo: press again quickly to revert the previous conversion.
    if let last = lastConvert, GetTickCount() &- last.at <= undoWindowMs {
        waitModifiersReleased()
        selectLeft(last.converted.count)
        sendUnicode(last.original)
        Sleep(20)
        switchLayout(to: last.src)
        lastConvert = nil
        return
    }

    guard let cur = WinLayout.current() else { return }
    let all = WinLayout.installedList()
    guard all.count >= 2 else { return }
    let dst = all.first(where: { $0.isCyrillic != cur.isCyrillic && $0.id != cur.id })
        ?? all.first(where: { $0.id != cur.id })
    guard let dst else { return }

    waitModifiersReleased()
    guard let text = readSelection(), !text.isEmpty,
          let out = convertWrong(text, src: cur, dst: dst) else { return }
    sendUnicode(out)
    Sleep(20)
    switchLayout(to: dst)
    lastConvert = LastConvert(original: text, converted: out, src: cur, at: GetTickCount())
}

let hotkeyID: Int32 = 1

// (Re)register the global convert hotkey, replacing any prior registration.
// NOREPEAT so holding the combo doesn't spam. Called at startup and whenever
// the hotkey is changed in Settings.
@discardableResult
func registerConvertHotkey(_ mods: UINT, _ vk: UINT) -> Bool {
    UnregisterHotKey(nil, hotkeyID)
    return RegisterHotKey(nil, hotkeyID, mods | UINT(MOD_NOREPEAT), vk)
}

// Load the saved hotkey (default Ctrl+Alt+R); if it can't be registered (e.g. a
// saved combo is taken by another app) fall back to the default.
let savedHotkey = loadHotkey()
if !registerConvertHotkey(savedHotkey.mods, savedHotkey.vk) {
    _ = registerConvertHotkey(UINT(MOD_CONTROL) | UINT(MOD_ALT), UINT(0x52))
}
_ = setupTray()

var msg = MSG()
while GetMessageW(&msg, nil, 0, 0) {
    if msg.message == UINT(WM_HOTKEY), Int32(truncatingIfNeeded: msg.wParam) == hotkeyID {
        performRetype()
    }
    TranslateMessage(&msg)
    DispatchMessageW(&msg)
}

removeTray()
UnregisterHotKey(nil, hotkeyID)
