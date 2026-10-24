import WinSDK
import ReLayoutCore

// reLayout — Windows. Hotkey -> read the selection (UI Automation, else the
// clipboard) -> convert with the shared engine -> type the result -> switch layout.
// Pressing the hotkey again right after a conversion retypes the original into the
// next layout (three or more enabled), and once those readings run out undoes it.

/// The last conversion (hotkey or auto mode), for press-again (engine `PressAgain`).
typealias WinConversion = Conversion<WinLayout, WinLayout>
// Hook-thread state: any key or click forgets the record (`forgetConversion`).
private var pressAgain = PressAgain<WinLayout, WinLayout>()

/// The point a conversion starts from; pass it to `recordConversion`.
func conversionMark() -> Int { onHook { pressAgain.mark } }

func recordConversion(original: String, typed: String, src: WinLayout, since mark: Int,
                      learned: [String] = [], autoWords: [String] = [],
                      alternatives: [(out: String, dst: WinLayout)] = [], suffix: String = "") {
    let c = WinConversion(original: original, typed: typed, src: src,
                          learned: learned, autoWords: autoWords, alternatives: alternatives, suffix: suffix)
    onHook { pressAgain.record(c, since: mark) }
}

/// Any real keystroke or click moves on from the last conversion: the caret is no
/// longer right after the typed text, so undo would erase the wrong characters.
func forgetConversion() {
    onHook { pressAgain.forget() }
}

private var retypeMark = 0   // UI thread: conversionMark() when this hotkey press began

// "Trigger on double-tap" (engine `TapSequence`, as on macOS).
private var tapSequences = [TapSequence](repeating: TapSequence(), count: HotkeySlot.allCases.count)

// Called for every hotkey activation (WM_RETYPE / WM_TOGGLE_AUTO from the hook);
// gates it on a double-press/tap when that hotkey was recorded as one.
func triggerHotkey(_ slot: HotkeySlot) {
    guard tapSequences[slot.rawValue].activate(at: Double(GetTickCount64()) / 1000,
                                               taps: loadHotkey(slot).doubleTap ? 2 : 1) else { return }
    switch slot {
    case .retype:     performRetype()
    case .autoToggle: toggleAutoMode()
    }
}

func performRetype() {
    dwatch("hotkey")
    // Figma's canvas takes the erase backspaces and typed letters as tool commands.
    if hotkeyExcluded() { dwatch("hotkey: off in this app"); return }
    // Press-again: the next reading, then undo; a double-tap hotkey counts once
    // per completed double tap.
    retypeMark = conversionMark()
    switch onHook({ pressAgain.next() }) {
    case .retarget(let erase, let text, let dst, let then)?: return performRetarget(erase: erase, type: text, in: dst, then: then)
    case .undo(let last)?: return performUndo(last)
    case nil: break
    }
    guard let cur = WinLayout.current() else { return }
    guard waitModifiersReleased() else { return }

    // The selection, else the word just typed (the auto-mode run) — never a guess
    // at text before the caret that we did not see typed (engine `retypeSource`).
    let typed = typedWord()
    let console = foregroundIsConsole()
    switch retypeSource(selection: console ? nil : readSelectedText(), hasTypedWord: !typed.text.isEmpty,
                        console: console, probeBlocked: GetTickCount() &- lastEmptyProbe < 1000) {
    case .selection(let text): retype(text, cur: cur)
    case .typedWord: retypeTyped(typed, cur: cur)
    case .clipboardProbe: retypeViaClipboard(cur, typed: typed)
    case .nothing: dwatch("hotkey: nothing selected or typed")
    }
}

/// Nothing selected: backspaces the word just typed (and the spaces after it), types
/// its conversion and the same spaces.
private func retypeTyped(_ typed: (text: String, spaces: Int), cur: WinLayout) {
    guard !typed.text.isEmpty else { return }
    let enabled = WinLayout.installedList()
    guard let curIdx = enabled.firstIndex(where: { $0.id == cur.id }),
          let plan = planRetype(typed.text, enabled: enabled, curIdx: curIdx, model: trigram) else { return }
    let spaces = String(repeating: " ", count: typed.spaces)
    sendBackspaces(typed.text.count + typed.spaces)
    guard typeText(plan.out + spaces, in: plan.dst) else { return }
    resetAutoBuffer()
    recordConversion(original: typed.text + spaces, typed: plan.out + spaces, src: plan.src, since: retypeMark,
                     learned: learnHotkeyMisses(replaced: typed.text, out: plan.out, src: plan.src, dst: plan.dst),
                     alternatives: alternatives(typed.text, first: plan.out, src: plan.src, enabled: enabled),
                     suffix: spaces)
}

/// Converts the selected `text` and types the result over it. Which layouts it
/// converts between is the engine's call (`planRetype`), shared with macOS.
private func retype(_ text: String, cur: WinLayout) {
    guard !text.isEmpty else { return }
    let enabled = WinLayout.installedList()
    guard let curIdx = enabled.firstIndex(where: { $0.id == cur.id }),
          let plan = planRetype(text, enabled: enabled, curIdx: curIdx, model: trigram) else { return }
    guard typeText(plan.out, in: plan.dst) else { return }   // also leaves dst active
    resetAutoBuffer()
    recordConversion(original: text, typed: plan.out, src: plan.src, since: retypeMark,
                     learned: learnHotkeyMisses(replaced: text, out: plan.out, src: plan.src, dst: plan.dst),
                     alternatives: alternatives(text, first: plan.out, src: plan.src, enabled: enabled))
}

