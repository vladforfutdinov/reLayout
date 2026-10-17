import RelayoutNative

// Swift side of the system spell checker (windows/native): the engine's
// `SpellCheck` and `SpellGuesses` for the auto-correct spell-check option.

/// Whether `w` is spelled right in `lang` (2-letter code); nil without a dictionary.
func isWord(_ w: String, _ lang: String) -> Bool? {
    let r = lang.withCString(encodedAs: UTF16.self) { l in
        w.withCString(encodedAs: UTF16.self) { relayout_spell_check(l, $0) }
    }
    return r < 0 ? nil : r == 1
}

/// The spell checker's suggestions for `w` in `lang`; empty without a dictionary.
func spellGuesses(_ w: String, _ lang: String) -> [String] {
    var buf = [UInt16](repeating: 0, count: 1024)
    let n = lang.withCString(encodedAs: UTF16.self) { l in
        w.withCString(encodedAs: UTF16.self) { word in
            buf.withUnsafeMutableBufferPointer { relayout_spell_suggest(l, word, $0.baseAddress, Int32($0.count)) }
        }
    }
    guard n > 0 else { return [] }
    return String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF16.self)
        .split(separator: "\n").map(String.init)
}

/// True when a system dictionary exists for some installed layout's language —
/// what the Settings spell-check option needs to be offered.
func hasSpellDictionary(_ layouts: [WinLayout]) -> Bool {
    layouts.contains { l in
        l.languageCode.map { code in code.withCString(encodedAs: UTF16.self) { relayout_spell_supported($0) } == 1 }
            ?? false
    }
}

/// Opens the dictionaries for `langs` now: the first check of a language loads its
/// dictionary, which must not happen inside the keyboard hook's time limit.
func warmSpellCheckers(_ langs: [String]) {
    for l in langs { _ = l.withCString(encodedAs: UTF16.self) { relayout_spell_supported($0) } }
}
