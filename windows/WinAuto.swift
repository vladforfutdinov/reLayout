import WinSDK
import Foundation
import ReLayoutCore

// Auto-correct while typing (opt-in), the Windows side of the macOS auto mode.
// The keyboard hook feeds every typed character here; at a word boundary the
// engine decides whether the word was typed in the wrong layout, and the fix is
// backspaced in and retyped. Nothing is read from the screen or the clipboard —
// only what the user typed in front of us, which is why a pasted or pre-existing
// word is never touched.
//
// The buffer lives in memory only and is never written to disk.
//
// All of this file's state belongs to the hook thread (WinHotkey.swift): the hooks
// run there, and the UI thread reaches the state only through `onHook`. UI
// Automation is called on the UI thread only; the spell checker on a thread of its
// own (relayout_spell.cpp), since COM calls out of a hook callback fail.

let WM_AUTOFIX = UINT(WM_APP) + 11
let WM_AUTOENTER = UINT(WM_APP) + 12

private var autoEnabled = false  // mirrors the preference; the hook reads it per key
private var autoEnterEnabled = true
private var autoSameScript = false
private var autoSpell = false
private var learned = LearnedWords()   // the user's verdicts, cached from the registry
private var edits = EditLearning<WinLayout>()
// Measured in the VM: a suggestion call takes 2-7 ms typically, 100+ ms at worst.
private let guessBudgetMs: UInt64 = 50
private var exceptions = AppExceptions(auto: [], hotkey: [])
private var passwordField = false
private var passwordPending = false   // not known for the focused control: nothing is corrected
private var passwordInFlight = false  // a check is on its way back from the UI thread
private var passwordAsk = 0           // bumped per question: only the latest one's answer counts
private var run = AutoRun()     // the typed-word state machine, shared with macOS (engine)
private var lastFocus: HWND?

// While a fix is in flight, typed keys are held and replayed afterwards (engine
// `KeyGate`) — otherwise they would land between our backspaces and our retype.
private typealias HeldKey = (vk: UINT, scan: WORD, shift: Bool)
private var gate = KeyGate<HeldKey>()
private var correcting: Bool { gate.isClosed }
private func seconds() -> Double { Double(GetTickCount64()) / 1000 }

private struct QueuedFix {
    let fix: AutoRun.Fix
    let boundary: Int32
    let shift: Bool          // Shift+Tab stays Shift+Tab when re-sent
    let target: WinLayout
    let src: WinLayout       // for undo
}
private var queued: QueuedFix?

// Esc, PgUp/PgDn, End/Home, arrows, Insert, Delete.
private let navigationVKs: Set<UINT> = Set([0x1B, 0x2D, 0x2E] + (0x21...0x28).map { UINT($0) })

private let vkBack = UINT(0x08), vkTab = UINT(0x09), vkReturn = UINT(0x0D), vkSpace = UINT(0x20)

/// Auto mode stays off in password fields and in the user's deny-list. Terminals
/// are in that list by default, not ruled out here: the run needs no text from the
/// window, so a user who removes one gets auto-correct there (the hotkey converts
/// only the typed word in consoles — a selection read would send Ctrl+C).
private func autoExcluded() -> Bool {
    if passwordField || passwordPending { return true }
    guard !exceptions.auto.isEmpty else { return false }
    return exceptions.autoOff(foregroundProcessName())
}

/// The retype hotkey does nothing in the foreground app.
func hotkeyExcluded() -> Bool {
    onHook { !exceptions.hotkey.isEmpty && exceptions.hotkeyOff(foregroundProcessName()) }
}

/// Both auto-correct and the hotkey are off in the foreground app: the hook reads
/// none of its keys. Asked on every key, hence the per-window cache below.
private func keysOffInForeground() -> Bool {
    guard !exceptions.hotkey.isEmpty else { return false }
    return exceptions.keysOff(foregroundProcessName())
}

private var foregroundHwnd: HWND?
private var foregroundExe = ""

/// Executable name of the foreground window's process, lowercased ("code.exe"); ""
/// for reLayout's own windows.
private func foregroundProcessName() -> String {
    let fg = GetForegroundWindow()
    if fg != foregroundHwnd {
        foregroundHwnd = fg
        foregroundExe = processImagePath(of: appWindow(fg)).map(exeName) ?? ""
    }
    return foregroundExe
}

// MARK: - trigram models (shipped next to the exe as trigram/<lang>.txt)

