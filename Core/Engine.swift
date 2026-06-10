// reLayout conversion engine — platform-free.
//
// No AppKit / Carbon / WinSDK here: only Swift stdlib. Shared verbatim by the
// macOS app (compiled together by build.sh) and the Windows port (imported as the
// ReLayoutCore SwiftPM module). Each platform supplies its own LayoutMaps builder
// (UCKeyTranslate on macOS, ToUnicodeEx on Windows); this file is the conversion
// logic that runs on top of those maps.

// MARK: - Keystroke (physical key + modifier state)

public struct KeyStroke: Hashable {
    public let keyCode: UInt16
    public let mods: UInt32   // platform modifier-state encoding (carbon mods >> 8 on macOS)
    public init(keyCode: UInt16, mods: UInt32) {
        self.keyCode = keyCode
        self.mods = mods
    }
}

// Conversion-relevant surface of a keyboard layout. Lets the engine run over a
// live layout or injected fixtures (tests) without knowing how the maps are built.
//   strokeToChar : physical key+mods  -> produced character
//   charToStroke : produced character -> physical key+mods   (reverse)
public protocol LayoutMaps {
    var charToStroke: [String: KeyStroke] { get }
    var strokeToChar: [KeyStroke: String] { get }
    var isCyrillic: Bool { get }
}

// MARK: - Transliteration
//
// char --(source.charToStroke)--> stroke --(target.strokeToChar)--> char
// Layout-driven, so the Option/AltGr layer (ß/æ <-> ы/э) resolves automatically —
// no hand-coded character tables.

public func transliterate(_ text: String, from src: LayoutMaps, to dst: LayoutMaps) -> String {
    var out = ""
    for ch in text {
        let key = String(ch)
        if let stroke = src.charToStroke[key], let mapped = dst.strokeToChar[stroke] {
            out += mapped
        } else {
            out += key
        }
    }
    return out
}

// MARK: - Script detection

public func isCyrLetter(_ u: Unicode.Scalar) -> Bool {
    (0x0400...0x04FF).contains(u.value) || (0x0500...0x052F).contains(u.value)
}

public func hasCyr(_ w: Substring) -> Bool { w.unicodeScalars.contains(where: isCyrLetter) }

func isLatinLetter(_ u: Unicode.Scalar) -> Bool {
    let v = u.value
    if (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) { return true }
    // Latin-1 Supplement + Latin Extended-A/B letters (ä ö ü ß é …), minus × ÷
    if (0xC0...0x24F).contains(v) && v != 0xD7 && v != 0xF7 { return true }
    return false
}

public func hasLatin(_ w: Substring) -> Bool { w.unicodeScalars.contains(where: isLatinLetter) }

// A word is wrong-but-Cyrillic-target if any of its chars (which src can type) maps
// to a Cyrillic letter in dst. Catches the Option layer (ß/æ -> ы/э), neither a-z nor Cyrillic.
func mapsToCyr(_ w: Substring, src: LayoutMaps, dst: LayoutMaps) -> Bool {
    for ch in w {
        if let st = src.charToStroke[String(ch)], let m = dst.strokeToChar[st],
           let f = m.unicodeScalars.first, isCyrLetter(f) { return true }
    }
    return false
}

// MARK: - Tokenize + per-word conversion

// Tokenize into alternating whitespace / non-whitespace runs (order preserved).
public func tokenize(_ text: String) -> [Substring] {
    var tokens: [Substring] = []
    var i = text.startIndex
    while i < text.endIndex {
        let space = text[i].isWhitespace
        var j = i
        while j < text.endIndex, text[j].isWhitespace == space { j = text.index(after: j) }
        tokens.append(text[i..<j]); i = j
    }
    return tokens
}

// Majority script across the letter-bearing word tokens of `text`.
// true = Cyrillic dominates, false = Latin dominates, nil = no letters or a tie.
// Used to detect the "wrong" layout from the text itself when the system's
// current layout no longer matches what was typed (user switched after mistyping).
// Non-whitespace tokens (the "words") of `text`.
func wordTokens(_ text: String) -> [Substring] {
    tokenize(text).filter { !($0.first?.isWhitespace ?? true) }
}

