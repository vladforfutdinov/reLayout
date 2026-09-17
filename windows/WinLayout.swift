import WinSDK
import ReLayoutCore

// Windows counterpart of the macOS `Layout`: build char<->stroke maps for a
// keyboard layout (HKL) by probing ToUnicodeEx over every virtual key × modifier
// combo. Same idea as UCKeyTranslate on macOS — layout-driven, no hand tables.
//
// mods encoding (must match between any two layouts being converted):
//   0 = none, 1 = Shift, 2 = AltGr (Ctrl+Alt), 3 = Shift+AltGr
final class WinLayout: LayoutMaps {
    let hkl: HKL
    let id: String
    private(set) var charToStroke: [String: KeyStroke] = [:]
    private(set) var strokeToChar: [KeyStroke: String] = [:]
    private(set) var isCyrillic = false

    private init(_ hkl: HKL) {
        self.hkl = hkl
        // Full HKL, not just its LANGID: two layouts of one language must differ.
        self.id = String(UInt(bitPattern: hkl), radix: 16)
        build()
    }

    /// Human-readable language name for this layout (e.g. "Ukrainian", "English"),
    /// derived from the LANGID. Falls back to the hex id if lookup fails.
    var displayName: String {
        let lcid = DWORD(UInt(bitPattern: hkl) & 0xFFFF)
        var loc = [WCHAR](repeating: 0, count: 85)   // LOCALE_NAME_MAX_LENGTH
        guard LCIDToLocaleName(lcid, &loc, Int32(loc.count), 0) > 0 else { return id }
        var disp = [WCHAR](repeating: 0, count: 128)
        let m = GetLocaleInfoEx(&loc, DWORD(0x6f /* LOCALE_SLOCALIZEDLANGUAGENAME */), &disp, Int32(disp.count))
        return m > 1 ? String(decoding: disp.prefix(Int(m - 1)), as: UTF16.self) : id
    }

    // Maps are built once per HKL: ~900 ToUnicodeEx calls each, on the hook's thread.
    private static var cache: [UInt: WinLayout] = [:]

    private static func of(_ hkl: HKL) -> WinLayout {
        let key = UInt(bitPattern: hkl)
        if let l = cache[key] { return l }
        let l = WinLayout(hkl)
        cache[key] = l
        return l
    }

    /// All installed keyboard layouts, in system order.
    static func installedList() -> [WinLayout] {
        let n = GetKeyboardLayoutList(0, nil)
        guard n > 0 else { return [] }
        var handles = [HKL?](repeating: nil, count: Int(n))
        let got = GetKeyboardLayoutList(n, &handles)
        var out: [WinLayout] = []
        for i in 0..<Int(got) where handles[i] != nil { out.append(of(handles[i]!)) }
        return out
    }

    /// Layout of the focused window's input thread.
    static func current() -> WinLayout? {
        guard let focus = focusWindow() else { return nil }
        let tid = GetWindowThreadProcessId(focus, nil)
        guard let h = GetKeyboardLayout(tid) else { return nil }
        return of(h)
    }

    private func build() {
        // (mods index, shift?, altgr?) — simplest combo first so plain keys win.
        let combos: [(idx: UInt32, shift: Bool, altgr: Bool)] = [
            (0, false, false), (1, true, false), (2, false, true), (3, true, true),
        ]
        // ToUnicodeEx flag 0x4 (Win10 1607+): translate WITHOUT mutating the live
        // keyboard state — avoids the classic dead-key state corruption.
        let noChange: UINT = 0x4

        // Numpad VKs (0x60-0x6F) are skipped: they precede the OEM keys and would
        // claim `.`/`,`/`/` with their own, layout-independent meaning.
        let keys: [(vk: UINT, scan: UINT)] = (0x20...0xFF).compactMap { (v: Int) -> (vk: UINT, scan: UINT)? in
            guard !(0x60...0x6F).contains(v) else { return nil }
            let scan = MapVirtualKeyExW(UINT(v), 0 /* MAPVK_VK_TO_VSC */, hkl)
            return scan == 0 ? nil : (vk: UINT(v), scan: scan)
        }
        for c in combos {
            var state = [BYTE](repeating: 0, count: 256)
            if c.shift { state[Int(VK_SHIFT)] = 0x80 }
            if c.altgr { state[Int(VK_CONTROL)] = 0x80; state[Int(VK_MENU)] = 0x80 }
            for k in keys {
                var buf = [WCHAR](repeating: 0, count: 8)
                let r = ToUnicodeEx(k.vk, k.scan, state, &buf, 8, noChange, hkl)
                guard r > 0 else { continue }   // 0 = none, <0 = dead key: skip
                let s = String(decoding: buf.prefix(Int(r)), as: UTF16.self)
                guard let f = s.unicodeScalars.first, f.value >= 0x20 else { continue }
                let stroke = KeyStroke(keyCode: UInt16(k.vk), mods: c.idx)
                if strokeToChar[stroke] == nil { strokeToChar[stroke] = s }
                if charToStroke[s] == nil { charToStroke[s] = stroke }
            }
        }
        isCyrillic = strokeToChar.values.contains { $0.unicodeScalars.first.map(isCyrLetter) ?? false }
    }
}