/// The other readings of a hotkey conversion for the press-again cycle (engine
/// `retypeAlternatives`); empty with two layouts.
private func alternatives(_ replaced: String, first: String, src: WinLayout,
                          enabled: [WinLayout]) -> [(out: String, dst: WinLayout)] {
    enabled.firstIndex(where: { $0.id == src.id }).map {
        retypeAlternatives(replaced, enabled: enabled, srcIdx: $0, first: first, model: trigram)
    } ?? []
}

/// Erases what the conversion typed and types the next reading of the original
/// in its layout; the remaining readings stay in the record.
private func performRetarget(erase: Int, type text: String, in dst: WinLayout, then: WinConversion) {
    guard waitModifiersReleased() else { return }
    resetAutoBuffer()
    sendBackspaces(erase)
    guard typeText(text, in: dst) else { return }   // also leaves dst active
    rememberSelection(text)
    let mark = retypeMark
    onHook { pressAgain.record(then, since: mark) }
}

/// Erases what the conversion typed (the caret sits right after it), types the
/// original back and returns to the source layout.
private func performUndo(_ last: WinConversion) {
    guard waitModifiersReleased() else { return }
    unlearn(last)
    resetAutoBuffer()
    sendBackspaces(last.typed.count)
    // The original goes back in its own layout, which also stays active. A Tab
    // boundary goes back as the real key, like it was typed.
    if last.original.last == "\t" {
        guard typeText(String(last.original.dropLast()), in: last.src) else { return }
        sendKeyTap(VK_TAB)
    } else {
        guard typeText(last.original, in: last.src) else { return }
    }
    rememberSelection(last.original)
}

/// Fallback for controls without UI Automation text (Electron, old apps): read the
/// selection with Ctrl+C and put the user's clipboard back afterwards. Nothing is
/// selected -> the word just typed.
// When the Ctrl+C probe last found nothing selected: a second synthetic Ctrl+C
// within a second would be DeepL's Ctrl+C-Ctrl+C trigger.
private var lastEmptyProbe: DWORD = 0

private func retypeViaClipboard(_ cur: WinLayout, typed: (text: String, spaces: Int)) {
    let saved = saveClipboard()
    let seq = GetClipboardSequenceNumber()
    let text = readSelection()
    if let saved, GetClipboardSequenceNumber() != seq { restoreClipboard(saved, owner: trayWindow()) }
    guard let text else { lastEmptyProbe = GetTickCount(); return retypeTyped(typed, cur: cur) }
    retype(text, cur: cur)
}

// One instance only: a second one (autostart + manual launch) would add a second
// hook and convert twice. The handle lives as long as the process.
let alreadyRunning = "Local\\reLayout".withCString(encodedAs: UTF16.self) { name -> Bool in
    CreateMutexW(nil, false, name) == nil || GetLastError() == DWORD(ERROR_ALREADY_EXISTS)
}
if alreadyRunning { ExitProcess(0) }

WinLoc.load()
dlogStartup()

// The tray window first: the hook thread posts fixes and UI work to it.
_ = setupTray()

// Global hotkey via a low-level keyboard hook (see WinHotkey.swift) so a bare
// modifier (e.g. Left Shift) can be a hotkey, which RegisterHotKey can't do.
// The hook (on its own thread, with the mouse hook) posts WM_RETYPE / WM_TOGGLE_AUTO
// to this thread; we act on them here.
keepOldHotkeyExclusions()   // before pinOldDefaultHotkey creates the prefs key
pinOldDefaultHotkey()
if !installHotkeyHook() {
    let err = GetLastError()
    let text = L("win.hookFailed", "\(err)")
    text.withCString(encodedAs: UTF16.self) { t in
        "reLayout".withCString(encodedAs: UTF16.self) { c in
            _ = MessageBoxW(nil, t, c, UINT(MB_ICONERROR))
        }
    }
    removeTray()
    ExitProcess(1)
}
reloadAutoMode()
refreshTrayIcon()        // drawn before the settings were read
// The first UI Automation call of a process takes long (COM, the client proxies):
// made now, not on the first typed word, whose password answer would come too late
// and leave that word uncorrected (nothing is corrected while it is pending).
_ = focusIsPasswordField()
trackForegroundApps()    // for "Exclude current app"

var msg = MSG()
while GetMessageW(&msg, nil, 0, 0) {
    if msg.message == WM_RETYPE {
        triggerHotkey(.retype)
    } else if msg.message == WM_TOGGLE_AUTO {
        triggerHotkey(.autoToggle)
    }
    // Tab / Shift+Tab / arrows / Space between the controls of our windows.
    if [settingsWindow(), exceptionsWindow(), learnedWindow()].contains(where: { $0 != nil && IsDialogMessageW($0, &msg) }) {
        continue
    }
    TranslateMessage(&msg)
    DispatchMessageW(&msg)
}

removeTray()
uninstallHotkeyHook()