private var models: [String: TrigramModel?] = [:]

func trigram(_ lang: String) -> TrigramModel? {
    if let cached = onHook({ models[lang] }) { return cached }
    // Not inside the hook: the file is read on the UI thread; this word goes without.
    if onHookThread() { postToUI { _ = trigram(lang) }; return nil }
    let model = (try? String(contentsOfFile: "\(exeDirectory())\\trigram\\\(lang).txt", encoding: .utf8))
        .flatMap(TrigramModel.init(text:))
    onHook { models[lang] = model }
    return model
}

/// The character this key produces under the live keyboard state (Shift, AltGr,
/// CapsLock, and the layout of the focused app). Empty for keys that type nothing.
/// - Parameter shift: Shift as it was when the key was pressed; nil reads it live.
private func character(_ vk: UINT, _ scan: WORD, _ layout: WinLayout, shift: Bool? = nil) -> String {
    var state = [BYTE](repeating: 0, count: 256)
    GetKeyboardState(&state)
    // GetKeyboardState is the hook thread's own queue state, not the user's: Shift
    // showed up as released and "Ybrmt" buffered as "ybrmt". Overlay the live keys.
    for vk in [VK_SHIFT, VK_LSHIFT, VK_RSHIFT, VK_CONTROL, VK_LCONTROL, VK_RCONTROL, VK_MENU, VK_LMENU, VK_RMENU] {
        state[Int(vk)] = (Int(GetAsyncKeyState(vk)) & 0x8000) != 0 ? 0x80 : 0
    }
    if let shift {
        state[Int(VK_SHIFT)] = shift ? 0x80 : 0; state[Int(VK_LSHIFT)] = state[Int(VK_SHIFT)]; state[Int(VK_RSHIFT)] = 0
    }
    state[Int(VK_CAPITAL)] = BYTE(Int(GetKeyState(VK_CAPITAL)) & 1)
    var buf = [WCHAR](repeating: 0, count: 8)
    // 0x4 = do not disturb the live dead-key state.
    let n = ToUnicodeEx(vk, UINT(scan), state, &buf, 8, 0x4, layout.hkl)
    guard n > 0 else { return "" }
    return String(decoding: buf.prefix(Int(n)), as: UTF16.self)
}

// MARK: - run

/// Ends the run: the caret may have moved, so what we remember is no longer what
/// is on screen.
func resetAutoBuffer() {
    onHook { run.reset() }
}

/// What an undo or a retarget just put before the caret stays the hotkey's
/// target as a whole (engine `remember`).
func rememberSelection(_ s: String) {
    onHook { run.remember(s) }
}

/// The word typed before the caret and the spaces after it, for the hotkey with
/// nothing selected.
func typedWord() -> (text: String, spaces: Int) {
    onHook { run.hotkeyTarget }
}

/// Re-reads the preferences (at startup and whenever Settings changes them).
func reloadAutoMode() {
    let all = WinLayout.installedList()
    // Loaded here, on the calling thread, not lazily on the first word inside the hook.
    for lang in all.compactMap(\.languageCode) { _ = trigram(lang) }
    let enabled = loadAutoMode(), enter = loadAutoEnter(), same = loadAutoSameScript(), spell = loadAutoSpell()
    let words = LearnedWords(convert: loadLearned(), keep: Set(loadKept()), counts: loadLearnCounts(),
                             candidates: loadLearnCandidates())
    let exc = AppExceptions(auto: loadExcludedApps(), hotkey: loadHotkeyExcludedApps())
    onHook {
        autoEnabled = enabled; autoEnterEnabled = enter; autoSameScript = same; autoSpell = spell
        learned = words
        exceptions = exc
        run.reset()
    }
    // Opening a dictionary is slow: one language per queued step on the hook thread
    // (which waits for the spell thread), so keys are served in between.
    if spell {
        for lang in scriptLanguages(cyrillic: true, enabled: all) + scriptLanguages(cyrillic: false, enabled: all) {
            postToHook { warmSpellCheckers([lang]) }
        }
    }
}

/// Turns auto-correct on or off as the Settings checkbox does: saves it, re-reads
/// the preferences, syncs an open Settings window and the tray icon's dot.
func setAutoMode(_ on: Bool) {
    saveAutoMode(on)
    reloadAutoMode()
    refreshSettingsAuto()
    refreshTrayIcon()
}

