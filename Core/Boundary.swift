/// What auto mode does at a word boundary (space or Tab after a word).
public enum BoundaryAction<L> {
    /// Leave the word: no candidate, a short word waiting for a neighbour, or the
    /// user just reverted a correction of it.
    case none
    /// Right text, wrong layout (a Ukrainian word on the Russian layout): switch only.
    case switchLayout(L)
    /// Retype: erase `fix.erase` characters, type `fix.text`, switch to `target`.
    case fix(AutoRun.Fix, target: L)
}

/// The decision a platform's auto decision chain returns (engine `autoDecision`).
public typealias AutoDecision<L> = (target: L, out: String, ambiguous: Bool, repaired: Bool)

/// Auto mode's whole word-boundary step, shared by both apps: learning from the
/// user's edits, the decision, the short-word chain, the switch-only case and the
/// fix plan. The platform then performs the returned action and saves `learned`
/// when it changed.
/// - Parameters:
///   - excluded: auto mode is off here (password field, excluded app); asked only
///     for a non-empty word.
///   - decide: the decision for a word, given the user's verdicts as they stand
///     after this boundary's lessons.
/// - Returns: the action, and the lessons applied (for the platform's trace).
public func evaluateBoundary<L: AutoLayout>(
    word: String, trail: String, cur: L, enabled: [L],
    run: inout AutoRun, edits: inout EditLearning<L>, learned: inout LearnedWords, chainTarget: inout L?,
    excluded: () -> Bool,
    decide: (_ word: String, _ verdict: @escaping (String) -> LearnedVerdict?) -> AutoDecision<L>?
) -> (action: BoundaryAction<L>, lessons: [EditLesson]) {
    // A non-word (a double space) or an excluded place breaks the chain, so a stale
    // short candidate cannot attach across the gap.
    guard !word.isEmpty, !excluded() else { run.noCandidate(); return (.none, []) }
    let lessons = edits.boundary(word, verdict: learned.verdict(learnedKey(word)))
    for lesson in lessons {
        switch lesson {
        case .keep(let key):
            learned.keep.insert(key)
            run.noCandidate()
            return (.none, lessons)
        case .dropKeep(let key):
            learned.keep.remove(key)
        case .convert(let key, let out):
            learned.promote(key, to: out)
        }
    }
    let verdicts = learned
    guard let d = decide(word, { verdicts.verdict($0) }) else {
        edits.leftAlone(word, cur: cur, enabled: enabled)
        // A short word the model reads as fine right after a chain word ("ot" in
        // "nf ot [fktgf") rides along with its reading in the chain's layout.
        if wordBody(word) <= 2, run.previous != nil, let t = chainTarget {
            run.bridge(raw: word + trail, out: transliterate(word + trail, from: cur, to: t))
        } else {
            run.noCandidate()
        }
        return (.none, lessons)
    }
    chainTarget = d.target
    if d.out == word {
        guard wordBody(word) >= 3 else { return (.none, lessons) }
        run.noCandidate()
        return (.switchLayout(d.target), lessons)
    }
    let outTrail = transliterate(trail, from: cur, to: d.target)
    // The short-word rule: a 1-2 letter word waits for a neighbour.
    guard let fix = run.plan(raw: word + trail, out: d.out + outTrail, cyrillic: d.target.isCyrillic,
                             trusted: learned.verdict(learnedKey(word)) == .convert, ambiguous: d.ambiguous)
    else { return (.none, lessons) }
    edits.corrected(word, into: d.out, from: cur, to: d.target)
    return (.fix(fix, target: d.target), lessons)
}

/// A key or click, by what it can do to the text before the caret.
public enum KeyRole {
    case text, backspace, forwardDelete
    /// Arrows, Home/End, Page Up/Down: move the caret, and select with Shift.
    case caretMove
    /// A Cmd/Ctrl shortcut: may cut, paste, undo or select.
    case command
    case click
    /// Esc, Insert, function keys.
    case other
}

/// Whether a key may delete or select text, so a correction can be undone by hand
/// after it: such a key arms learning by revert (`EditLearning.edit`).
public func mayEditText(_ role: KeyRole) -> Bool {
    switch role {
    case .backspace, .forwardDelete, .caretMove, .command, .click: return true
    case .text, .other: return false
    }
}

/// The fix for a word Return ended, made only once the field shows a new line.
/// A short word is left alone: across a line break no preposition attaches to it.
/// - Returns: what the field should show for `word + trail` (`original`) and the
///   layout to type it in; nil when the word is short, right or ambiguous.
public func enterFixPlan<L: LayoutMaps>(word: String, trail: String, cur: L,
                                        decide: (String) -> AutoDecision<L>?) -> (original: String, text: String, target: L)? {
    guard wordBody(word) >= 3, let d = decide(word), !d.ambiguous else { return nil }
    return (word + trail, d.out + transliterate(trail, from: cur, to: d.target), d.target)
}
