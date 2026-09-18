// Character-trigram language model for auto-mode wrong-layout detection.
//
// A word typed in the wrong keyboard layout produces character sequences that
// are improbable for the intended language (e.g. "ghbdtn" is junk in English).
// We score a word as the length-normalized mean log-probability of its character
// trigrams under a per-language model; the auto-mode decision compares the word
// as-typed against its converted form (see autoConvertTarget).
//
// Model data is generated offline (scripts/trigram/gen.py) from frequency word
// lists and shipped per language. Words are lowercased; each is padded with two
// leading "^" and one trailing "$" so word-initial and word-final patterns count.
//
// Pure, platform-free, no allocation-heavy work — fits the shared engine.

public struct TrigramModel {
    public let floor: Float                 // log-prob for an unseen trigram
    private let table: [String: Float]      // "abc" -> conditional log P(c | ab)

    public init(floor: Float, table: [String: Float]) {
        self.floor = floor
        self.table = table
    }

    // Parse the text model format:
    //   lines "# ..."        -> comments, ignored
    //   line  "floor <v>"    -> the unseen-trigram floor (required, first)
    //   lines "<trigram> <v>" -> one conditional log-prob each (trigram is 3 chars)
    public init?(text: String) {
        var floor: Float?
        var table: [String: Float] = [:]
        // isNewline, not "\n": in a CRLF file (a Windows checkout) "\r\n" is a single
        // Character, so splitting on "\n" alone would leave the file one long line.
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw
            while line.first == " " { line = line.dropFirst() }
            if line.isEmpty || line.first == "#" { continue }
            // Split on the LAST space — trigrams are letters + ^/$ only, never a space.
            guard let sp = line.lastIndex(of: " ") else { continue }
            let key = String(line[line.startIndex..<sp])
            guard let val = Float(line[line.index(after: sp)...]) else { continue }
            if key == "floor" { floor = val } else { table[key] = val }
        }
        guard let f = floor else { return nil }
        self.floor = f
        self.table = table
    }

    // Length-normalized mean trigram log-prob. Higher = more plausible in this
    // language. Returns `floor` for words too short to form a trigram.
    //
    // Hyphenated words are scored part by part (length-weighted): the models are
    // built from a plain word list, so every trigram spanning a hyphen is unseen
    // and three floor hits would sink "какого-то" below any gate.
    public func score(_ word: String) -> Float {
        guard word.contains(where: isWordConnector) else { return scoreRun(word) }
        let parts = word.split(whereSeparator: isWordConnector)
        guard !parts.isEmpty else { return floor }
        var sum: Float = 0, n = 0
        for p in parts { sum += scoreRun(String(p)) * Float(p.count); n += p.count }
        return sum / Float(n)
    }

    private func scoreRun(_ word: String) -> Float {
        let chars = Array("^^" + word.lowercased() + "$")
        guard chars.count >= 3 else { return floor }
        var sum: Float = 0
        var n = 0
        for i in 2..<chars.count {
            let tri = String(chars[(i - 2)...i])
            sum += table[tri] ?? floor
            n += 1
        }
        return n > 0 ? sum / Float(n) : floor
    }
}
