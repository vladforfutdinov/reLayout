// Auto-mode decision: was a just-typed word typed in the wrong layout, and to
// which cross-script target? Platform-free, so macOS and Windows share it (and
// the tests cover it).

// Calibrated for ~99% precision on cross-script pairs (see scripts/trigram).
public let autoGarbage: Float = -2.5   // word looks like junk in its own language
public let autoMargin:  Float = 0.5    // converted form must beat it by this much
// Same-script pairs (ru<->uk) differ in a few letters only, so the margin is per
// target language, from a 6000+6000-word sweep (scripts/trigram, 2026-10-10):
// into uk 1.5 — the Russian model underrates "ы" words ("рыба", "пыль"), at 1.0
// they flip; into ru 1.0 — the dictionary-cleaned uk model is strict, 3/6000
// false at 1.0, and "кто-то" (1.11), "как-то" (1.02) are lost at 1.5.
public let autoSameScriptMargins: [String: Float] = ["uk": 1.5, "ru": 1.0]
public let autoSameScriptMargin: Float = 1.5   // other same-script pairs
// Words carrying mapped punctuation (',' is б, '[' is х …) get an absolute gate
// too: their typed-side score is floor-dominated, so the relative margin alone
// lets junk through ("e.g" -> "уюп", which scored <= -3.8). Measured 2026-10-12
// on 20k-word lists: a third of real Cyrillic words carry such a letter, and at
// -3.0 the gate rejected 14% of them ("халепа" -3.15); -3.6 passes 97.8% and
// fires nothing new on 39 English abbreviations ("e.g", "i.e", "don't" …).
public let autoPunctPlausible: Float = -3.6
// Pure-letter words: the converted form must read at least this well, so junk
// does not convert into lesser junk ("всы" -> "dcs" -4.25). Measured 2026-10-14
// on 12 one-Latin + one-Cyrillic pairs, frequency-weighted: recall -0.06 points
// at most, uk/ru leaks 0.54% -> 0.14%, English on de/fr/es/pl/pt 3.05% -> 0.13%.
public let autoPlausible: Float = -4.0
// A 3-letter word both of whose readings score at least this is two real words
// on the same keys ("рук" / "her", "цру" / "whe"): it waits for a neighbour like
// a 1-2 letter word. Measured 2026-10-14 on Leipzig news sentences, 6 pairs:
// leaks 0.56 -> 0.51 per 1000 words, whole wrong-layout sentences -0.04 points,
// a lone foreign 3-letter word in a sentence 96.5% -> 92.3% fixed.
public let autoAmbiguous: Float = -3.0

/// A layout that also knows its language, so the right trigram model can be picked.
public protocol AutoLayout: LayoutMaps {
    /// BCP-47 language, e.g. "ru", "uk", "en"; nil when the system reports none.
    var languageCode: String? { get }
}

// Auto fires between layouts of different scripts (Cyrillic<->Latin) and between
// same-script layouts of different languages (ru<->uk: "ъжа" is "їжа" typed on
// the Russian layout), under the same gates. Same-language pairs (ru / ru-PC)
// never: the text would not change.
//
// Length is NOT gated here — the trigram model pads `^^w$`, so 1-2 char words
// (prepositions: d->в, yf->на) still score. autoEvaluate applies the extra
// adjacency requirement that keeps short-word precision high; a bare candidate
// from here only means "looks like a wrong-layout word of some length".
/// The user's own verdict on a typed form, recorded from the hotkey (see
/// `hotkeyMisses`) and from undoing an auto-correction. No dictionary of a
/// language: only strings this user has explicitly fixed or restored.
public enum LearnedVerdict: String { case convert, keep }

/// The dictionary key of a typed form: lowercased, trailing non-letters dropped
/// (the hotkey sees "учше," where the auto path judged "учше").
/// Whether two enabled layouts share a script but not a language, both with a model:
/// the only setup where `decideAutoTarget(sameScript: true)` can fire.
public func hasSimilarLayouts<L: AutoLayout>(_ enabled: [L], model: (String) -> TrigramModel?) -> Bool {
    let langs = enabled.compactMap { l in l.languageCode.flatMap { model($0) != nil ? ($0, l.isCyrillic) : nil } }
    return langs.contains { a in langs.contains { $0.1 == a.1 && $0.0 != a.0 } }
}

public func learnedKey(_ w: String) -> String {
    var s = Substring(w.lowercased())
    while let l = s.last, !l.isLetter { s = s.dropLast() }
    return String(s)
}

