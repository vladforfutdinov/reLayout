// Reader for Apple `.strings` files, so the Windows port shows the same
// translations as the macOS app (Resources/<lang>.lproj/Localizable.strings).
// macOS itself reads them through Bundle; this parser is for platforms without it.

/// Parses `"key" = "value";` pairs. Handles `//` and `/* */` comments and the
/// escapes the shipped files use (`\"`, `\\`, `\n`, `\t`). Malformed entries are
/// skipped, never fatal.
public func parseStrings(_ text: String) -> [String: String] {
    var table: [String: String] = [:]
    var chars = Array(text)[...]

    func skipSpaceAndComments() {
        while let c = chars.first {
            if c.isWhitespace { chars.removeFirst(); continue }
            if c == "/", chars.dropFirst().first == "/" {
                while let n = chars.first, n != "\n" { chars.removeFirst() }
                continue
            }
            if c == "/", chars.dropFirst().first == "*" {
                chars.removeFirst(2)
                while !chars.isEmpty, !(chars.first == "*" && chars.dropFirst().first == "/") { chars.removeFirst() }
                chars = chars.dropFirst(2)
                continue
            }
            return
        }
    }

    func quoted() -> String? {
        guard chars.first == "\"" else { return nil }
        chars.removeFirst()
        var out = ""
        while let c = chars.popFirst() {
            if c == "\"" { return out }
            if c == "\\", let e = chars.popFirst() {
                switch e {
                case "n": out.append("\n")
                case "t": out.append("\t")
                default:  out.append(e)
                }
            } else {
                out.append(c)
            }
        }
        return nil   // unterminated
    }

    while true {
        skipSpaceAndComments()
        guard !chars.isEmpty else { break }
        guard let key = quoted() else { chars.removeFirst(); continue }
        skipSpaceAndComments()
        guard chars.first == "=" else { continue }
        chars.removeFirst()
        skipSpaceAndComments()
        guard let value = quoted() else { continue }
        skipSpaceAndComments()
        if chars.first == ";" { chars.removeFirst() }
        table[key] = value
    }
    return table
}
