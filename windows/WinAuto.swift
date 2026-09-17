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
private var buffer = ""          // the word as typed
private var trail = ""           // punctuation typed right after it
private var lastFocus: HWND?

// While a fix is in flight, typed keys are swallowed and replayed afterwards —
// otherwise they would land between our backspaces and our retype.
private var correcting = false
private var gateSince: DWORD = 0
private let gateMaxHoldMs: DWORD = 3000
private var held: [(vk: UINT, text: String)] = []

private struct Fix {
    let erase: Int
    let text: String
    let boundary: Int32
    let target: WinLayout
}
private var queued: Fix?

/// The word before this one, for the short-word rule: a 1-2 char word (a
/// preposition: "d" -> в) scores fine but is not trusted alone, so it is only
/// fixed next to a real conversion of the same script.
private struct Prev {
    let raw: String        // as typed, still on screen
    let out: String        // its conversion
    let cyrillic: Bool     // script of the target
    let committed: Bool    // true: already retyped; false: pending candidate
}
private var prev: Prev?

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

private func trigram(_ lang: String) -> TrigramModel? {
    if let cached = models[lang] { return cached }
    let model = (try? String(contentsOfFile: "\(exeDirectory())\\trigram\\\(lang).txt", encoding: .utf8))
        .flatMap(TrigramModel.init(text:))
    models[lang] = model
    return model
}

// MARK: - buffer

/// Ends the run: the previous word can no longer be folded into a correction.
func resetAutoBuffer() {
    buffer = ""
    trail = ""
    prev = nil
}

