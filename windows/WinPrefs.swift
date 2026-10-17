import WinSDK
import Foundation
import ReLayoutCore

// Small registry-backed preferences under HKCU\Software\reLayout.

private let prefsHKCU = HKEY(bitPattern: 0x8000_0001)!
private let prefsSubKey   = "Software\\reLayout"
private let keyHotkeyMods = "HotkeyMods"
private let keyHotkeyVK   = "HotkeyVK"
private let keyDoubleTap  = "DoubleTap"
private let keyAutoHotkeyMods = "AutoHotkeyMods"
private let keyAutoHotkeyVK   = "AutoHotkeyVK"
private let keyAutoHotkeyDoubleTap = "AutoHotkeyDoubleTap"
private let keyAutoMode   = "AutoCorrect"
private let keyAutoEnter  = "AutoCorrectOnEnter"
private let keyAutoSameScript = "AutoCorrectSameScript"
private let keyLearned    = "AutoCorrectLearned"
private let keyKept       = "AutoCorrectKept"
private let keyLearnCounts = "AutoCorrectLearnCounts"
private let keyLearnCandidates = "AutoCorrectLearnCandidates"
private let keyExcluded   = "AutoCorrectExcluded"
private let keyExcludedSeen = "AutoCorrectExcludedDefaultsSeen"
private let keyLanguage   = "Language"

private let kKeyQuery: REGSAM = 0x0001   // KEY_QUERY_VALUE
private let kKeySet:   REGSAM = 0x0002   // KEY_SET_VALUE

private func withPrefsKey<T>(write: Bool, _ body: (HKEY) -> T?) -> T? {
    var key: HKEY?
    let r = prefsSubKey.withCString(encodedAs: UTF16.self) { sub in
        if write {
            return RegCreateKeyExW(prefsHKCU, sub, 0, nil, 0, kKeySet | kKeyQuery, nil, &key, nil)
        }
        return RegOpenKeyExW(prefsHKCU, sub, 0, kKeyQuery, &key)
    }
    guard r == 0, let key else { return nil }   // 0 == ERROR_SUCCESS
    defer { RegCloseKey(key) }
    return body(key)
}

private func readDword(_ key: HKEY, _ name: String) -> DWORD? {
    var data: DWORD = 0
    var cb = DWORD(MemoryLayout<DWORD>.size)
    let r = name.withCString(encodedAs: UTF16.self) { np in
        withUnsafeMutablePointer(to: &data) { dp in
            dp.withMemoryRebound(to: BYTE.self, capacity: MemoryLayout<DWORD>.size) { bp in
                RegQueryValueExW(key, np, nil, nil, bp, &cb)
            }
        }
    }
    return r == 0 ? data : nil
}

private func writeDword(_ key: HKEY, _ name: String, _ value: DWORD) {
    var v = value
    name.withCString(encodedAs: UTF16.self) { np in
        withUnsafeBytes(of: &v) { raw in
            _ = RegSetValueExW(key, np, 0, DWORD(4 /* REG_DWORD */),
                               raw.bindMemory(to: BYTE.self).baseAddress,
                               DWORD(MemoryLayout<DWORD>.size))
        }
    }
}

private func hotkeyValueNames(_ slot: HotkeySlot) -> (mods: String, vk: String, doubleTap: String) {
    switch slot {
    case .retype:     return (keyHotkeyMods, keyHotkeyVK, keyDoubleTap)
    case .autoToggle: return (keyAutoHotkeyMods, keyAutoHotkeyVK, keyAutoHotkeyDoubleTap)
    }
}

/// Convert: Ctrl+Alt+R. Auto-correct on/off: unset.
func defaultHotkey(_ slot: HotkeySlot) -> Hotkey {
    slot == .retype ? Hotkey(mods: UINT(MOD_CONTROL) | UINT(MOD_ALT), vk: UINT(0x52)) : Hotkey.none
}

func loadHotkey(_ slot: HotkeySlot) -> Hotkey {
    let names = hotkeyValueNames(slot)
    return withPrefsKey(write: false) { key -> Hotkey? in
        guard let m = readDword(key, names.mods),
              let v = readDword(key, names.vk), v != 0 else { return nil }
        return Hotkey(mods: UINT(m), vk: UINT(v), doubleTap: (readDword(key, names.doubleTap) ?? 0) != 0)
    } ?? defaultHotkey(slot)
}