/// Decides whether a just-typed word was typed in the wrong layout.
/// - Parameters:
///   - model: trigram model for a language code, cached by the caller.
///   - learned: the user's verdict on a `learnedKey`; `.keep` leaves the word,
///     `.convert` converts it past the plausibility gates.
///   - sameScript: also consider same-script layouts of another language (ru ↔ uk).
///     Experimental: the models tell the two apart only on their distinctive letters.
/// - Returns: the target layout, the converted word, and whether the word reads as
///   a real word both ways (`autoAmbiguous`: convert only next to a neighbour);
///   nil to leave the word alone.
///   With `sameScript`, `out == w` means: the text is right, only the layout is wrong.
public func decideAutoTarget<L: AutoLayout>(_ w: String, cur: L, enabled: [L],
                                            model: (String) -> TrigramModel?,
                                            learned: (String) -> LearnedVerdict? = { _ in nil },
                                            sameScript: Bool = false) -> (target: L, out: String, ambiguous: Bool)? {
    guard let curLang = cur.languageCode, let curModel = model(curLang) else { return nil }
    let targets = enabled.filter {
        $0.isCyrillic != cur.isCyrillic || (sameScript && $0.languageCode != curLang)
    }
    guard !targets.isEmpty else { return nil }

    let forced: Bool
    switch learned(learnedKey(w)) {
    case .keep: return nil
    case .convert: forced = true
    case nil: forced = false
    }
    let sTyped = curModel.score(w)
    guard forced || sTyped < autoGarbage else {
        return nil   // already plausible -> leave it
    }
    // Cross-script gate: the word is junk only if no layout of its script reads
    // it. Languages typed on any layout of their script even when not enabled
    // (Russian on uk: "еще" -> "tot"; Ukrainian on ru: "лише" -> "kbit"; English
    // on pl: "but" -> "иге") always gate it: ru + uk for Cyrillic, en for Latin.
    var langs = enabled.filter { $0.isCyrillic == cur.isCyrillic }.compactMap(\.languageCode)
    langs += cur.isCyrillic ? ["ru", "uk"] : ["en"]
    var sScript = sTyped
    for lang in langs {
        if let m = model(lang) { sScript = max(sScript, m.score(w)) }
    }

    // A hyphen is not punctuation here — it is part of the word ("rfrjuj-nj" is
    // "какого-то"), and carries no layout ambiguity, so such a word is gated
    // like a pure-letter one.
    let pure = w.allSatisfy { $0.isLetter || isWordConnector($0) }
    // Mid-word layout switch leaves ONE word carrying both scripts ("ghjсто").
    // Punctuation-bearing mixed words are left alone — the shape gates below
    // reason about a single-script word.
    let mixed = pure && hasCyr(w[...]) && hasLatin(w[...])
    var best: (L, String, Float, ambiguous: Bool)?
    for t in targets {
        if mixed {
            // Two readings: convert the pre-switch run into the current script
            // ("ghjсто" -> "просто", target stays `cur` — no layout switch), or
            // convert the current-layout run into `t`. Each is scored under the
            // model of the script it ends up in.
            var readings: [(target: L, model: TrigramModel, src: L, dst: L)] =
                [(cur, curModel, t, cur)]
            if let tLang = t.languageCode, let tModel = model(tLang) {
                readings.append((t, tModel, cur, t))
            }
            for r in readings {
                guard let out = convertScriptRuns(w, src: r.src, dst: r.dst), out != w else { continue }
                let sAlt = r.model.score(out)
                guard sAlt - sTyped > autoMargin else { continue }
                if best == nil || sAlt > best!.2 { best = (r.target, out, sAlt, false) }
            }
            continue
        }
        // Shape + core gates (see autoWordCore): mapped punctuation may be a
        // Cyrillic letter (",skj" is "было"), but not when the word minus its
        // edge punctuation is already plausible ("'hello", "hello," stay).
        // Pure-letter words have no such ambiguity (core == word), and a lone
        // letter — a preposition — trips autoWordCore's letters>=2 guard, so
        // skip it for them.
        // A char that BECOMES a connector is word material too, and carries no
        // ambiguity either: on a Latin layout the Ukrainian apostrophe is "\\"
        // ("v\\zrj" is "мʼяко"), so that word is gated like a pure-letter one.
        let pureFor = pure || w.allSatisfy {
            $0.isLetter || isWordConnector($0) || mapsToConnector($0, src: cur, dst: t)
        }
        if !pureFor {
            guard let core = autoWordCore(w, src: cur, dst: t),
                  forced || core.count == w.count || curModel.score(String(core)) < autoGarbage
            else { continue }
        }
        // Same script: a word without the layouts' distinctive letters converts to
        // itself ("мабуть" on the Russian layout); the caller then only switches
        // the layout. Across scripts an unchanged word is no conversion.
        let sameScript = t.isCyrillic == cur.isCyrillic
        guard let out = convertWrong(w, src: cur, dst: t) ?? (sameScript ? w : nil), sameScript || out != w,
              let tLang = t.languageCode, let tModel = model(tLang) else { continue }
        // Read like the gate above: the script's common language counts on any of
        // its layouts ("c,jhrf" is Russian "сборка" typed for a Ukrainian layout).
        let sAlt = max(tModel.score(out), model(t.isCyrillic ? "ru" : "en")?.score(out) ?? -.infinity)
        guard forced || sAlt > (pureFor ? autoPlausible : autoPunctPlausible) else { continue }
        let margin = sameScript ? autoSameScriptMargins[tLang] ?? autoSameScriptMargin : autoMargin
        let sGate = sameScript ? sTyped : sScript   // same-script: the target's own model is the alternative
        guard forced || (sGate < autoGarbage && sAlt - sGate > margin) else { continue }
        let ambiguous = !forced && !sameScript && pure && w.count == 3
            && sGate >= autoAmbiguous && sAlt >= autoAmbiguous
        if best == nil || sAlt > best!.2 { best = (t, out, sAlt, ambiguous) }
    }
    guard let b = best else {
        return nil
    }
    return (b.0, b.1, b.ambiguous)
}