public func dominantScript(_ text: String) -> Bool? {
    var cyr = 0, lat = 0
    for t in wordTokens(text) {
        if hasCyr(t) { cyr += 1 } else if hasLatin(t) { lat += 1 }
    }
    if cyr > lat { return true }
    if lat > cyr { return false }
    return nil
}

// True if `text` has at least one word token of the given script (Cyrillic if
// `cyrillic`, else Latin-without-Cyrillic).
public func textHasScript(_ text: String, cyrillic: Bool) -> Bool {
    for t in wordTokens(text) {
        if cyrillic ? hasCyr(t) : (hasLatin(t) && !hasCyr(t)) { return true }
    }
    return false
}

// MARK: - Implicit-selection window (caret-line grab)
//
// When the hotkey is pressed with nothing selected, the platform layer grabs the
// whole line from the caret back to its start. Unlike an explicit selection, that
// line routinely mixes correct text with the one wrong-layout tail the user just
// typed — so only the tail may be converted. Narrowing rules:
//
//   - The wrong script is anchored on the line's LAST letter (the user is thinking
//     about what they just typed); Cyrillic or Latin only. A line ending in neither
//     (CJK, digits, empty) gives nothing to anchor on.
//   - Walk backward over wrong-script letters and neutral chars (digits,
//     punctuation, whitespace); stop at the first letter of any other script.
//     No stop found -> the whole line is the window.
//   - The window starts right after the stop letter. If it then begins mid-word
//     (first char is a letter — the stop letter's word continues into the window,
//     e.g. a mixed token like "мирqwerty"), drop that word's remainder up to the
//     first non-letter.
//
// Returns the window start (window = text[start...]) plus the wrong script, or nil
// when there is no anchor or nothing convertible survives the trim.
public func lastWrongWindow(_ text: String) -> (start: String.Index, wrongIsCyrillic: Bool)? {
    func cyr(_ ch: Character) -> Bool { ch.unicodeScalars.contains(where: isCyrLetter) }
    func lat(_ ch: Character) -> Bool { ch.unicodeScalars.contains(where: isLatinLetter) }

    // Anchor: the last letter decides the wrong script — or disqualifies (CJK).
    var wrongCyr: Bool?
    var i = text.endIndex
    while i > text.startIndex {
        let ch = text[text.index(before: i)]
        if ch.isLetter {
            if cyr(ch) { wrongCyr = true } else if lat(ch) { wrongCyr = false }
            break
        }
        i = text.index(before: i)
    }
    guard let wrongCyr else { return nil }

    // Walk back to the first letter of another script.
    var stop: String.Index?
    i = text.endIndex
    while i > text.startIndex {
        let j = text.index(before: i)
        let ch = text[j]
        if ch.isLetter, wrongCyr ? !cyr(ch) : !lat(ch) { stop = j; break }
        i = j
    }
    guard let stop else { return (text.startIndex, wrongCyr) }

    // Mid-word landing: trim the stop word's remainder.
    var start = text.index(after: stop)
    while start < text.endIndex, text[start].isLetter { start = text.index(after: start) }

    guard text[start...].contains(where: { wrongCyr ? cyr($0) : lat($0) }) else { return nil }
    return (start, wrongCyr)
}

// Per-word conversion. The "wrong" words are those typed in `src` (the active/wrong
// layout) — identified by script — and only those are converted to `dst`.
//   src Cyrillic -> convert words containing Cyrillic
//   src Latin    -> convert words with Latin letters (or src->dst Cyrillic-mapping, e.g. ß/æ)
// Returns nil if nothing changed.
public func convertWrong(_ text: String, src: LayoutMaps, dst: LayoutMaps) -> String? {
    var acc = ""
    for t in tokenize(text) {
        if t.first?.isWhitespace ?? false { acc += t; continue }
        let wrong: Bool
        if src.isCyrillic {
            wrong = hasCyr(t)
        } else {
            wrong = !hasCyr(t) && (hasLatin(t) || mapsToCyr(t, src: src, dst: dst))
        }
        acc += wrong ? transliterate(String(t), from: src, to: dst) : String(t)
    }
    return acc == text ? nil : acc
}