func saveHotkey(_ slot: HotkeySlot, _ hk: Hotkey) {
    let names = hotkeyValueNames(slot)
    _ = withPrefsKey(write: true) { key -> Bool in
        writeDword(key, names.mods, DWORD(hk.mods))
        writeDword(key, names.vk, DWORD(hk.vk))
        writeDword(key, names.doubleTap, hk.doubleTap ? 1 : 0)
        return true
    }
}

private func readString(_ key: HKEY, _ name: String) -> String? {
    var buf = [WCHAR](repeating: 0, count: 4096)
    while true {
        var cb = DWORD(buf.count * MemoryLayout<WCHAR>.size)
        let r = name.withCString(encodedAs: UTF16.self) { np in
            buf.withUnsafeMutableBytes {
                RegQueryValueExW(key, np, nil, nil, $0.bindMemory(to: BYTE.self).baseAddress, &cb)
            }
        }
        // ERROR_MORE_DATA (the learned words outgrow the buffer): cb holds the size needed.
        if r == 234 { buf = [WCHAR](repeating: 0, count: Int(cb) / 2 + 1); continue }
        guard r == 0 else { return nil }
        return String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF16.self)
    }
}

private func writeString(_ key: HKEY, _ name: String, _ value: String) {
    name.withCString(encodedAs: UTF16.self) { np in
        let units = Array(value.utf16) + [0]
        units.withUnsafeBytes { raw in
            _ = RegSetValueExW(key, np, 0, DWORD(1 /* REG_SZ */),
                               raw.bindMemory(to: BYTE.self).baseAddress, DWORD(raw.count))
        }
    }
}

/// Programs where auto-correct stays off, one executable name per line. Terminals
/// and editors by default — typing there is commands and code, not prose — and
/// virtual machines and remote desktops, where it goes to another system with its
/// own layout.
let defaultExcludedApps = [
    "cmd.exe", "powershell.exe", "pwsh.exe", "conhost.exe", "windowsterminal.exe",
    "wt.exe", "mintty.exe", "putty.exe", "alacritty.exe", "wezterm-gui.exe",
    "code.exe", "devenv.exe", "idea64.exe", "rider64.exe", "sublime_text.exe",
    "vmconnect.exe", "vmware.exe", "virtualboxvm.exe", "mstsc.exe", "msrdc.exe",
]
// The defaults a list saved before the "seen" record existed already reflects.
private let firstDefaultExcludedApps = Array(defaultExcludedApps.prefix(15))

private func splitLines(_ s: String) -> [String] {
    s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
     .filter { !$0.isEmpty }
}

/// The saved list, plus defaults introduced since it was saved (once each: one the
/// user removed stays removed — see the engine's mergeExclusions).
func loadExcludedApps() -> [String] {
    let stored = withPrefsKey(write: false, { readString($0, keyExcluded) })
    guard let stored else { return defaultExcludedApps }
    let seen = withPrefsKey(write: false, { readString($0, keyExcludedSeen) }).map(splitLines) ?? firstDefaultExcludedApps
    let merged = mergeExclusions(saved: splitLines(stored), defaults: defaultExcludedApps, seen: Set(seen))
    if Set(seen) != Set(defaultExcludedApps) { saveExcludedApps(merged) }
    return merged
}

func saveExcludedApps(_ apps: [String]) {
    _ = withPrefsKey(write: true) { key -> Bool in
        writeString(key, keyExcluded, apps.joined(separator: "\r\n"))
        writeString(key, keyExcludedSeen, defaultExcludedApps.joined(separator: "\r\n"))
        return true
    }
}

/// UI language override ("ru", "zh-Hans"); nil follows the system.
func loadLanguage() -> String? {
    let code = withPrefsKey(write: false, { readString($0, keyLanguage) })
    return (code?.isEmpty ?? true) ? nil : code
}

func saveLanguage(_ code: String?) {
    _ = withPrefsKey(write: true) { key -> Bool in
        writeString(key, keyLanguage, code ?? ""); return true
    }
}

