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

let WM_AUTOFIX = UINT(WM_APP) + 11
let WM_AUTOENTER = UINT(WM_APP) + 12

private var autoEnabled = false  // mirrors the preference; the hook reads it per key
private var autoEnterEnabled = true
private var excludedApps: [String] = []
private var passwordField = false
private var run = AutoRun()     // the typed-word state machine, shared with macOS (engine)
private var lastFocus: HWND?

// While a fix is in flight, typed keys are swallowed and replayed afterwards —
// otherwise they would land between our backspaces and our retype.
private var correcting = false
private var gateSince: DWORD = 0
private let gateMaxHoldMs: DWORD = 3000
private var held: [(vk: UINT, text: String, shift: Bool)] = []

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

/// Auto mode stays off in terminals and in the user's deny-list: what is typed
/// there is commands and code, not prose.
private func autoExcluded() -> Bool {
    if foregroundIsConsole() || passwordField { return true }
    guard !excludedApps.isEmpty else { return false }
    return excludedApps.contains(foregroundProcessName())
}

/// Executable name of the foreground window's process, lowercased ("code.exe").
private func foregroundProcessName() -> String {
    var pid: DWORD = 0
    GetWindowThreadProcessId(GetForegroundWindow(), &pid)
    guard pid != 0,
          let handle = OpenProcess(DWORD(0x1000 /* PROCESS_QUERY_LIMITED_INFORMATION */), false, pid)
    else { return "" }
    defer { CloseHandle(handle) }
    var buf = [WCHAR](repeating: 0, count: 1024)
    var size = DWORD(buf.count)
    guard QueryFullProcessImageNameW(handle, 0, &buf, &size) else { return "" }
    let path = String(decoding: buf.prefix(Int(size)), as: UTF16.self)
    return (path.split(separator: "\\").last.map(String.init) ?? path).lowercased()
}

// MARK: - trigram models (shipped next to the exe as trigram/<lang>.txt)

private var models: [String: TrigramModel?] = [:]

func trigram(_ lang: String) -> TrigramModel? {
    if let cached = models[lang] { return cached }
    let model = (try? String(contentsOfFile: "\(exeDirectory())\\trigram\\\(lang).txt", encoding: .utf8))
        .flatMap(TrigramModel.init(text:))
    models[lang] = model
    return model
}

/// The character this key produces under the live keyboard state (Shift, AltGr,
/// CapsLock, and the layout of the focused app). Empty for keys that type nothing.
private func character(_ vk: UINT, _ scan: WORD, _ layout: WinLayout) -> String {
    var state = [BYTE](repeating: 0, count: 256)
    GetKeyboardState(&state)
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
    run.reset()
}

/// Re-reads the preferences (at startup and whenever Settings changes them).
func reloadAutoMode() {
    autoEnabled = loadAutoMode()
    autoEnterEnabled = loadAutoEnter()
    excludedApps = loadExcludedApps()
    run.reset()
}

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
func autoFeed(vk: UINT, scan: WORD, shortcut: Bool, shift: Bool) -> Bool {
    guard autoEnabled else { return false }

    if correcting {
        if GetTickCount() &- gateSince > gateMaxHoldMs {   // watchdog: never freeze the keyboard
            correcting = false
            held = []
        } else if vk == vkBack, !shortcut, !held.isEmpty {
            held.removeLast()   // un-type a held key instead of reaching the app out of order
            return true
        } else if let cur = WinLayout.current() {
            let text = character(vk, scan, cur)
            guard !text.isEmpty || vk == vkSpace || vk == vkTab else { return false }
            held.append((vk, text, shift))
            return true
        }
    }

    // A different field may hold other text. The password check rides along, so it
    // costs one UI Automation call per field, not per key.
    let focus = focusWindow()
    if focus != lastFocus {
        lastFocus = focus
        run.reset()
        passwordField = focusIsPasswordField()
    }
    if passwordField { return false }   // never buffer a password

    // Backspace edits the word; Ctrl+Backspace removes a word — nothing left to track.
    if vk == vkBack {
        if shortcut { held = [] }
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
    default:       text = character(vk, scan, cur)
    }
    switch run.feed(text, mapsToCyrillic: { mapsToCyrillic($0, cur: cur) }) {
    case .none:
        return false
    case .enter(let word, let trail):
        // Return submits: never correct before it lands (a launcher query, a
        // message). Only once the field shows a new line is the word fixed above it.
        enterFollowUp(word: word, trail: trail, cur: cur)
        return false
    case .boundary(let word, let trail):
        return evaluate(word: word, trail: trail, boundary: Int32(vk), shift: shift, cur: cur)
    }
}

