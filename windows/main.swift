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
    guard !foregroundIsConsole(), let cur = WinLayout.current() else { return }
    guard waitModifiersReleased() else { return }

    // Selection only: the hotkey converts what the user pointed at, never a
    // guess at the word before the caret. Unselected text is the auto mode's job.
    guard let selected = readSelectedText() else { return retypeViaClipboard(cur) }
    retype(selected, cur: cur)
}

/// Converts the selected `text` and types the result over it.
private func retype(_ text: String, cur: WinLayout) {
    guard !text.isEmpty else { return }
    let all = WinLayout.installedList()
    guard all.count >= 2 else { return }
    let dst = all.first(where: { $0.isCyrillic != cur.isCyrillic && $0.id != cur.id })
        ?? all.first(where: { $0.id != cur.id })
    guard let dst, let out = convertWrong(text, src: cur, dst: dst) else { return }
    guard sendUnicode(out) else { return }
    pumpWait(20)
    switchLayout(to: dst)
}

/// Fallback for controls without UI Automation text (Electron, old apps): read the
/// selection with Ctrl+C and put the user's clipboard back afterwards. Nothing is
/// selected -> nothing to convert.
private func retypeViaClipboard(_ cur: WinLayout) {
    let saved = saveClipboard()
    let seq = GetClipboardSequenceNumber()
    defer {
        if let saved, GetClipboardSequenceNumber() != seq { restoreClipboard(saved, owner: trayWindow()) }
    }
    guard let text = readSelection() else { return }
    retype(text, cur: cur)
}

// One instance only: a second one (autostart + manual launch) would add a second
// hook and convert twice. The handle lives as long as the process.
let alreadyRunning = "Local\\reLayout".withCString(encodedAs: UTF16.self) { name -> Bool in
    CreateMutexW(nil, false, name) == nil || GetLastError() == DWORD(ERROR_ALREADY_EXISTS)
}
if alreadyRunning { ExitProcess(0) }

// Global hotkey via a low-level keyboard hook (see WinHotkey.swift) so a bare
// modifier (e.g. Left Shift) can be a hotkey, which RegisterHotKey can't do.
// The hook posts WM_RETYPE to this thread; we run the conversion here.
if !installHotkeyHook() {
    let err = GetLastError()
    let text = "reLayout could not install its keyboard hook (error \(err))."
    text.withCString(encodedAs: UTF16.self) { t in
        "reLayout".withCString(encodedAs: UTF16.self) { c in
            _ = MessageBoxW(nil, t, c, UINT(MB_ICONERROR))
        }
    }
    ExitProcess(1)
}
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