/// A system spell checker: whether `word` is spelled right in language `lang`
/// (ISO 639-1); nil when there is no dictionary for that language.
public typealias SpellCheck = (_ word: String, _ lang: String) -> Bool?

/// Languages typed on a script's layouts: the enabled ones plus the script's
/// common languages, as in the cross-script gate of `decideAutoTarget`.
public func scriptLanguages<L: AutoLayout>(cyrillic: Bool, enabled: [L]) -> [String] {
    var langs = enabled.filter { $0.isCyrillic == cyrillic }.compactMap(\.languageCode)
    langs += cyrillic ? ["ru", "uk"] : ["en"]
    var seen = Set<String>()
    return langs.filter { seen.insert($0).inserted }
}

/// True if any language's dictionary has the word, false if at least one has a
/// dictionary and none has the word, nil if none has a dictionary.
func spelledRight(_ w: String, in langs: [String], _ isWord: SpellCheck) -> Bool? {
    var any: Bool?
    for l in langs {
        guard let r = isWord(w, l) else { continue }
        if r { return true }
        any = false
    }
    return any
}

// Rule A2 (HISTORY, after v1.3.14): measured on FrequencyWords 20k, it raised
// recall and lowered false positives on every en <-> ru/uk run.
public let spellOverrideMinLetters = 4

/// Refines a cross-script `decideAutoTarget` result with a system dictionary.
/// - A conversion is dropped when the typed word is spelled right in its script
///   and the conversion is not; when both are words the trigram decision stands.
/// - A word the trigrams leave alone is converted when it is junk to them, no
///   dictionary of its script has it, and a dictionary of the other script has its
///   conversion (pure letters, `spellOverrideMinLetters`+ letters).
/// Same-script results and learned `.keep` words are left as they are.
/// - Returns: the refined decision; nil to leave the word.
public func spellCheckedTarget<L: AutoLayout>(_ w: String, cur: L, enabled: [L],
                                              decided: (target: L, out: String, ambiguous: Bool)?,
                                              model: (String) -> TrigramModel?,
                                              learned: (String) -> LearnedVerdict? = { _ in nil },
                                              isWord: SpellCheck) -> (target: L, out: String, ambiguous: Bool)? {
    let typedLangs = scriptLanguages(cyrillic: cur.isCyrillic, enabled: enabled)
    if let d = decided {
        guard d.target.isCyrillic != cur.isCyrillic, learned(learnedKey(w)) != .convert else { return d }
        let outLangs = scriptLanguages(cyrillic: d.target.isCyrillic, enabled: enabled)
        if spelledRight(w, in: typedLangs, isWord) == true, spelledRight(d.out, in: outLangs, isWord) == false {
            return nil
        }
        return d
    }
    guard learned(learnedKey(w)) != .keep, w.count >= spellOverrideMinLetters, w.allSatisfy(\.isLetter),
          let lang = cur.languageCode, let m = model(lang), m.score(w) < autoGarbage,
          spelledRight(w, in: typedLangs, isWord) == false else { return nil }
    for t in enabled where t.isCyrillic != cur.isCyrillic {
        guard let out = convertWrong(w, src: cur, dst: t), out != w, out.allSatisfy(\.isLetter),
              spelledRight(out, in: scriptLanguages(cyrillic: t.isCyrillic, enabled: enabled), isWord) == true
        else { continue }
        return (t, out, false)
    }
    return nil
}


/// The system spell checker's suggestions for a misspelled `word` in language `lang`.
public typealias SpellGuesses = (_ word: String, _ lang: String) -> [String]

/// True when `a` and `b` differ by one edit: a substituted, inserted or deleted
/// letter, or two adjacent letters swapped.
public func isOneEdit(_ a: String, _ b: String) -> Bool {
    let x = Array(a), y = Array(b)
    if x.count == y.count {
        let diff = x.indices.filter { x[$0] != y[$0] }
        if diff.count == 1 { return true }
        return diff.count == 2 && diff[1] == diff[0] + 1 && x[diff[0]] == y[diff[1]] && x[diff[1]] == y[diff[0]]
    }
    let (long, short) = x.count > y.count ? (x, y) : (y, x)
    guard long.count == short.count + 1 else { return false }
    var i = 0
    while i < short.count, long[i] == short[i] { i += 1 }
    return long[(i + 1)...].elementsEqual(short[i...])
}

