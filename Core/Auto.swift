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

