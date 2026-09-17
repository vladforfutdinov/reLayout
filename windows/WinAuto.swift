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

private var autoEnabled = false  // mirrors the preference; the hook reads it per key
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

private let vkBack = UINT(0x08), vkTab = UINT(0x09), vkReturn = UINT(0x0D), vkSpace = UINT(0x20)

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

func resetAutoBuffer() {
    buffer = ""
    trail = ""
}

/// Re-reads the preference (at startup and whenever Settings changes it).
func reloadAutoMode() {
    autoEnabled = loadAutoMode()
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

    // A click, a different window or any Ctrl/Alt/Win shortcut may have moved the
    // caret: what we remember is no longer what is on screen.
    let focus = GetForegroundWindow()
    if focus != lastFocus { lastFocus = focus; resetAutoBuffer() }
    if modifiers { resetAutoBuffer(); return false }

    switch vk {
    case vkBack:
        if !trail.isEmpty { trail.removeLast() } else if !buffer.isEmpty { buffer.removeLast() }
        return false
    case vkReturn:
        // Return submits: never correct before it lands (a launcher query, a message).
        resetAutoBuffer()
        return false
    case vkSpace, vkTab:
        return evaluate(boundary: Int32(vk))
    default:
        break
    }

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
    resetAutoBuffer()
    // Short words need the neighbour rule the macOS app applies (a preposition is
    // only fixed next to a real conversion); until that is ported, leave them.
    guard word.count >= 3, !foregroundIsConsole(), let cur = WinLayout.current() else { return false }
    let enabled = WinLayout.installedList()
    guard let decided = decideAutoTarget(word, cur: cur, enabled: enabled, model: trigram) else { return false }

    let outTrail = punct.isEmpty ? "" : transliterate(punct, from: cur, to: decided.target)
    queued = Fix(erase: word.utf16.count + punct.utf16.count,
                 text: decided.out + outTrail,
                 boundary: boundary,
                 target: decided.target)
    correcting = true
    gateSince = GetTickCount()
    PostMessageW(trayWindow(), WM_AUTOFIX, 0, 0)
    return true
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