/// The one dictionary word a misspelled conversion was most likely meant to be:
/// first one doubled letter removed or two adjacent letters swapped, else the
/// system's guesses one edit away. Nil unless exactly one candidate remains.
func repairedSpelling(_ out: String, langs: [String], isWord: SpellCheck, guesses: SpellGuesses) -> String? {
    let chars = Array(out)
    guard chars.count >= 2 else { return nil }
    var own = Set<String>()
    for i in 0..<(chars.count - 1) {
        var c = chars
        if chars[i] == chars[i + 1] { c.remove(at: i) } else { c.swapAt(i, i + 1) }
        own.insert(String(c))
    }
    let words = own.filter { $0.count >= spellOverrideMinLetters && spelledRight($0, in: langs, isWord) == true }
    if words.count == 1 { return words.first }
    var guessed = Set<String>()
    for l in langs {
        for g in guesses(out, l) where g.count >= spellOverrideMinLetters && g.allSatisfy(\.isLetter)
            && g.first?.isUppercase == false && isOneEdit(out, g) {
            guessed.insert(g)
        }
    }
    return guessed.count == 1 ? guessed.first : nil
}

/// Repairs a one-letter typo in a wrong-layout word on top of `spellCheckedTarget`
/// (`decided`): a conversion that is not a dictionary word ("ghbddtn" ->
/// "приввет") becomes the single dictionary word `repairedSpelling` finds
/// ("привет"); a word left alone is converted when its conversion repairs to one.
/// The typed word must be pure letters, `spellOverrideMinLetters`+ long, not
/// capitalized, junk to its own model and misspelled in its script.
/// - Returns: the decision and whether a typo was repaired; nil to leave the word.
public func spellRepairedTarget<L: AutoLayout>(_ w: String, cur: L, enabled: [L],
                                               decided: (target: L, out: String, ambiguous: Bool)?,
                                               model: (String) -> TrigramModel?,
                                               learned: (String) -> LearnedVerdict? = { _ in nil },
                                               isWord: SpellCheck, guesses: SpellGuesses)
    -> (target: L, out: String, ambiguous: Bool, repaired: Bool)? {
    let plain = decided.map { (target: $0.target, out: $0.out, ambiguous: $0.ambiguous, repaired: false) }
    guard learned(learnedKey(w)) != .keep, w.count >= spellOverrideMinLetters, w.allSatisfy(\.isLetter),
          w.first?.isUppercase == false, let lang = cur.languageCode, let m = model(lang), m.score(w) < autoGarbage,
          spelledRight(w, in: scriptLanguages(cyrillic: cur.isCyrillic, enabled: enabled), isWord) == false
    else { return plain }
    let targets = decided.map { [$0.target] } ?? enabled.filter { $0.isCyrillic != cur.isCyrillic }
    for t in targets where t.isCyrillic != cur.isCyrillic {
        let langs = scriptLanguages(cyrillic: t.isCyrillic, enabled: enabled)
        guard let out = decided?.out ?? convertWrong(w, src: cur, dst: t), out != w, out.allSatisfy(\.isLetter),
              spelledRight(out, in: langs, isWord) == false,
              let fixed = repairedSpelling(out, langs: langs, isWord: isWord, guesses: guesses)
        else { continue }
        return (t, fixed, decided?.ambiguous ?? false, true)
    }
    return plain
}

// A hotkey miss is learned only when its conversion reads in the target
// language: a real miss does ("exit" -2.41, "ок" -2.78, "сброс" -3.41), a
// deliberate transliteration of correct text does not ("nf ot [fktgf" -10..-18),
// and a single letter has no trigram at all (floor). Without this, every word of
// a transliterated selection became a `convert` verdict.
public let autoLearnPlausible: Float = -4.5
// One hotkey press on a word may be a one-off; the same correction three times
// is the model being wrong about it. `convert` verdicts need this many.
public let autoLearnRepeats = 3

