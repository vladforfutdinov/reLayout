import WinSDK
import ReLayoutCore
import Dispatch

// Conversion runs off the UI thread: it synthesizes input and sleeps for ~200ms,
// and the low-level keyboard hook is serviced by the UI thread — blocking it past
// LowLevelHooksTimeout makes Windows silently drop the hook (hotkey dies). So the
// hook only posts; the actual retype happens on this serial queue.
private let convertQueue = DispatchQueue(label: "com.vlad.relayout.convert")

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

// "Trigger on double-tap": fire only on the second hotkey press within the
// window. While on, undo (press-again) is disabled — it would clash.
private var lastTriggerTick: DWORD = 0
private let doubleTapWindowMs: DWORD = 350

// Called for every hotkey activation (WM_RETYPE from the hook); gates the
// conversion on a double-press/tap when enabled.
func triggerHotkey() {
    func fire() { convertQueue.async { performRetype() } }
    guard loadDoubleTap() else { fire(); return }
    let now = GetTickCount()
    if now &- lastTriggerTick <= doubleTapWindowMs {
        lastTriggerTick = 0
        fire()
    } else {
        lastTriggerTick = now
    }
}

// Source = current (foreground) layout. Target = the other-script enabled layout,
// else simply the other one. In single-tap mode the result is left selected so a
// quick press-again undoes it; in double-tap mode it is not (see below).
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

    // Undo: only when the still-selected text IS our last output and it's recent.
    // Disabled when double-tap triggering is on (a second double-tap would clash).
    if !loadDoubleTap(), let last = lastConvert, GetTickCount() &- last.at <= undoWindowMs, text == last.converted {
        sendUnicode(last.original)
        selectLeft(last.original.count)        // keep it selected for repeat-undo/redo
        Sleep(20)
        switchLayout(to: last.src)
        lastConvert = nil
        return
    }

    let all = WinLayout.installedList()
    guard all.count >= 2 else { return }
    let dst = all.first(where: { $0.isCyrillic != cur.isCyrillic && $0.id != cur.id })
        ?? all.first(where: { $0.id != cur.id })
    guard let dst, let out = convertWrong(text, src: cur, dst: dst) else { return }
    sendUnicode(out)
    // Re-select the result ONLY in single-tap mode, so press-again undoes it. In
    // double-tap mode we must NOT leave it selected, else the next double-tap would
    // re-convert our own output instead of fresh text.
    if !loadDoubleTap() { selectLeft(out.count) }
    Sleep(20)
    switchLayout(to: dst)
    lastConvert = LastConvert(original: text, converted: out, src: cur, at: GetTickCount())
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
