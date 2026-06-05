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

    init(_ hkl: HKL) {
        self.hkl = hkl
        // Low word of the HKL is the LANGID; use it as a stable id.
        let raw = UInt(bitPattern: Int(bitPattern: hkl))
        self.id = String(format: "%04x", UInt32(raw & 0xFFFF))
        build()
    }

    /// All installed keyboard layouts, in system order.
    static func installedList() -> [WinLayout] {
        let n = GetKeyboardLayoutList(0, nil)
        guard n > 0 else { return [] }
        var handles = [HKL?](repeating: nil, count: Int(n))
        let got = GetKeyboardLayoutList(n, &handles)
        var out: [WinLayout] = []
        for i in 0..<Int(got) where handles[i] != nil { out.append(WinLayout(handles[i]!)) }
        return out
    }

    /// Layout of the foreground window's input thread.
    static func current() -> WinLayout? {
        let tid = GetWindowThreadProcessId(GetForegroundWindow(), nil)
        guard let h = GetKeyboardLayout(tid) else { return nil }
        return WinLayout(h)
    }

    private func build() {
        // (mods index, shift?, altgr?) — simplest combo first so plain keys win.
        let combos: [(idx: UInt32, shift: Bool, altgr: Bool)] = [
            (0, false, false), (1, true, false), (2, false, true), (3, true, true),
        ]
        // ToUnicodeEx flag 0x4 (Win10 1607+): translate WITHOUT mutating the live
        // keyboard state — avoids the classic dead-key state corruption.
        let noChange: UINT = 0x4

        for vkInt in 0x20...0xFF {
            let vk = UINT(vkInt)
            let scan = MapVirtualKeyExW(vk, 0 /* MAPVK_VK_TO_VSC */, hkl)
            if scan == 0 { continue }
            for c in combos {
                var state = [BYTE](repeating: 0, count: 256)
                if c.shift { state[Int(VK_SHIFT)] = 0x80 }
                if c.altgr { state[Int(VK_CONTROL)] = 0x80; state[Int(VK_MENU)] = 0x80 }
                var buf = [WCHAR](repeating: 0, count: 8)
                let r = ToUnicodeEx(vk, scan, &state, &buf, 8, noChange, hkl)
                guard r > 0 else { continue }   // 0 = none, <0 = dead key: skip
                let s = String(utf16CodeUnits: buf, count: Int(r))
                guard let f = s.unicodeScalars.first, f.value >= 0x20 else { continue }
                let stroke = KeyStroke(keyCode: UInt16(vk), mods: c.idx)
                if strokeToChar[stroke] == nil { strokeToChar[stroke] = s }
                if charToStroke[s] == nil { charToStroke[s] = stroke }
            }
        }
        isCyrillic = strokeToChar.values.contains { $0.unicodeScalars.first.map(isCyrLetter) ?? false }
    }
}