/// The words of a hotkey conversion that auto mode would have left alone: the
/// user just overruled it, so they are learned as `.convert`.
/// - Parameters:
///   - replaced: the text the hotkey converted, as typed.
///   - out: its conversion (same whitespace, word for word).
///   - src: the layout the text was typed in.
///   - dst: the layout it was converted into; its model vets each result.
/// - Returns: `learnedKey`s of the misses.
public func hotkeyMisses<L: AutoLayout>(replaced: String, out: String, src: L, dst: L, enabled: [L],
                                        model: (String) -> TrigramModel?) -> [String] {
    let typedWords = replaced.split(whereSeparator: { $0.isWhitespace })
    let outWords = out.split(whereSeparator: { $0.isWhitespace })
    guard typedWords.count == outWords.count, let dstModel = dst.languageCode.flatMap(model) else { return [] }
    // A whole phrase still in the wrong layout: every long word of it escaped auto
    // mode, whatever the engine thinks of it now; the short ones were held on
    // purpose. A single word is a miss when auto would leave it, or is short
    // (trusted only next to a neighbour).
    let phrase = typedWords.count > 1
    return zip(typedWords, outWords).compactMap { t, o in
        let key = learnedKey(String(t))
        guard t != o, !key.isEmpty, dstModel.score(learnedKey(String(o))) > autoLearnPlausible else { return nil }
        let miss = phrase ? wordBody(key) >= 3
            : wordBody(key) < 3 || decideAutoTarget(key, cur: src, enabled: enabled, model: model)?.ambiguous ?? true
        return miss ? key : nil
    }
}


// MARK: - Mid-word layout switch

/// Fixes a word that mixes scripts because the layout was switched mid-word. Which
/// half is wrong is not decidable from the layouts alone — "ghjсто" wants its head
/// fixed ("просто"), "мирqwerty" its tail ("мирйцукен"), and the two are shaped the
/// same — so both readings are scored with the trigram models and the better wins.
/// No confidence gates: this serves the hotkey, an explicit request.
/// - Parameter model: trigram model for a language code, cached by the caller.
/// - Returns: the fixed word, the layout it is now in (`dst`) and the one the wrong
///   half was typed in (`src`); nil when `w` is not a pure-letter mixed-script word.
public func fixMixedWord<L: AutoLayout>(_ w: String, cur: L, enabled: [L],
                                        model: (String) -> TrigramModel?) -> (out: String, dst: L, src: L)? {
    guard w.allSatisfy(\.isLetter), hasCyr(w[...]), hasLatin(w[...]) else { return nil }
    var best: (out: String, dst: L, src: L, score: Float)?
    func offer(_ out: String?, dst: L, src: L) {
        guard let out, out != w, let lang = dst.languageCode, let m = model(lang) else { return }
        let score = m.score(out)
        if best == nil || score > best!.score { best = (out, dst, src, score) }
    }
    for t in enabled where t.isCyrillic != cur.isCyrillic {
        // Head reading: the other-script run predates the switch -> current layout.
        offer(convertScriptRuns(w, src: t, dst: cur), dst: cur, src: t)
        // Tail reading: what was typed on the current layout is the wrong half.
        offer(convertScriptRuns(w, src: cur, dst: t), dst: t, src: cur)
    }
    return best.map { ($0.out, $0.dst, $0.src) }
}

// MARK: - Hotkey: which layouts a selection converts between

/// Plans the hotkey conversion of a selection.
///
/// In order: a single word with both scripts is a mid-word layout switch
/// (`fixMixedWord`); a text with none of the current layout's script was typed
/// before the user switched, so it converts from its own script back to the
/// current layout; otherwise the current layout is the wrong one and the target
/// comes from `pickTarget`.
/// - Parameters:
///   - enabled: the enabled layouts, in the system's order.
///   - curIdx: index of the active layout in `enabled`.
///   - model: trigram model for a language code (only the mixed-word case uses it).
/// - Returns: the converted text, its layouts, and the part of `text` it replaces;
///   nil when nothing converts.
public func planRetype<L: AutoLayout>(_ text: String, enabled: [L], curIdx: Int,
                                      model: (String) -> TrigramModel?)
    -> (out: String, dst: L, src: L, replaced: String)? {
    guard enabled.count >= 2, enabled.indices.contains(curIdx) else { return nil }
    let cur = enabled[curIdx]

    let toks = tokenize(text)
    if toks.count == 1, let word = toks.first, !(word.first?.isWhitespace ?? true),
       let fix = fixMixedWord(String(word), cur: cur, enabled: enabled, model: model) {
        return (fix.out, fix.dst, fix.src, String(word))
    }

    // Switched after typing: the wrong layout is the text's, the target the current.
    if !textHasScript(text, cyrillic: cur.isCyrillic),
       let wrongCyr = dominantScript(text), wrongCyr != cur.isCyrillic {
        let srcs = enabled.filter { $0.isCyrillic == wrongCyr }
        let src = bestConversion(text, pairs: srcs.map { ($0, cur) }, model: model)?.src ?? srcs.first
        if let src, let out = convertWrong(text, src: src, dst: cur) {
            return (out, cur, src, text)
        }
    }

    let targets = enabled.filter { $0.isCyrillic != cur.isCyrillic }
    let target = bestConversion(text, pairs: targets.map { (cur, $0) }, model: model)?.dst
        ?? pickTarget(text, enabled: enabled, curIdx: curIdx)
    if let out = convertWrong(text, src: cur, dst: target) { return (out, target, cur, text) }
    // The positional pick was a same-script twin (Polish Programmers vs US: the
    // same keys), so nothing changed: the other script is the only real target.
    guard let t = targets.first, let out = convertWrong(text, src: cur, dst: t) else { return nil }
    return (out, t, cur, text)
}

