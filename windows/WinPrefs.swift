import WinSDK

// Small registry-backed preferences under HKCU\Software\reLayout. Currently the
// convert hotkey (modifiers + virtual-key), stored as two REG_DWORD values.

private let prefsHKCU = HKEY(bitPattern: 0x8000_0001)!
private let prefsSubKey   = "Software\\reLayout"
private let keyHotkeyMods = "HotkeyMods"
private let keyHotkeyVK   = "HotkeyVK"
private let keyTrayMode   = "TrayMode"

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

// Tray icon mode: 0 = static logo (default), 1 = live layout code (e.g. "EN").
func loadTrayMode() -> Int {
    Int(withPrefsKey(write: false) { readDword($0, keyTrayMode) } ?? 0)
}

func saveTrayMode(_ mode: Int) {
    _ = withPrefsKey(write: true) { key -> Bool in
        writeDword(key, keyTrayMode, DWORD(mode)); return true
    }
}