/// The auto-correct on/off hotkey. Does nothing while auto-correct is unavailable
/// (layouts of one script), where the Settings checkbox is disabled too.
func toggleAutoMode() {
    guard WinLayout.crossScriptAvailable() else { dwatch("auto toggle: unavailable"); return }
    let on = !loadAutoMode()
    dwatch("auto toggle: \(on ? "on" : "off")")
    setAutoMode(on)
}

/// Auto-correct is on and can act — what the Settings checkbox shows checked.
func autoModeActive() -> Bool { onHook { autoEnabled } && WinLayout.crossScriptAvailable() }

/// True when the character is a letter on an installed Cyrillic layout while a
/// Latin one is active ("," is б), so ",skj" buffers as "было".
private func mapsToCyrillic(_ ch: Character, cur: WinLayout) -> Bool {
    guard !cur.isCyrillic else { return false }
    return WinLayout.installedList().contains {
        $0.isCyrillic && mapsToWordChar(String(ch)[...], src: cur, dst: $0, connectors: true)
    }
}

/// Feeds one key press to the run.
/// - Parameters:
///   - shortcut: Ctrl or Alt alone, or Win, is held — a command, not text. AltGr
///     (Ctrl+Alt together) types characters and is not a shortcut.
///   - shift: Shift is held, so a re-sent boundary keeps it.
/// - Returns: true when the key must not reach the app — it is either held while a
///   fix is in flight, or the boundary key that the fix will retype itself.
///   - typed: what the key types, when already worked out (a replayed held key).
///   - replayed: a held key fed after its fix: it is not held again.
func autoFeed(vk: UINT, scan: WORD, shortcut: Bool, shift: Bool, typed: String? = nil, replayed: Bool = false) -> Bool {
    if correcting, !replayed {
        if vk == vkBack, gate.backspace(wide: shortcut) { return true }
        if vk == vkBack, shortcut { run.backspace(wide: true); return false }   // the held keys are dropped
        guard let cur = WinLayout.current(),
              !character(vk, scan, cur).isEmpty || vk == vkSpace || vk == vkTab else { return false }
        switch gate.key((vk, scan, shift), at: seconds()) {
        case .pass: break
        case .hold: return true
        case .release(let keys):
            // The fix is stuck: it must not run late at a moved caret, and nothing
            // typed is lost — the held keys and this one go out as typed.
            queued = nil; enterJob = nil
            run.reset()
            for k in keys { sendKeyTap(Int32(k.vk), shift: k.shift) }
            return true
        }
    }
    if !correcting || replayed, keysOffInForeground() { run.reset(); return false }

    // A different window may hold other text.
    let focus = focusWindow()
    if focus != lastFocus {
        lastFocus = focus
        run.reset()
    }
    // Password check once per word, as it starts: a browser page is one window, so
    // moving from the login field to the password field changes no focus window.
    // UI Automation can block, so the UI thread asks and the answer comes back;
    // until it does, nothing is corrected (autoExcluded).
    // While the answer is pending the last one may be stale (another field): keys
    // are kept, in memory only, and the next key after a "yes" drops them.
    // Replayed keys are checked by finishFix itself: the UI thread, busy replaying,
    // could not answer a queued question until the replay ends.
    if run.word.isEmpty && run.trail.isEmpty, !replayed { checkPasswordField() }
    if passwordField, !passwordPending { run.reset(); return false }

    // A modifier alone types nothing. Alt pressed with Ctrl already down reads as a
    // shortcut, and Ctrl+Alt+R would end the very word the hotkey is about to convert.
    if isModifierVK(vk) { return false }

    // Anything that may delete or select text arms learning by revert.
    if vk == vkBack || shortcut || navigationVKs.contains(vk) {
        edits.edit()
    }
    // Backspace edits the word; Ctrl+Backspace removes a word — nothing left to track.
    if vk == vkBack {
        run.backspace(wide: shortcut)
        return false
    }
    if shortcut || navigationVKs.contains(vk) { run.reset(); return false }

    guard let cur = WinLayout.current() else { run.reset(); return false }
    let text: String
    switch vk {
    case vkReturn: text = "\r"
    case vkTab:    text = "\t"
    case vkSpace:  text = " "
    default:       text = typed ?? character(vk, scan, cur)
    }
    let event = run.feed(text, mapsToCyrillic: { mapsToCyrillic($0, cur: cur) })
    guard autoEnabled else { return false }   // the run still serves the hotkey
    switch event {
    case .none:
        return false
    case .enter(let word, let trail):
        // Return submits: never correct before it lands (a launcher query, a
        // message). Only once the field shows a new line is the word fixed above it.
        return enterFollowUp(word: word, trail: trail, cur: cur, shift: shift)
    case .boundary(let word, let trail):
        return evaluate(word: word, trail: trail, boundary: Int32(vk), shift: shift, cur: cur)
    }
}