/// Re-reads the preference (at startup and whenever Settings changes it).
func reloadAutoMode() {
    autoEnabled = loadAutoMode()
    autoEnterEnabled = loadAutoEnter()
    excludedApps = loadExcludedApps()
    resetAutoBuffer()
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

/// Word material: a letter, a connector (hyphen, apostrophe), or a character that
/// is a letter on an installed layout of the other script — "," is б on ЙЦУКЕН,
/// so ",skj" is a word, not punctuation.
private func isWordMaterial(_ ch: Character, cur: WinLayout) -> Bool {
    if ch.isLetter || isWordConnector(ch) { return true }
    guard !cur.isCyrillic else { return false }
    return WinLayout.installedList().contains { $0.isCyrillic && mapsToWordChar(String(ch)[...], src: cur, dst: $0, connectors: true) }
}

/// Feeds one key press to the word buffer.
/// - Returns: true when the key must not reach the app — it is either held while a
///   fix is in flight, or it is the boundary key that the fix will retype itself.
func autoFeed(vk: UINT, scan: WORD, modifiers: Bool) -> Bool {
    guard autoEnabled else { return false }

    if correcting {
        if GetTickCount() &- gateSince > gateMaxHoldMs {   // watchdog: never freeze the keyboard
            correcting = false
            held = []
        } else if let cur = WinLayout.current() {
            let text = character(vk, scan, cur)
            guard !text.isEmpty || vk == vkSpace || vk == vkTab else { return false }
            held.append((vk, text))
            return true
        }
    }

    // A click, a different field or any Ctrl/Alt/Win shortcut may have moved the
    // caret: what we remember is no longer what is on screen. The password check
    // rides along, so it costs one UI Automation call per field, not per key.
    let focus = focusWindow()
    if focus != lastFocus {
        lastFocus = focus
        resetAutoBuffer()
        passwordField = focusIsPasswordField()
    }
    if passwordField { return false }   // never buffer a password
    if modifiers { resetAutoBuffer(); return false }

    switch vk {
    case vkBack:
        if !trail.isEmpty { trail.removeLast() }
        else if !buffer.isEmpty { buffer.removeLast() }
        else { prev = nil }
        return false
    case vkReturn:
        // Return submits: never correct before it lands (a launcher query, a
        // message). Only once the field shows a new line is the word fixed above it.
        enterFollowUp()
        resetAutoBuffer()
        return false
    case vkSpace, vkTab:
        return evaluate(boundary: Int32(vk))
    default:
        break
    }

    // Navigation and editing keys move the caret, so the buffer stops describing
    // what is on screen. (Dead keys and Globe/fn produce no character either, but
    // they type — they must not end the run, so only these are listed.)
    if navigationVKs.contains(vk) { resetAutoBuffer(); return false }

    guard let cur = WinLayout.current() else { resetAutoBuffer(); return false }
    let text = character(vk, scan, cur)
    guard !text.isEmpty else { return false }   // Globe/fn, dead key, F-key: not a reset
    for ch in text {
        if isWordMaterial(ch, cur: cur) {
            if !trail.isEmpty { resetAutoBuffer() }   // "a?b" starts a new word
            buffer.append(ch)
            if buffer.count > 64 { buffer.removeFirst() }
        } else if !buffer.isEmpty {
            trail.append(ch)
        } else {
            resetAutoBuffer()
        }
    }
    return false
}

/// Word boundary: decide, and queue the fix for the UI thread.
/// - Returns: true when a fix was queued, so the boundary key is swallowed — the
///   fix retypes it after the correction.
private func evaluate(boundary: Int32) -> Bool {
    let word = buffer, punct = trail
    buffer = ""; trail = ""
    guard !word.isEmpty, !autoExcluded(), let cur = WinLayout.current() else { prev = nil; return false }
    let enabled = WinLayout.installedList()
    guard let decided = decideAutoTarget(word, cur: cur, enabled: enabled, model: trigram) else { prev = nil; return false }

    let outTrail = punct.isEmpty ? "" : transliterate(punct, from: cur, to: decided.target)
    let cyrillic = decided.target.isCyrillic
    // A trailing mapped char is the weakest evidence ("vs." reads as "мію"), so the
    // length that decides trust is measured without it.
    let body = word.reversed().drop(while: { !$0.isLetter }).count

    if body >= 3 {
        // Long enough to trust alone. A pending short word right before it (the
        // "d ljhjut" case) is folded into the same correction.
        let swallow = prev.flatMap { !$0.committed && $0.cyrillic == cyrillic ? $0 : nil }
        prev = Prev(raw: word + punct, out: decided.out + outTrail, cyrillic: cyrillic, committed: true)
        queue(word: word, punct: punct, out: decided.out + outTrail,
              swallow: swallow, boundary: boundary, target: decided.target)
        return true
    }
    if let p = prev, p.committed, p.cyrillic == cyrillic {
        // Short word right after a committed conversion of the same script.
        prev = Prev(raw: word + punct, out: decided.out + outTrail, cyrillic: cyrillic, committed: true)
        queue(word: word, punct: punct, out: decided.out + outTrail,
              swallow: nil, boundary: boundary, target: decided.target)
        return true
    }
    // ponytail: one-neighbour lookback, like macOS — a stack ("bp pf ghbdtn") fixes
    // only the last preposition. Widen to a pending list if that ever matters.
    prev = Prev(raw: word + punct, out: decided.out + outTrail, cyrillic: cyrillic, committed: false)
    return false
}

private func queue(word: String, punct: String, out: String,
                   swallow: Prev?, boundary: Int32, target: WinLayout) {
    let extra = swallow.map { $0.raw.utf16.count + 1 } ?? 0   // "<raw> " before the word
    queued = Fix(erase: word.utf16.count + punct.utf16.count + extra,
                 text: (swallow.map { $0.out + " " } ?? "") + out,
                 boundary: boundary,
                 target: target)
    correcting = true
    gateSince = GetTickCount()
    PostMessageW(trayWindow(), WM_AUTOFIX, 0, 0)
}

// MARK: - Enter follow-up

private struct EnterJob {
    let before: FieldSnapshot
    let word: String        // word + trail, as typed
    let text: String        // its conversion
    let target: WinLayout
}
private var enterJob: EnterJob?

/// Return is never swallowed. If the word looks wrong, snapshot the field now and
/// let the UI thread see where Return took it: a new line means the word is still
/// there to fix, a submitted field means it is gone.
private func enterFollowUp() {
    let word = buffer, punct = trail
    guard autoEnterEnabled, !correcting,
          word.reversed().drop(while: { !$0.isLetter }).count >= 3,
          !autoExcluded(), let cur = WinLayout.current(),
          let decided = decideAutoTarget(word, cur: cur, enabled: WinLayout.installedList(), model: trigram),
          let before = readFieldSnapshot(), before.tail.hasSuffix(word + punct)
    else { return }

    let outTrail = punct.isEmpty ? "" : transliterate(punct, from: cur, to: decided.target)
    enterJob = EnterJob(before: before, word: word + punct,
                        text: decided.out + outTrail, target: decided.target)
    correcting = true
    gateSince = GetTickCount()
    PostMessageW(trayWindow(), WM_AUTOENTER, 0, 0)
}

/// Waits for the field to settle — the system may capitalize the word ~50 ms after
/// the line break appears, so one changed read is not enough — then fixes the word
/// above the new line.
func runAutoEnter() {
    defer { finishFix() }
    guard let job = enterJob else { return }
    enterJob = nil

    var last: FieldSnapshot?, stable = 0, settled: FieldSnapshot?
    for _ in 0..<20 {
        pumpWait(25)
        let snap = readFieldSnapshot()
        stable = (snap != nil && snap == last) ? stable + 1 : 0
        last = snap
        if stable >= 3, let snap, snap != job.before { settled = snap; break }
    }
    guard let after = settled,
          enterOutcome(before: job.before, after: after, word: job.word) == .newline else { return }

    sendBackspaces(job.word.utf16.count + 1)   // the word and the line break
    guard sendUnicode(job.text) else { return }
    sendKeyTap(Int32(vkReturn))
    switchLayout(to: job.target)
}

// MARK: - the fix (runs on the UI thread, off the hook)

func runAutoFix() {
    defer { finishFix() }
    guard let fix = queued else { return }
    queued = nil
    sendBackspaces(fix.erase)
    guard sendUnicode(fix.text) else { return }
    sendKeyTap(fix.boundary)
    switchLayout(to: fix.target)
}

/// Replays what was typed during the fix, feeding each key through the buffer
/// first so a word typed across the correction is still judged as one word.
private func finishFix() {
    correcting = false
    let replay = held
    held = []
    for (i, key) in replay.enumerated() {
        let scan = WORD(truncatingIfNeeded: MapVirtualKeyW(key.vk, 0 /* MAPVK_VK_TO_VSC */))
        if autoFeed(vk: key.vk, scan: scan, modifiers: false) {
            held = Array(replay[(i + 1)...])   // that key started another fix; it replays the rest
            return
        }
        if key.text.isEmpty || key.vk == vkSpace || key.vk == vkTab || key.vk == vkReturn {
            sendKeyTap(Int32(key.vk))          // apps act on these keys, not on their text
        } else {
            _ = sendUnicode(key.text)
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
    }
    return CallNextHookEx(nil, nCode, wParam, lParam)
}

func installAutoMouseHook() {
    mouseHook = SetWindowsHookExW(14 /* WH_MOUSE_LL */, mouseProc, GetModuleHandleW(nil), 0)
}

func uninstallAutoMouseHook() {
    if let hook = mouseHook { UnhookWindowsHookEx(hook); mouseHook = nil }
}