#if DEBUG
/// Troubleshooting log (WinDebug.swift, DEBUG builds); set by hand in the registry.
func loadDebugLog() -> Bool {
    (withPrefsKey(write: false) { readDword($0, "DebugLog") } ?? 0) != 0
}
#endif

/// The release tag the tray last announced, so each version is announced once.
func loadNotifiedUpdate() -> String? {
    withPrefsKey(write: false, { readString($0, "UpdateNotified") })
}

func saveNotifiedUpdate(_ tag: String) {
    _ = withPrefsKey(write: true) { key -> Bool in writeString(key, "UpdateNotified", tag); return true }
}

func loadAutoMode() -> Bool {
    (withPrefsKey(write: false) { readDword($0, keyAutoMode) } ?? 0) != 0
}

/// Defaults to on, like macOS — it only acts while auto-correct itself is on.
func loadAutoEnter() -> Bool {
    (withPrefsKey(write: false) { readDword($0, keyAutoEnter) } ?? 1) != 0
}

func saveAutoEnter(_ on: Bool) {
    _ = withPrefsKey(write: true) { key -> Bool in
        writeDword(key, keyAutoEnter, on ? 1 : 0); return true
    }
}

/// Experimental same-script correction (ru <-> uk); default off.
func loadAutoSameScript() -> Bool {
    (withPrefsKey(write: false) { readDword($0, keyAutoSameScript) } ?? 0) != 0
}

func saveAutoSameScript(_ on: Bool) {
    _ = withPrefsKey(write: true) { key -> Bool in
        writeDword(key, keyAutoSameScript, on ? 1 : 0); return true
    }
}

/// A typed form -> conversion map, one `typed\tout` per line.
private func loadPairs(_ name: String) -> [String: String] {
    var map: [String: String] = [:]
    for line in (withPrefsKey(write: false, { readString($0, name) }) ?? "").split(separator: "\n") {
        let p = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        map[String(p[0])] = p.count > 1 ? String(p[1]) : ""
    }
    return map
}

private func savePairs(_ name: String, _ map: [String: String]) {
    _ = withPrefsKey(write: true) { key -> Bool in
        writeString(key, name, map.map { "\($0.key)\t\($0.value)" }.sorted().joined(separator: "\n"))
        return true
    }
}

/// The user's hotkey verdicts: typed form -> its conversion.
func loadLearned() -> [String: String] { loadPairs(keyLearned) }
func saveLearned(_ map: [String: String]) { savePairs(keyLearned, map) }

/// Counted, not yet promoted hotkey corrections: typed form -> its conversion.
func loadLearnCandidates() -> [String: String] { loadPairs(keyLearnCandidates) }
func saveLearnCandidates(_ map: [String: String]) { savePairs(keyLearnCandidates, map) }

/// Hotkey corrections counted toward a `convert` verdict: "typed<TAB>n" per line.
func loadLearnCounts() -> [String: Int] {
    var map: [String: Int] = [:]
    for line in (withPrefsKey(write: false, { readString($0, keyLearnCounts) }) ?? "").split(separator: "\n") {
        let p = line.split(separator: "\t", maxSplits: 1)
        if p.count == 2, let n = Int(p[1]) { map[String(p[0])] = n }
    }
    return map
}

func saveLearnCounts(_ map: [String: Int]) {
    _ = withPrefsKey(write: true) { key -> Bool in
        writeString(key, keyLearnCounts, map.map { "\($0.key)\t\($0.value)" }.sorted().joined(separator: "\n"))
        return true
    }
}

/// Typed forms whose auto-correction the user undid, one per line.
func loadKept() -> [String] {
    (withPrefsKey(write: false, { readString($0, keyKept) }) ?? "").split(separator: "\n").map(String.init)
}

func saveKept(_ words: [String]) {
    _ = withPrefsKey(write: true) { key -> Bool in
        writeString(key, keyKept, words.joined(separator: "\n")); return true
    }
}

func saveAutoMode(_ on: Bool) {
    _ = withPrefsKey(write: true) { key -> Bool in
        writeDword(key, keyAutoMode, on ? 1 : 0); return true
    }
}