/// Asks the UI thread whether the focused control is a password field; the answer
/// lands in `passwordField`. One question at a time.
private func checkPasswordField() {
    passwordAsk &+= 1
    passwordPending = true
    guard !passwordInFlight else { return }   // the answer on its way asks again when it lands
    askPasswordField()
}

private func askPasswordField() {
    let ask = passwordAsk
    passwordInFlight = postToUI {
        let password = focusIsPasswordField()
        onHook {
            passwordInFlight = false
            // Asked for an earlier word, maybe in another field: ask again for this one.
            if ask == passwordAsk { passwordField = password; passwordPending = false } else { askPasswordField() }
        }
    }
}

/// Word boundary: the engine's `evaluateBoundary`, then the fix is queued for the
/// UI thread.
/// - Returns: true when a fix was queued, so the boundary key is swallowed — the
///   fix retypes it after the correction.
private var chainTarget: WinLayout?   // layout of the last auto candidate, for bridged words

private func evaluate(word: String, trail: String, boundary: Int32, shift: Bool, cur: WinLayout) -> Bool {
    let before = learned
    let (action, lessons) = evaluateBoundary(
        word: word, trail: trail, cur: cur, enabled: WinLayout.installedList(),
        run: &run, edits: &edits, learned: &learned, chainTarget: &chainTarget,
        excluded: { autoExcluded() },
        decide: { w, verdict in autoDecide(w, cur: cur, enabled: WinLayout.installedList(), verdict: verdict) })
    if learned != before { saveLearnedWords() }
    if !lessons.isEmpty { dwatch("learned by edit: \(lessons.count)") }
    switch action {
    case .none:
        return false
    case .switchLayout(let target):
        switchLayout(to: target)
        return false
    case .fix(let fix, let target):
        queued = QueuedFix(fix: fix, boundary: boundary, shift: shift, target: target, src: cur)
        gate.close(at: seconds())
        PostMessageW(trayWindow(), WM_AUTOFIX, 0, 0)
        return true
    }
}

/// The engine's `autoDecision` with this app's models, verdicts and dictionary.
/// - Parameter verdict: the user's verdicts; the stored ones when nil.
private func autoDecide(_ w: String, cur: WinLayout, enabled: [WinLayout], verdict: ((String) -> LearnedVerdict?)? = nil)
    -> (target: WinLayout, out: String, ambiguous: Bool, repaired: Bool)? {
    // Suggestions run inside the keyboard hook, which Windows drops when it runs
    // long: past the budget the remaining languages are skipped.
    let deadline = GetTickCount64() + guessBudgetMs
    let r = autoDecision(w, cur: cur, enabled: enabled, model: trigram, learned: verdict ?? learnedVerdict,
                         sameScript: autoSameScript, spell: autoSpell ? (isWord, { word, lang in
        GetTickCount64() < deadline ? spellGuesses(word, lang) : nil
    }) : nil)
    if let r, r.repaired { dwatch("typo: repaired len=\(r.out.count)") }
    return r
}

// MARK: - learned words (the user's verdicts; rules in the engine's LearnedWords)

func learnedVerdict(_ key: String) -> LearnedVerdict? { onHook { learned.verdict(key) } }

func learnedCount() -> Int { onHook { learned.convert.count + learned.keep.count } }

/// Learns, as `.convert`, the words of a hotkey conversion that auto-correct would
/// have left alone. Only with auto-correct on, never in a password field or an
/// excluded app: nothing typed there is persisted.
/// - Returns: the learned keys, so the press-again undo can forget them.
func learnHotkeyMisses(replaced: String, out: String, src: WinLayout, dst: WinLayout) -> [String] {
    guard !focusIsPasswordField() else { return [] }   // UI Automation: on the calling (UI) thread
    return onHook {
        guard autoEnabled, !autoExcluded() else { return [] }
        let misses = hotkeyMisses(replaced: replaced, out: out, src: src, dst: dst,
                                  enabled: WinLayout.installedList(), model: trigram)
        guard !misses.isEmpty else { return [] }
        learned.count(misses: misses, replaced: replaced, out: out)
        saveLearnedWords()
        return misses
    }
}

