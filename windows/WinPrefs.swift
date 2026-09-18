import WinSDK
import Foundation

// Small registry-backed preferences under HKCU\Software\reLayout. Currently the
// convert hotkey (modifiers + virtual-key), stored as two REG_DWORD values.

private let prefsHKCU = HKEY(bitPattern: 0x8000_0001)!
private let prefsSubKey   = "Software\\reLayout"
private let keyHotkeyMods = "HotkeyMods"
private let keyHotkeyVK   = "HotkeyVK"
private let keyDoubleTap  = "DoubleTap"
private let keyAutoMode   = "AutoCorrect"
private let keyAutoEnter  = "AutoCorrectOnEnter"
private let keyExcluded   = "AutoCorrectExcluded"
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

// Default convert hotkey: Ctrl+Alt+R.
let defaultHotkey: (mods: UINT, vk: UINT) = (UINT(MOD_CONTROL) | UINT(MOD_ALT), UINT(0x52))

func loadHotkey() -> (mods: UINT, vk: UINT) {
    withPrefsKey(write: false) { key -> (UINT, UINT)? in
        guard let m = readDword(key, keyHotkeyMods),
              let v = readDword(key, keyHotkeyVK), v != 0 else { return nil }
        return (UINT(m), UINT(v))
    } ?? defaultHotkey
}

func saveHotkey(mods: UINT, vk: UINT) {
    _ = withPrefsKey(write: true) { key -> Bool in
        writeDword(key, keyHotkeyMods, DWORD(mods))
        writeDword(key, keyHotkeyVK, DWORD(vk))
        return true
    }
}

// "Trigger on double-tap": fire only when the hotkey is pressed twice quickly.
private func readString(_ key: HKEY, _ name: String) -> String? {
    var buf = [WCHAR](repeating: 0, count: 4096)
    var cb = DWORD(buf.count * MemoryLayout<WCHAR>.size)
    let r = name.withCString(encodedAs: UTF16.self) { np in
        buf.withUnsafeMutableBytes {
            RegQueryValueExW(key, np, nil, nil, $0.bindMemory(to: BYTE.self).baseAddress, &cb)
        }
    }
    guard r == 0 else { return nil }
    return String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF16.self)
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
/// and editors by default — typing there is commands and code, not prose.
let defaultExcludedApps = [
    "cmd.exe", "powershell.exe", "pwsh.exe", "conhost.exe", "windowsterminal.exe",
    "wt.exe", "mintty.exe", "putty.exe", "alacritty.exe", "wezterm-gui.exe",
    "code.exe", "devenv.exe", "idea64.exe", "rider64.exe", "sublime_text.exe",
]

func loadExcludedApps() -> [String] {
    let stored = withPrefsKey(write: false, { readString($0, keyExcluded) })
    guard let stored else { return defaultExcludedApps }
    return stored.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                 .filter { !$0.isEmpty }
}

func saveExcludedApps(_ apps: [String]) {
    _ = withPrefsKey(write: true) { key -> Bool in
        writeString(key, keyExcluded, apps.joined(separator: "\r\n")); return true
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

func loadDoubleTap() -> Bool {
    (withPrefsKey(write: false) { readDword($0, keyDoubleTap) } ?? 0) != 0
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

func saveAutoMode(_ on: Bool) {
    _ = withPrefsKey(write: true) { key -> Bool in
        writeDword(key, keyAutoMode, on ? 1 : 0); return true
    }
}

func saveDoubleTap(_ on: Bool) {
    _ = withPrefsKey(write: true) { key -> Bool in
        writeDword(key, keyDoubleTap, on ? 1 : 0); return true
    }
}