/// Word boundary: decide, and queue the fix for the UI thread.
/// - Returns: true when a fix was queued, so the boundary key is swallowed — the
///   fix retypes it after the correction.
private func evaluate(word: String, trail: String, boundary: Int32, shift: Bool, cur: WinLayout) -> Bool {
    guard !word.isEmpty, !autoExcluded(),
          let decided = decideAutoTarget(word, cur: cur, enabled: WinLayout.installedList(), model: trigram)
    else { run.noCandidate(); return false }
    let outTrail = trail.isEmpty ? "" : transliterate(trail, from: cur, to: decided.target)
    // The short-word rule (engine): a 1-2 letter word waits for a neighbour.
    guard let fix = run.plan(raw: word + trail, out: decided.out + outTrail,
                             cyrillic: decided.target.isCyrillic) else { return false }
    queued = QueuedFix(fix: fix, boundary: boundary, shift: shift, target: decided.target, src: cur)
    correcting = true
    gateSince = GetTickCount()
    PostMessageW(trayWindow(), WM_AUTOFIX, 0, 0)
    return true
}

// MARK: - Enter follow-up

private struct EnterJob {
    let before: FieldSnapshot
    let word: String        // word + trail, as typed
    let text: String        // its conversion
    let target: WinLayout
    let src: WinLayout      // for undo
}
private var enterJob: EnterJob?

/// Return is never swallowed. If the word looks wrong, snapshot the field now and
/// let the UI thread see where Return took it: a new line means the word is still
/// there to fix, a submitted field means it is gone.
private func enterFollowUp(word: String, trail: String, cur: WinLayout) {
    guard autoEnterEnabled, !correcting, wordBody(word) >= 3, !autoExcluded(),
          let decided = decideAutoTarget(word, cur: cur, enabled: WinLayout.installedList(), model: trigram),
          let before = readFieldSnapshot(), before.tail.hasSuffix(word + trail)
    else { return }
    let outTrail = trail.isEmpty ? "" : transliterate(trail, from: cur, to: decided.target)
    enterJob = EnterJob(before: before, word: word + trail,
                        text: decided.out + outTrail, target: decided.target, src: cur)
    correcting = true
    gateSince = GetTickCount()
    PostMessageW(trayWindow(), WM_AUTOENTER, 0, 0)
}

/// Fixes the word above the new line once the field has settled.
func runAutoEnter() {
    defer { finishFix() }
    guard let job = enterJob else { return }
    enterJob = nil
    dwatch("enter fix")
    guard let after = awaitSettledField(before: job.before, read: readFieldSnapshot,
                                        wait: { pumpWait(DWORD($0)) }),
          enterOutcome(before: job.before, after: after, word: job.word) == .newline else { return }
    sendBackspaces(job.word.count + 1)   // the word and the line break
    guard typeText(job.text, in: job.target) else { return }   // also leaves target active
    sendKeyTap(Int32(vkReturn))
    recordConversion(original: job.word + "\r", typed: job.text + "\r", src: job.src)
}

// MARK: - the fix (runs on the UI thread, off the hook)

func runAutoFix() {
    defer { finishFix() }
    guard let job = queued else { return }
    queued = nil
    dwatch("auto fix erase=\(job.fix.erase) len=\(job.fix.text.count)")
    sendBackspaces(job.fix.erase)
    guard typeText(job.fix.text, in: job.target) else { return }   // also leaves target active
    sendKeyTap(job.boundary, shift: job.shift)
    let boundary = job.boundary == Int32(vkTab) ? "\t" : " "
    recordConversion(original: job.fix.original + boundary, typed: job.fix.text + boundary, src: job.src)
}

/// Replays what was typed during the fix, feeding each key through the run first
/// so a word typed across the correction is still judged as one word.
private func finishFix() {
    correcting = false
    let replay = held
    held = []
    // Keys typed during the fix land after it: the caret has moved past the fix.
    if !replay.isEmpty { forgetConversion() }
    for (i, key) in replay.enumerated() {
        if key.vk == vkReturn {
            // No Enter follow-up here: its "before" read would race this very key.
            run.reset()
            sendKeyTap(Int32(vkReturn), shift: key.shift)
            continue
        }
        let scan = WORD(truncatingIfNeeded: MapVirtualKeyW(key.vk, 0 /* MAPVK_VK_TO_VSC */))
        if autoFeed(vk: key.vk, scan: scan, shortcut: false, shift: key.shift) {
            held = Array(replay[(i + 1)...])   // that key started another fix; it replays the rest
            return
        }
        if key.text.isEmpty || key.vk == vkSpace || key.vk == vkTab {
            sendKeyTap(Int32(key.vk), shift: key.shift)   // apps act on these keys, not on their text
        } else {
            if let cur = WinLayout.current() { _ = typeText(key.text, in: cur) } else { _ = sendUnicode(key.text) }
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
    }
    return CallNextHookEx(nil, nCode, wParam, lParam)
}

func installAutoMouseHook() {
    mouseHook = SetWindowsHookExW(14 /* WH_MOUSE_LL */, mouseProc, GetModuleHandleW(nil), 0)
}

func uninstallAutoMouseHook() {
    if let hook = mouseHook { UnhookWindowsHookEx(hook); mouseHook = nil }
}