/// Undo takes back what the conversion taught (engine `LearnedWords.unlearn`).
func unlearn(_ last: WinConversion) {
    onHook {
        guard autoEnabled, !(last.learned.isEmpty && last.autoWords.isEmpty) else { return }
        learned.unlearn(learned: last.learned, autoWords: last.autoWords)
        saveLearnedWords()
    }
}

func learnedWords() -> (convert: [String: String], keep: Set<String>, candidates: [String: String]) {
    onHook { (learned.convert, learned.keep, learned.candidates) }
}

/// Makes `key` a verdict (a checked candidate, a word added by hand): `.convert`
/// to `out`, or `.keep` when `out` is empty (a keep candidate's conversion).
func promoteLearned(_ key: String, to out: String) { changeLearned { $0.promote(key, to: out) } }

/// Turns a verdict back into a candidate counted once.
func demoteLearned(_ key: String) { changeLearned { $0.demote(key) } }

/// Drops the candidates and their counts; no verdict is touched.
func cleanLearnCandidates() { changeLearned { $0.cleanCandidates() } }

/// Forgets `keys` from every store, or everything learned when nil.
func forgetLearned(_ keys: Set<String>? = nil) { changeLearned { $0.forget(keys) } }

private func changeLearned(_ change: @escaping (inout LearnedWords) -> Void) {
    onHook { change(&learned); saveLearnedWords() }
}

private func saveLearnedWords() {
    saveLearned(learned.convert)
    saveKept(learned.keep.sorted())
    saveLearnCounts(learned.counts)
    saveLearnCandidates(learned.candidates)
    postToUI { refreshSettingsLearned() }   // its windows belong to the UI thread
}

// MARK: - Enter follow-up

private struct EnterJob {
    let word: String        // word + trail, as typed
    let text: String        // its conversion
    let target: WinLayout
    let src: WinLayout      // for undo
    let shift: Bool         // Shift+Return stays Shift+Return when re-sent
}
private var enterJob: EnterJob?

/// If the word looks wrong, Return is held back for the UI thread: it reads the
/// field (UI Automation, which must not run in the hook), re-sends Return, and sees
/// where it took the field — a new line means the word is still there to fix, a
/// submitted field means it is gone.
/// - Returns: true when Return was held back.
private func enterFollowUp(word: String, trail: String, cur: WinLayout, shift: Bool) -> Bool {
    guard autoEnterEnabled, !correcting, wordBody(word) >= 3, !autoExcluded(), !foregroundIsConsole(),
          let decided = autoDecide(word, cur: cur, enabled: WinLayout.installedList()), !decided.ambiguous
    else { return false }
    let outTrail = trail.isEmpty ? "" : transliterate(trail, from: cur, to: decided.target)
    enterJob = EnterJob(word: word + trail, text: decided.out + outTrail, target: decided.target, src: cur,
                        shift: shift)
    gate.close(at: seconds())
    PostMessageW(trayWindow(), WM_AUTOENTER, 0, 0)
    return true
}

/// Fixes the word above the new line once the field has settled.
func runAutoEnter() {
    defer { finishFix() }
    guard let job = onHook({ () -> EnterJob? in defer { enterJob = nil }; return enterJob }) else { return }
    let mark = conversionMark()
    let before = readFieldSnapshot()
    sendKeyTap(Int32(vkReturn), shift: job.shift)   // the held-back Return, now that the field is read
    guard let before, before.tail.hasSuffix(job.word) else { return }
    dwatch("enter fix")
    guard let after = awaitSettledField(before: before, read: readFieldSnapshot,
                                        wait: { pumpWait(DWORD($0)) }),
          enterOutcome(before: before, after: after, word: job.word) == .newline else { return }
    sendBackspaces(job.word.count + 1)   // the word and the line break
    guard typeText(job.text, in: job.target) else { return }   // also leaves target active
    sendKeyTap(Int32(vkReturn))
    recordConversion(original: job.word + "\r", typed: job.text + "\r", src: job.src, since: mark,
                     autoWords: [learnedKey(job.word)])
}

// MARK: - the fix (runs on the UI thread, off the hook)

