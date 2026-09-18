// Auto-mode decision: was a just-typed word typed in the wrong layout, and to
// which cross-script target? Platform-free, so macOS and Windows share it (and
// the tests cover it).

// Calibrated for ~99% precision on cross-script pairs (see scripts/trigram).
public let autoGarbage: Float = -2.5   // word looks like junk in its own language
public let autoMargin:  Float = 0.5    // converted form must beat it by this much
// Words carrying mapped punctuation (',' is б …) get a stricter, absolute gate:
// their typed-side score is floor-dominated, so the relative margin alone lets
// junk conversions through ("e.g" -> "уюп"). Real converted words score >= -2.6
// on the shipped models; the fired junk scored <= -3.8.
public let autoPunctPlausible: Float = -3.0

/// A layout that also knows its language, so the right trigram model can be picked.
public protocol AutoLayout: LayoutMaps {
    /// BCP-47 language, e.g. "ru", "uk", "en"; nil when the system reports none.
    var languageCode: String? { get }
}

// Auto fires ONLY between layouts of different scripts (Cyrillic<->Latin), where
// detection is reliable; same-script pairs always return nil.
//
// Length is NOT gated here — the trigram model pads `^^w$`, so 1-2 char words
// (prepositions: d->в, yf->на) still score. autoEvaluate applies the extra
// adjacency requirement that keeps short-word precision high; a bare candidate
// from here only means "looks like a wrong-layout word of some length".
/// Decides whether a just-typed word was typed in the wrong layout.
/// - Parameter model: trigram model for a language code, cached by the caller.
/// - Returns: the target layout and the converted word, or nil to leave the word alone.
public func decideAutoTarget<L: AutoLayout>(_ w: String, cur: L, enabled: [L],
                                            model: (String) -> TrigramModel?) -> (target: L, out: String)? {
    guard let curLang = cur.languageCode, let curModel = model(curLang) else { return nil }
    let targets = enabled.filter { $0.isCyrillic != cur.isCyrillic }   // cross-script only
    guard !targets.isEmpty else { return nil }

    let sTyped = curModel.score(w)
    guard sTyped < autoGarbage else {
        return nil   // already plausible -> leave it
    }

    // A hyphen is not punctuation here — it is part of the word ("rfrjuj-nj" is
    // "какого-то"), and carries no layout ambiguity, so such a word is gated
    // like a pure-letter one.
    let pure = w.allSatisfy { $0.isLetter || isWordConnector($0) }
    // Mid-word layout switch leaves ONE word carrying both scripts ("ghjсто").
    // Punctuation-bearing mixed words are left alone — the shape gates below
    // reason about a single-script word.
    let mixed = pure && hasCyr(w[...]) && hasLatin(w[...])
    var best: (L, String, Float)?
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
                if best == nil || sAlt > best!.2 { best = (r.target, out, sAlt) }
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
                  core.count == w.count || curModel.score(String(core)) < autoGarbage
            else { continue }
        }
        guard let out = convertWrong(w, src: cur, dst: t), out != w,
              let tLang = t.languageCode, let tModel = model(tLang) else { continue }
        let sAlt = tModel.score(out)
        guard pureFor || sAlt > autoPunctPlausible else { continue }
        guard sAlt - sTyped > autoMargin else { continue }
        if best == nil || sAlt > best!.2 { best = (t, out, sAlt) }
    }
    guard let b = best else {
        return nil
    }
    return (b.0, b.1)
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

    public init() {}

    /// Ends the run; the previous word can no longer join a correction.
    public mutating func reset() {
        word = ""; trail = ""; previous = nil
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
            let ended = Event.boundary(word: word, trail: trail)
            word = ""; trail = ""   // the previous word stays for the short-word rule
            return ended
        }
        guard s.count == 1, let c = s.first else { reset(); return .none }
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
        if !trail.isEmpty { trail.removeLast(); return }
        word = String(word.dropLast())
        if word.isEmpty { previous = nil }
    }

    /// The boundary word had no candidate: it breaks the chain of short words.
    public mutating func noCandidate() {
        previous = nil
    }

    /// Decides whether a candidate at a boundary is fixed now.
    /// - Parameters:
    ///   - raw: the word plus its trail, as typed.
    ///   - out: their conversion.
    ///   - cyrillic: the script of the conversion.
    /// - Returns: the correction, or nil when a short word waits for a neighbour.
    public mutating func plan(raw: String, out: String, cyrillic: Bool) -> Fix? {
        if wordBody(raw) >= 3 {
            // Long enough to trust alone. A pending short word right before it (the
            // "d ljhjut" case) is folded into the same correction.
            let swallow = previous.flatMap { !$0.committed && $0.cyrillic == cyrillic ? $0 : nil }
            previous = Previous(raw: raw, out: out, cyrillic: cyrillic, committed: true)
            let rawPrefix = swallow.map { $0.raw + " " } ?? ""   // "<raw> " before it
            return Fix(erase: rawPrefix.count + raw.count,
                       text: (swallow.map { $0.out + " " } ?? "") + out,
                       original: rawPrefix + raw)
        }
        if let p = previous, p.committed, p.cyrillic == cyrillic {
            // A short word right after a committed conversion of the same script.
            previous = Previous(raw: raw, out: out, cyrillic: cyrillic, committed: true)
            return Fix(erase: raw.count, text: out, original: raw)
        }
        // ponytail: one-neighbour lookback — a stack ("bp pf ghbdtn") fixes only the
        // last preposition; widen to a pending list if that ever matters.
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