/// Among several layouts of one script (ru + uk, en + de): the pair whose
/// conversion the destination's language model reads best. Nil with fewer than
/// two pairs, no models, or nothing converting — the caller's positional rule
/// then decides.
func bestConversion<L: AutoLayout>(_ text: String, pairs: [(src: L, dst: L)],
                                  model: (String) -> TrigramModel?) -> (src: L, dst: L)? {
    guard pairs.count > 1 else { return nil }
    var best: (pair: (src: L, dst: L), score: Float)?
    for p in pairs {
        guard let lang = p.dst.languageCode, let m = model(lang),
              let out = convertWrong(text, src: p.src, dst: p.dst),
              let s = textScore(out, m) else { continue }
        if best == nil || s > best!.score { best = (p, s) }
    }
    return best?.pair
}

/// Length-weighted mean word score of a text; nil when it has no words.
private func textScore(_ text: String, _ m: TrigramModel) -> Float? {
    let words = text.split(whereSeparator: { $0.isWhitespace })
    let n = words.reduce(0) { $0 + $1.count }
    guard n > 0 else { return nil }
    return words.reduce(Float(0)) { $0 + m.score(String($1)) * Float($1.count) } / Float(n)
}

/// The other readings of a hotkey conversion, for the press-again cycle: `text`
/// converted from the layout it was typed on into every other enabled layout,
/// best-reading first (layouts without a model last, in list order). Distinct
/// results only; `first` (what the hotkey already typed) and the text itself are
/// left out. Empty with two layouts, so the second press stays the undo.
/// - Parameter srcIdx: index in `enabled` of the layout the text was typed on.
public func retypeAlternatives<L: AutoLayout>(_ text: String, enabled: [L], srcIdx: Int, first: String,
                                              model: (String) -> TrigramModel?) -> [(out: String, dst: L)] {
    guard enabled.indices.contains(srcIdx) else { return [] }
    let src = enabled[srcIdx]
    var seen: Set<String> = [first, text]
    var scored: [(out: String, dst: L, score: Float?)] = []
    for (i, d) in enabled.enumerated() where i != srcIdx {
        guard let out = convertWrong(text, src: src, dst: d), !seen.contains(out) else { continue }
        seen.insert(out)
        scored.append((out, d, d.languageCode.flatMap(model).flatMap { textScore(out, $0) }))
    }
    let ranked = scored.enumerated().sorted { a, b in
        switch (a.element.score, b.element.score) {
        case let (x?, y?): return x > y
        case (nil, nil): return a.offset < b.offset
        case (nil, _): return false
        case (_, nil): return true
        }
    }
    return ranked.map { ($0.element.out, $0.element.dst) }
}

/// Target layout when the current one is the wrong one: with two layouts, the
/// other; with more, the first unless the current is first — then the one the
/// rest of the text is written in, if exactly one layout has that script, else
/// the second.
public func pickTarget<L: LayoutMaps>(_ text: String, enabled: [L], curIdx: Int) -> L {
    if enabled.count == 2 { return enabled[curIdx == 0 ? 1 : 0] }
    if curIdx != 0 { return enabled[0] }
    return restTextLayout(text, enabled: enabled, curIdx: curIdx) ?? enabled[1]
}

/// The layout implied by the words of the other script in `text`, when exactly one
/// enabled layout has that script.
private func restTextLayout<L: LayoutMaps>(_ text: String, enabled: [L], curIdx: Int) -> L? {
    let cur = enabled[curIdx]
    let words = tokenize(text).filter { !($0.first?.isWhitespace ?? true) }
    let otherScriptPresent = cur.isCyrillic
        ? words.contains { !hasCyr($0) && hasLatin($0) }
        : words.contains { hasCyr($0) }
    guard otherScriptPresent else { return nil }
    let candidates = enabled.indices.filter { $0 != curIdx && enabled[$0].isCyrillic != cur.isCyrillic }
    return candidates.count == 1 ? enabled[candidates[0]] : nil
}

// MARK: - The typed-word run

/// Length of `w` without its trailing non-letters: a trailing mapped char is the
/// weakest evidence ("vs." reads as "мію"), so trust is measured without it.
public func wordBody(_ w: String) -> Int {
    w.reversed().drop(while: { !$0.isLetter }).count
}

/// What the auto mode knows about the text right before the caret: the word being
/// typed, the punctuation typed after it, and the word before it. Fed only with
/// what the user typed; the platform resets it whenever the caret may have moved.
public struct AutoRun {
    /// The previous word of the run, for the short-word rule.
    public struct Previous: Equatable {
        public let raw: String        // as typed, still on screen
        public let out: String        // its conversion
        public let cyrillic: Bool     // script of the conversion
        public let committed: Bool    // true: retyped; false: a pending short candidate
    }

