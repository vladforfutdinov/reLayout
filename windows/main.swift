import WinSDK
import ReLayoutCore

// reLayout — Windows. Hotkey -> read selection (clipboard) -> convert with the
// shared engine -> type the result -> switch layout. (No undo on Windows.)

// "Trigger on double-tap": fire only on the second hotkey press within the window.
private var lastTriggerTick: DWORD = 0
private let doubleTapWindowMs: DWORD = 350

// Called for every hotkey activation (WM_RETYPE from the hook); gates the
// conversion on a double-press/tap when enabled.
func triggerHotkey() {
    guard loadDoubleTap() else { performRetype(); return }
    let now = GetTickCount()
    if now &- lastTriggerTick <= doubleTapWindowMs {
        lastTriggerTick = 0
        performRetype()
    } else {
        lastTriggerTick = now
    }
}

// Source = current (foreground) layout. Target = the other-script enabled layout,
// else simply the other one. Each press converts fresh — no undo on Windows.
func performRetype() {
    guard let cur = WinLayout.current() else { return }
    waitModifiersReleased()

    // Read the selection; if nothing is selected, grab the current line up to the
    // caret (Shift+Home) so the hotkey still converts what was just typed.
    var sel = readSelection()
    if sel == nil || sel!.isEmpty {
        selectToLineStart()
        sel = readSelection()
    }
    guard let text = sel, !text.isEmpty else { return }

    let all = WinLayout.installedList()
    guard all.count >= 2 else { return }
    let dst = all.first(where: { $0.isCyrillic != cur.isCyrillic && $0.id != cur.id })
        ?? all.first(where: { $0.id != cur.id })
    guard let dst, let out = convertWrong(text, src: cur, dst: dst) else { return }
    sendUnicode(out)
    Sleep(20)
    switchLayout(to: dst)
}

// Global hotkey via a low-level keyboard hook (see WinHotkey.swift) so a bare
// modifier (e.g. Left Shift) can be a hotkey, which RegisterHotKey can't do.
// The hook posts WM_RETYPE to this thread; we run the conversion here.
installHotkeyHook()
_ = setupTray()

var msg = MSG()
while GetMessageW(&msg, nil, 0, 0) {
    if msg.message == WM_RETYPE {
        triggerHotkey()
    }
    TranslateMessage(&msg)
    DispatchMessageW(&msg)
}

removeTray()
uninstallHotkeyHook()
