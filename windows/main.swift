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
// MVP default: Ctrl+Alt+R (NOREPEAT so holding doesn't spam).
let mods = UINT(MOD_CONTROL) | UINT(MOD_ALT) | UINT(MOD_NOREPEAT)
if RegisterHotKey(nil, hotkeyID, mods, UINT(0x52)) == 0 {
    print("reLayout: failed to register hotkey")
    exit(1)
}
print("reLayout (Windows MVP) — hotkey: Ctrl+Alt+R. Select text, press it. Ctrl+C here to quit.")

var msg = MSG()
while GetMessageW(&msg, nil, 0, 0) > 0 {
    if msg.message == UINT(WM_HOTKEY), Int32(truncatingIfNeeded: msg.wParam) == hotkeyID {
        performRetype()
    }
    TranslateMessage(&msg)
    DispatchMessageW(&msg)
}
