import WinSDK
import ReLayoutCore

// reLayout — Windows MVP. Hotkey -> read selection (clipboard) -> convert with the
// shared engine -> type the result -> switch layout. No tray/GUI yet; runs from a
// console. Selection-read is the Ctrl+C fallback for now (UI Automation later).

// Source = current (foreground) layout. Target = the other-script enabled layout,
// else simply the other one.
func performRetype() {
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