    /// What a fed key did to the run.
    public enum Event: Equatable {
        case none
        /// Space or Tab ended `word` (+ `trail`): judge it now.
        case boundary(word: String, trail: String)
        /// Return ended it. Never corrected before Return lands — it may submit.
        case enter(word: String, trail: String)
    }

    /// One correction: delete `erase` characters before the caret, type `text`.
    /// `original` is what those characters were, for undo.
    public struct Fix: Equatable {
        public let erase: Int
        public let text: String
        public let original: String
    }

    public private(set) var word = ""
    public private(set) var trail = ""
    public private(set) var previous: Previous?
    // Short words without a candidate typed after `previous` ("ot" in "nf ot
    // [fktgf": "ot" reads as English): they ride along when the chain commits on
    // a long candidate, rather than breaking it.
    private var bridged: [(raw: String, out: String)] = []
    // The last word (+ trail) and the spaces typed after it: still the hotkey's
    // target until any other key.
    private var spacedWord = "", spacedTrail = "", spaces = 0

    public init() {}

    /// What the hotkey converts with nothing selected: the word being typed, else
    /// the last word followed only by spaces. Empty when there is none.
    public var hotkeyTarget: (text: String, spaces: Int) {
        word.isEmpty && trail.isEmpty ? (spacedWord + spacedTrail, spaces) : (word + trail, 0)
    }

    /// Makes `text` (what an undo or a retarget just put before the caret, spaces
    /// and punctuation included) the hotkey's target as a whole. Any key drops it.
    public mutating func remember(_ text: String) {
        reset()
        spacedWord = text
    }

    /// Ends the run; the previous word can no longer join a correction.
    public mutating func reset() {
        word = ""; trail = ""; previous = nil; bridged = []
        dropSpacedWord()
    }

    private mutating func dropSpacedWord() {
        spacedWord = ""; spacedTrail = ""; spaces = 0
    }

    /// Feeds the text one keystroke produced.
    /// - Parameter mapsToCyrillic: true when the character is a letter on an
    ///   enabled Cyrillic layout while a Latin one is active ("," is б), so ",skj"
    ///   buffers as "было" instead of breaking the word.
    public mutating func feed(_ s: String, mapsToCyrillic: (Character) -> Bool) -> Event {
        // A key that types nothing (Globe/fn — the layout switch itself, dead keys,
        // F-keys) must not break the run: switching layout mid-word is exactly the
        // case that has to keep "ghj" so "ghjсто" is judged as one word.
        if s.isEmpty { return .none }
        if s == "\r" || s == "\n" {
            let ended = Event.enter(word: word, trail: trail)
            reset()
            return ended
        }
        if s == " " || s == "\t" {
            if s == "\t" {
                dropSpacedWord()   // Tab may move focus: nothing to erase across it
            } else if !word.isEmpty || !trail.isEmpty {
                spacedWord = word; spacedTrail = trail; spaces = 1
            } else if spaces > 0 || !spacedWord.isEmpty {
                spaces += 1   // a remembered text gets its spaces counted too
            }
            let ended = Event.boundary(word: word, trail: trail)
            word = ""; trail = ""   // the previous word stays for the short-word rule
            return ended
        }
        guard s.count == 1, let c = s.first else { reset(); return .none }
        dropSpacedWord()
        if c.isLetter || (trail.isEmpty && (mapsToCyrillic(c) || (isWordConnector(c) && !word.isEmpty))) {
            if !trail.isEmpty { reset() }   // "a?b": a new run
            word.append(c)
            if word.count > 64 { word.removeFirst(word.count - 64) }
        } else if !word.isEmpty, c.isPunctuation || c.isSymbol {
            // Punctuation that is not word material trails the word ("ltkfq?"); it
            // is judged only when whitespace follows, so "@" or "/" inside an address
            // or a path — never followed by whitespace — breaks nothing.
            trail.append(c)
        } else {
            reset()   // digits, interior punctuation, navigation: the run ends
        }
        return .none
    }

    /// Backspace edits the word being typed, so the run follows it instead of
    /// ending. A wide delete (word/line) leaves nothing to track.
    public mutating func backspace(wide: Bool) {
        if wide { reset(); return }
        if spaces > 0 {
            // Deleting the last space rejoins the word: it is being typed again, and
            // the short-word rule must not pair it with itself.
            spaces -= 1
            if spaces == 0 { word = spacedWord; trail = spacedTrail; previous = nil; dropSpacedWord() }
            return
        }
        if !trail.isEmpty { trail.removeLast(); return }
        word = String(word.dropLast())
        if word.isEmpty { previous = nil }
    }

