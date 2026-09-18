import WinSDK
import Foundation
import ReLayoutCore

// UI strings, from the same Localizable.strings the macOS app ships — CI copies
// Resources/<lang>.lproj next to the exe as lang/<lang>.lproj. The language
// follows Windows unless Settings overrides it; a switch applies live.

enum WinLoc {
    private static var table: [String: String] = [:]
    private static var english: [String: String] = [:]

    private static var root: String { "\(exeDirectory())\\lang" }

    /// Shipped languages as (code, own name), sorted by name.
    static let languages: [(code: String, name: String)] = {
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: "\(exeDirectory())\\lang")) ?? []
        return dirs.filter { $0.hasSuffix(".lproj") }
            .map { dir -> (code: String, name: String) in
                let code = String(dir.dropLast(".lproj".count))
                let raw = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
                return (code, raw.prefix(1).uppercased() + raw.dropFirst())
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }()

    /// (Re)loads the table for the override, else the Windows UI language.
    static func load() {
        english = read("en")
        table = read(loadLanguage() ?? systemLanguage())
    }

    static func string(_ key: String) -> String {
        table[key] ?? english[key] ?? key
    }

    private static func read(_ code: String) -> [String: String] {
        let path = "\(root)\\\(code).lproj\\Localizable.strings"
        return (try? String(contentsOfFile: path, encoding: .utf8)).map(parseStrings) ?? [:]
    }

    /// The Windows display language mapped onto a shipped one ("ru-RU" -> "ru",
    /// "zh-CN" -> "zh-Hans"); English when nothing matches.
    private static func systemLanguage() -> String {
        var buf = [WCHAR](repeating: 0, count: 85)   // LOCALE_NAME_MAX_LENGTH
        let n = LCIDToLocaleName(DWORD(GetUserDefaultUILanguage()), &buf, Int32(buf.count), 0)
        guard n > 1 else { return "en" }
        let name = String(decoding: buf.prefix(Int(n - 1)), as: UTF16.self)
        let codes = languages.map(\.code)
        if codes.contains(name) { return name }
        let base = String(name.prefix(while: { $0 != "-" }))
        if base == "zh" { return "zh-Hans" }
        return codes.contains(base) ? base : "en"
    }
}

/// Localized UI string; `%@` in it is replaced by `arg`.
func L(_ key: String, _ arg: String? = nil) -> String {
    let s = WinLoc.string(key)
    return arg.map { s.replacingOccurrences(of: "%@", with: $0) } ?? s
}
