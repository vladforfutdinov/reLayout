// What both apps share of auto mode's per-word decision and of the user's learned
// verdicts. Platform code stores the lists (UserDefaults, the registry) and shows
// them; the rules for changing them live here.

/// The auto-mode decision for a typed word: the trigram decision, refined by the
/// system dictionary when spell checking is on.
/// - Parameters:
///   - spell: the platform's dictionary; nil when the spell-check option is off.
///     `guesses` returns nil when it ran out of time: a repair decided without
///     those suggestions is not trusted.
/// - Returns: the decision; `repaired` = a typo in the conversion was fixed too
///   (never learned).
public func autoDecision<L: AutoLayout>(_ w: String, cur: L, enabled: [L],
                                      model: (String) -> TrigramModel?,
                                      learned: (String) -> LearnedVerdict?, sameScript: Bool,
                                      spell: (isWord: SpellCheck, guesses: (String, String) -> [String]?)?)
    -> (target: L, out: String, ambiguous: Bool, repaired: Bool)? {
    let d = decideAutoTarget(w, cur: cur, enabled: enabled, model: model, learned: learned, sameScript: sameScript)
    guard let spell else { return d.map { ($0.target, $0.out, $0.ambiguous, false) } }
    let s = spellCheckedTarget(w, cur: cur, enabled: enabled, decided: d, model: model, learned: learned,
                               isWord: spell.isWord)
    var overBudget = false
    let r = spellRepairedTarget(w, cur: cur, enabled: enabled, decided: s, model: model, learned: learned,
                                isWord: spell.isWord, guesses: { word, lang in
        guard let g = spell.guesses(word, lang) else { overBudget = true; return [] }
        return g
    })
    if overBudget, r?.repaired == true { return s.map { ($0.target, $0.out, $0.ambiguous, false) } }
    return r
}

/// The user's verdicts on typed words (keys from `learnedKey`) and the hotkey
/// corrections counted toward one.
public struct LearnedWords: Equatable {
    /// Typed form -> its conversion: auto mode converts it whatever the models say.
    public var convert: [String: String]
    /// Typed forms auto mode leaves alone (the user undid their correction).
    public var keep: Set<String>
    /// Hotkey corrections seen for typed forms not yet in `convert`.
    public var counts: [String: Int]
    /// Their conversions; "" marks a keep candidate.
    public var candidates: [String: String]

    public init(convert: [String: String] = [:], keep: Set<String> = [], counts: [String: Int] = [:],
                candidates: [String: String] = [:]) {
        self.convert = convert; self.keep = keep; self.counts = counts; self.candidates = candidates
    }

    public func verdict(_ key: String) -> LearnedVerdict? {
        if convert[key] != nil { return .convert }
        return keep.contains(key) ? .keep : nil
    }

    /// Counts the hotkey misses of one conversion (engine `hotkeyMisses`); a word
    /// counted `autoLearnRepeats` times becomes `.convert`.
    /// - Parameters: replaced, out: the converted text and its conversion, paired word by word.
    /// - Returns: the keys promoted now.
    @discardableResult
    public mutating func count(misses: [String], replaced: String, out: String) -> [String] {
        guard !misses.isEmpty else { return [] }
        let typed = replaced.split(whereSeparator: { $0.isWhitespace }).map { learnedKey(String($0)) }
        let outs = out.split(whereSeparator: { $0.isWhitespace }).map { learnedKey(String($0)) }
        let byTyped = Dictionary(zip(typed, outs), uniquingKeysWith: { a, _ in a })
        var promoted: [String] = []
        for m in misses where convert[m] == nil {
            counts[m, default: 0] += 1
            candidates[m] = byTyped[m] ?? ""
            if counts[m]! >= autoLearnRepeats, let o = candidates[m], !o.isEmpty { promote(m, to: o); promoted.append(m) }
        }
        keep.subtract(misses)
        return promoted
    }

    /// Takes back what an undone conversion taught: its counted misses lose the count
    /// (or the promotion it caused), the words of an undone auto-correction become `.keep`.
    public mutating func unlearn(learned: [String], autoWords: [String]) {
        for w in learned {
            if convert[w] != nil { convert[w] = nil } else if let n = counts[w] { counts[w] = n > 1 ? n - 1 : nil }
            if counts[w] == nil { candidates[w] = nil }
        }
        for w in autoWords { convert[w] = nil }
        keep.formUnion(autoWords.filter { !$0.isEmpty })
    }

    /// Makes `key` a verdict: `.convert` to `out`, or `.keep` when `out` is empty.
    public mutating func promote(_ key: String, to out: String) {
        if out.isEmpty { convert[key] = nil; keep.insert(key) } else { convert[key] = out; keep.remove(key) }
        counts[key] = nil; candidates[key] = nil
    }

    /// Turns a verdict back into a candidate counted once (a `.keep` gets an empty conversion).
    public mutating func demote(_ key: String) {
        candidates[key] = convert.removeValue(forKey: key) ?? ""
        keep.remove(key)
        counts[key] = 1
    }

    /// Forgets `keys` everywhere, or everything when nil.
    public mutating func forget(_ keys: Set<String>? = nil) {
        guard let keys else { self = LearnedWords(); return }
        for k in keys { convert[k] = nil; counts[k] = nil; candidates[k] = nil }
        keep.subtract(keys)
    }

    /// Drops the candidates and their counts; no verdict is touched.
    public mutating func cleanCandidates() {
        candidates = [:]; counts = [:]
    }
}
