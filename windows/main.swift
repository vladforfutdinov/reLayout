import WinSDK
import ReLayoutCore

// Windows port — work in progress. This first cut validates the Win32 layout
// builder + the shared engine; the tray, hotkey, selection read (UI Automation),
// keystroke write (SendInput) and Settings UI come next.
//
// For now: list installed layouts and demo a conversion, so `swift build` on
// Windows CI compiles the WinSDK glue end-to-end.

let layouts = WinLayout.installedList()
print("installed layouts: \(layouts.map { "\($0.id)\($0.isCyrillic ? "(cyr)" : "")" })")

if layouts.count >= 2 {
    let src = layouts[0]
    let dst = layouts.first(where: { $0.isCyrillic != src.isCyrillic }) ?? layouts[1]
    let sample = "ghbdtn"
    print("convert \(sample.debugDescription) [\(src.id) -> \(dst.id)]: "
          + (convertWrong(sample, src: src, dst: dst) ?? "nil"))
} else {
    print("need >= 2 layouts to demo conversion")
}
