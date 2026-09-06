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

// Characters that live INSIDE a word but are not letters: the hyphen ("кое-что")
// and the Ukrainian apostrophe ("мʼяко", typed as "v\\zrj" — "\\" is ʼ on the
// Ukrainian layout). The models are built from a plain word list and carry none of
// them, so scoring splits on them.
// The ASCII "'" is deliberately NOT one: it is э on ЙЦУКЕН, real word material
// ("'nj" is "это").
public func isWordConnector(_ ch: Character) -> Bool {
    ch == "-" || ch == "–" || ch == "—" || ch == "\u{02BC}" || ch == "\u{2019}"
}

// A word is wrong-but-Cyrillic-target if any of its chars (which src can type) maps
// to a Cyrillic letter in dst. Catches the Option layer (ß/æ -> ы/э), neither a-z nor Cyrillic.
func mapsToCyr(_ w: Substring, src: LayoutMaps, dst: LayoutMaps) -> Bool {
    mapsToWordChar(w, src: src, dst: dst, connectors: false)
}

// True if any char of `w` becomes word material when retyped src -> dst: a
// Cyrillic letter, or — with `connectors` — an intra-word connector. The
// Ukrainian apostrophe has no key of its own on a Latin layout, so "мʼяко" is
// typed "v\\zrj" and the "\\" must not read as punctuation.
// True if `ch`, retyped src -> dst, becomes an intra-word connector.
public func mapsToConnector(_ ch: Character, src: LayoutMaps, dst: LayoutMaps) -> Bool {
    guard let st = src.charToStroke[String(ch)], let m = dst.strokeToChar[st],
          m.count == 1 else { return false }
    return isWordConnector(Character(m))
}

public func mapsToWordChar(_ w: Substring, src: LayoutMaps, dst: LayoutMaps,
                           connectors: Bool) -> Bool {
    for ch in w {
        guard let st = src.charToStroke[String(ch)], let m = dst.strokeToChar[st],
              let f = m.unicodeScalars.first else { continue }
        if isCyrLetter(f) { return true }
        if connectors, m.count == 1, isWordConnector(Character(m)) { return true }
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
// With nothing selected the platform layer grabs the whole line back to the line
// start, but only the word at the caret is ever converted: the rest of the line is
// text the user is not thinking about, and any "which part is wrong" heuristic
// guesses wrong on some lines. A word is a run of non-whitespace, so mid-word
// punctuation ("кое-что", "e-mail") stays inside it.
//
// Returns the start of that word (window = text[start...], trailing whitespace
// included so it is retyped verbatim), or nil when the line has no word.
public func caretWord(_ text: String) -> String.Index? {
    var end = text.endIndex
    while end > text.startIndex, text[text.index(before: end)].isWhitespace {
        end = text.index(before: end)
    }
    guard end > text.startIndex else { return nil }
    var start = end
    while start > text.startIndex, !text[text.index(before: start)].isWhitespace {
        start = text.index(before: start)
    }
    return start
}

// MARK: - Auto-mode word shape
//
// A Cyrillic word typed on a Latin layout may embed punctuation that IS a letter
// on the intended layout (',' is б, ''' is э, ';' is ж, '[' is х on ЙЦУКЕН) —
// "было" arrives as ",skj". Auto-mode must treat such chars as word material, but
// every keyboard also types them as real punctuation, so the shape is vetted here:
//
//   - every char must be a letter or map to a Cyrillic letter in `dst`;
//   - at least two real letters — per-language trigram floors differ, so a
//     floor-dominated string ("z...", "...") beats the score margin on the floor
//     difference alone and would retype "..." as "ююю";
//   - the last char must be a letter. A trailing mapped char is genuinely
//     ambiguous ("pyf." is both "знаю" and "зна."; "ghbdtn," is both "приветб"
//     and "привет,") and the trigram models cannot separate the two readings —
//     measured on common words the score gap between the readings overlaps in
//     both directions. Leading/interior mapped chars carry no such ambiguity
//     (no Latin word starts ",…"), so only those convert.
//
// Returns the word's core — the word minus its leading mapped-punctuation run —
// for the caller's plausibility check ("'hello" must not fire: the core "hello"
// is a real word and the quote was a quote). nil when the shape disqualifies.
public func autoWordCore(_ w: String, src: LayoutMaps, dst: LayoutMaps) -> Substring? {
    var letters = 0
    for ch in w {
        if ch.isLetter { letters += 1 }
        else if isWordConnector(ch) { continue }
        else if !mapsToWordChar(String(ch)[...], src: src, dst: dst, connectors: true) { return nil }
    }
    guard letters >= 2, w.last?.isLetter == true else { return nil }
    var core = Substring(w)
    while core.first?.isLetter == false { core = core.dropFirst() }
    return core
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
        // Mid-word layout switch: a token carrying both scripts has only its
        // src-script runs converted — transliterating it whole would drag the
        // already-correct half through an unrelated layout.
        if hasCyr(t), hasLatin(t) {
            acc += convertScriptRuns(String(t), src: src, dst: dst) ?? String(t)
            continue
        }
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

// Sub-word conversion for a mid-word layout switch: a single word may mix scripts
// ("ghjсто" — "про" typed on Latin, then the layout switched and "сто" followed).
// Converts every maximal run of `src`-script letters through `src` -> `dst` and
// leaves the rest verbatim, so both readings of a mixed word are expressible:
// src = the pre-switch layout fixes the prefix ("ghjсто" -> "просто"), src = the
// current layout fixes the tail. Returns nil if nothing changed.
public func convertScriptRuns(_ text: String, src: LayoutMaps, dst: LayoutMaps) -> String? {
    var acc = "", run = ""
    func flush() {
        if !run.isEmpty { acc += transliterate(run, from: src, to: dst); run = "" }
    }
    for ch in text {
        let inSrc = ch.unicodeScalars.contains(where: src.isCyrillic ? isCyrLetter : isLatinLetter)
        if inSrc { run.append(ch) } else { flush(); acc.append(ch) }
    }
    flush()
    return acc == text ? nil : acc
}
