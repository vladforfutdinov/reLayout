import WinSDK
import ReLayoutCore

// reLayout — Windows. Hotkey -> read the selection (UI Automation, else the
// clipboard) -> convert with the shared engine -> type the result -> switch layout.
// Pressing the hotkey again right after a conversion undoes it.

/// The last conversion (hotkey or auto mode), kept briefly so a second hotkey
/// press can put the original back.
struct Conversion {
    let original: String
    let typed: String
    let src: WinLayout
    let time: DWORD
}
private var lastConversion: Conversion?
private let undoWindowMs: DWORD = 1500

func recordConversion(original: String, typed: String, src: WinLayout) {
    lastConversion = Conversion(original: original, typed: typed, src: src, time: GetTickCount())
}

/// Any real keystroke or click moves on from the last conversion: the caret is no
/// longer right after the typed text, so undo would reselect the wrong characters.
func forgetConversion() {
    lastConversion = nil
}

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

func performRetype() {
    // Press-again undo. Off in double-tap mode, where a second press is the trigger.
    if !loadDoubleTap(), let last = lastConversion, GetTickCount() &- last.time < undoWindowMs {
        lastConversion = nil
        return performUndo(last)
    }
    guard !foregroundIsConsole(), let cur = WinLayout.current() else { return }
    guard waitModifiersReleased() else { return }

    // Selection only: the hotkey converts what the user pointed at, never a
    // guess at the word before the caret. Unselected text is the auto mode's job.
    guard let selected = readSelectedText() else { return retypeViaClipboard(cur) }
    retype(selected, cur: cur)
}

/// Converts the selected `text` and types the result over it. Which layouts it
/// converts between is the engine's call (`planRetype`), shared with macOS.
private func retype(_ text: String, cur: WinLayout) {
    guard !text.isEmpty else { return }
    let enabled = WinLayout.installedList()
    guard let curIdx = enabled.firstIndex(where: { $0.id == cur.id }),
          let plan = planRetype(text, enabled: enabled, curIdx: curIdx, model: trigram) else { return }
    guard sendUnicode(plan.out) else { return }
    pumpWait(20)
    switchLayout(to: plan.dst)
    recordConversion(original: plan.replaced, typed: plan.out, src: plan.src)
}

/// Reselects what the conversion typed (the caret sits right after it), types the
/// original back and returns to the source layout.
private func performUndo(_ last: Conversion) {
    guard waitModifiersReleased() else { return }
    selectLeft(last.typed.count)
    // A Tab boundary goes back as the real key, like it was typed (a line break
    // already does: sendUnicode turns it into Enter).
    if last.original.last == "\t" {
        guard sendUnicode(String(last.original.dropLast())) else { return }
        sendKeyTap(VK_TAB)
    } else {
        guard sendUnicode(last.original) else { return }
    }
    pumpWait(20)
    switchLayout(to: last.src)
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

WinLoc.load()

// Global hotkey via a low-level keyboard hook (see WinHotkey.swift) so a bare
// modifier (e.g. Left Shift) can be a hotkey, which RegisterHotKey can't do.
// The hook posts WM_RETYPE to this thread; we run the conversion here.
if !installHotkeyHook() {
    let err = GetLastError()
    let text = L("win.hookFailed", "\(err)")
    text.withCString(encodedAs: UTF16.self) { t in
        "reLayout".withCString(encodedAs: UTF16.self) { c in
            _ = MessageBoxW(nil, t, c, UINT(MB_ICONERROR))
        }
    }
    ExitProcess(1)
}
reloadAutoMode()
installAutoMouseHook()   // a click moves the caret: the typed-word buffer resets
_ = setupTray()

var msg = MSG()
while GetMessageW(&msg, nil, 0, 0) {
    if msg.message == WM_RETYPE {
        triggerHotkey()
    }
    // Tab / Shift+Tab / arrows / Space between the controls of our windows.
    if [settingsWindow(), exceptionsWindow()].contains(where: { $0 != nil && IsDialogMessageW($0, &msg) }) {
        continue
    }
    TranslateMessage(&msg)
    DispatchMessageW(&msg)
}

removeTray()
uninstallAutoMouseHook()
uninstallHotkeyHook()