func runAutoFix() {
    guard let job = onHook({ () -> QueuedFix? in defer { queued = nil }; return queued }) else { return finishFix() }
    defer { finishFix(afterTab: job.boundary == Int32(vkTab)) }
    let mark = conversionMark()
    dwatch("auto fix erase=\(job.fix.erase) len=\(job.fix.text.count)")
    sendBackspaces(job.fix.erase)
    guard typeText(job.fix.text, in: job.target) else { return }   // also leaves target active
    sendKeyTap(job.boundary, shift: job.shift)
    let boundary = job.boundary == Int32(vkTab) ? "\t" : " "
    recordConversion(original: job.fix.original + boundary, typed: job.fix.text + boundary, src: job.src, since: mark,
                     autoWords: job.fix.original.split(separator: " ").map { learnedKey(String($0)) })
}

/// Replays what was typed during the fix, feeding each key through the run first
/// so a word typed across the correction is still judged as one word. The gate
/// stays shut until the queue is empty, so keys typed during the replay queue up
/// behind it instead of overtaking it.
/// - Parameter afterTab: the fix ended by re-sending Tab, so focus may have moved.
private func finishFix(afterTab: Bool = false) {
    // Keys typed during the fix land after it: the caret has moved past the fix.
    // They may have gone to another field (the fix ended on Tab): ask now, on this
    // thread, before any of them is fed.
    if onHook({ () -> Bool in if !gate.held.isEmpty { forgetConversion() }; return !gate.held.isEmpty }) {
        if afterTab {
            // A read right after the Tab could still see the old field: unknown until
            // the next typed word asks.
            onHook { passwordAsk &+= 1; passwordPending = true }
        } else {
            let password = focusIsPasswordField()
            onHook { passwordAsk &+= 1; passwordField = password; passwordPending = false }
        }
    }
    while let key = onHook({ () -> HeldKey? in
        // A fix queued meanwhile (a replayed key started one, or the watchdog let
        // a new word through) replays what is held after it runs.
        guard queued == nil, enterJob == nil else { return nil }
        guard let key = gate.nextToReplay(at: seconds()) else { gate.open(); return nil }
        return key
    }) {
        if key.vk == vkReturn {
            // No Enter follow-up here: its "before" read would race this very key.
            resetAutoBuffer()
            sendKeyTap(Int32(vkReturn), shift: key.shift)
            continue
        }
        // Read in the layout the fix left active, once: the run is fed and the
        // screen typed the same text (the fix may have switched layout under the keys).
        let cur = WinLayout.current()
        let text = cur.map { character(key.vk, key.scan, $0, shift: key.shift) } ?? ""
        if onHook({ autoFeed(vk: key.vk, scan: key.scan, shortcut: false, shift: key.shift, typed: text, replayed: true) }) {
            return   // that key started another fix; the rest stays held for it to replay
        }
        if text.isEmpty || key.vk == vkSpace || key.vk == vkTab || key.vk == vkBack {
            sendKeyTap(Int32(key.vk), shift: key.shift)   // apps act on these keys, not on their text
            // Focus may move with a Tab, and a read right after it could still see the
            // old field: unknown until the next typed word asks again.
            if key.vk == vkTab { onHook { passwordAsk &+= 1; passwordPending = true } }
        } else if let cur {
            _ = typeText(text, in: cur)
        }
    }
}

// MARK: - mouse

private var mouseHook: HHOOK?

/// A click moves the caret, so the buffer no longer describes what is on screen.
private let mouseProc: HOOKPROC = { nCode, wParam, lParam in
    if nCode == 0, wParam == WPARAM(WM_LBUTTONDOWN) || wParam == WPARAM(WM_RBUTTONDOWN)
        || wParam == WPARAM(WM_MBUTTONDOWN) {
        resetAutoBuffer()
        forgetConversion()
        edits.edit()
        interruptHotkeyTaps()
    }
    return CallNextHookEx(nil, nCode, wParam, lParam)
}

func installAutoMouseHook() {
    mouseHook = SetWindowsHookExW(14 /* WH_MOUSE_LL */, mouseProc, GetModuleHandleW(nil), 0)
}

func uninstallAutoMouseHook() {
    if let hook = mouseHook { UnhookWindowsHookEx(hook); mouseHook = nil }
}

/// Whether "Between similar layouts" can fire with the installed layouts.
func similarAvailable() -> Bool { onHook { hasSimilarLayouts(WinLayout.installedList(), model: trigram) } }

/// Whether the spell-check option can act: a system dictionary for an installed
/// layout's language.
func spellAvailable() -> Bool { onHook { hasSpellDictionary(WinLayout.installedList()) } }