    /// The boundary word had no candidate: it breaks the chain of short words.
    public mutating func noCandidate() {
        previous = nil; bridged = []
    }

    /// A short word with no candidate right after a chain word: it neither breaks
    /// the chain nor converts alone. `out` is its reading in the chain's layout, typed
    /// with the rest when a long candidate commits the chain. Ignored without a chain.
    public mutating func bridge(raw: String, out: String) {
        guard previous != nil else { return }
        bridged.append((raw, out))
    }

    /// Decides whether a candidate at a boundary is fixed now.
    /// - Parameters:
    ///   - raw: the word plus its trail, as typed.
    ///   - out: their conversion.
    ///   - cyrillic: the script of the conversion.
    ///   - trusted: the user's own verdict (a learned word): fixed alone whatever its length.
    ///   - ambiguous: a long word that reads as a real word both ways: waits like a short one.
    /// - Returns: the correction, or nil when a short word waits for a neighbour.
    public mutating func plan(raw: String, out: String, cyrillic: Bool, trusted: Bool = false,
                              ambiguous: Bool = false) -> Fix? {
        let fix = planFix(raw: raw, out: out, cyrillic: cyrillic, trusted: trusted, ambiguous: ambiguous)
        if fix != nil { dropSpacedWord() }   // converted: nothing left for the hotkey
        return fix
    }

    private mutating func planFix(raw: String, out: String, cyrillic: Bool, trusted: Bool, ambiguous: Bool) -> Fix? {
        let chain = previous.flatMap { $0.cyrillic == cyrillic ? $0 : nil }
        let bridge = chain == nil ? [] : bridged
        bridged = []
        // Everything retyped before this word: a pending short candidate (the
        // "d ljhjut" case) and the bridged short words after the last chain word.
        func fix(_ before: [(raw: String, out: String)]) -> Fix {
            let raws = before.map(\.raw) + [raw], outs = before.map(\.out) + [out]
            let original = raws.joined(separator: " ")
            return Fix(erase: original.count, text: outs.joined(separator: " "), original: original)
        }
        if trusted || (wordBody(raw) >= 3 && !ambiguous) {
            let swallow = chain.flatMap { $0.committed ? nil : ($0.raw, $0.out) }.map { [$0] } ?? []
            previous = Previous(raw: raw, out: out, cyrillic: cyrillic, committed: true)
            return fix(swallow + bridge)
        }
        if let p = chain {
            previous = Previous(raw: raw, out: out, cyrillic: cyrillic, committed: true)
            // A short word right after a committed conversion of the same script, or
            // two short candidates in a row ("пщ ещ"): one alone is a guess the
            // trigram cannot back, two agreeing neighbours are trusted together.
            return fix((p.committed ? [] : [(p.raw, p.out)]) + bridge)
        }
        previous = Previous(raw: raw, out: out, cyrillic: cyrillic, committed: false)
        return nil
    }
}

// MARK: - Enter follow-up

/// Waits until the field stops changing after Return: the system may recapitalize
/// the word ~50 ms after the line break appears, so one changed read is not enough.
/// - Parameters:
///   - read: reads the field; nil when it cannot be read.
///   - wait: sleeps (or pumps) for the given milliseconds.
/// - Returns: the settled field, or nil when it did not settle within ~0.5 s.
public func awaitSettledField(before: FieldSnapshot, read: () -> FieldSnapshot?,
                              wait: (Int) -> Void) -> FieldSnapshot? {
    var last: FieldSnapshot?, stable = 0
    for _ in 0..<20 {
        wait(25)
        let snap = read()
        stable = (snap != nil && snap == last) ? stable + 1 : 0
        last = snap
        if stable >= 3, let snap, snap != before { return snap }
    }
    return nil
}

// MARK: - Exceptions list

/// The user's saved exceptions plus any default introduced since they last saw the
/// defaults. Each new default is offered once: one the user removed stays removed.
/// - Parameters:
///   - saved: the user's list as stored.
///   - defaults: the current defaults.
///   - seen: the defaults the stored list already reflects.
public func mergeExclusions(saved: [String], defaults: [String], seen: Set<String>) -> [String] {
    saved + defaults.filter { !seen.contains($0) && !saved.contains($0) }
}

// MARK: - Versions

/// True when release tag `candidate` ("v1.3.0") is newer than `current` ("1.2.27").
/// Numeric dot parts only; anything unparsable (a dev build's "0.0.0-dev" suffix,
/// a pre-release tag) is never newer.
public func isNewerVersion(_ candidate: String, than current: String) -> Bool {
    func parts(_ v: String) -> [Int]? {
        let bare = v.hasPrefix("v") ? v.dropFirst() : v[...]
        let nums = bare.split(separator: ".").map { Int($0) }
        return nums.contains(nil) || nums.isEmpty ? nil : nums.map { $0! }
    }
    guard let a = parts(candidate), let b = parts(current) else { return false }
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}
