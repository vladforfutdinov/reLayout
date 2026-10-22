import WinSDK
import Foundation

// Diagnostics for DEBUG builds only (scripts/build-windows.ps1 -DebugLog): with
// HKCU\Software\reLayout\DebugLog = 1 it writes to %TEMP%\relayout-debug.log what
// reLayout sends (SendInput batches) and every key event the hook sees, real or
// injected. That records keystrokes, so a release build compiles it out entirely
// — the same rule as the macOS app's dbg().

#if DEBUG
private let debugEnabled = loadDebugLog()

private let logPath: String = {
    var buf = [WCHAR](repeating: 0, count: 512)
    let n = Int(GetTempPathW(DWORD(buf.count), &buf))
    return String(decoding: buf.prefix(n), as: UTF16.self) + "relayout-debug.log"
}()

func dlog(_ line: @autoclosure () -> String) {
    guard debugEnabled else { return }
    let t0 = GetTickCount64()
    append("\(GetTickCount()) \(line())\n")
    let ms = GetTickCount64() - t0
    if ms > 100 { append("\(GetTickCount()) slow log write: \(ms) ms\n") }
}

// Kept open: an antivirus scans the file on every close, which stalled the hook.
private let logHandle: FileHandle? = {
    if !FileManager.default.fileExists(atPath: logPath) {
        _ = FileManager.default.createFile(atPath: logPath, contents: nil)
    }
    let h = FileHandle(forWritingAtPath: logPath)
    h?.seekToEndOfFile()
    return h
}()

private func append(_ text: String) {
    guard let data = text.data(using: .utf8) else { return }
    logHandle?.write(data)
}

/// Marks an action of ours in the log (a fix, a hotkey).
func dwatch(_ reason: String) {
    dlog("action: \(reason)")
}

/// Logs one hook event; flags bit 0x10 = injected (sent by some program, us included).
func dlogHook(vk: UInt32, scan: UInt32, flags: UInt32, message: UInt) {
    guard debugEnabled else { return }
    dlog("hook msg=\(String(message, radix: 16)) vk=\(String(vk, radix: 16)) scan=\(String(scan, radix: 16)) flags=\(String(flags, radix: 16))")
}

func dlogStartup() {
    dlog("start: INPUT size=\(MemoryLayout<INPUT>.size) stride=\(MemoryLayout<INPUT>.stride) "
         + "KEYBDINPUT size=\(MemoryLayout<KEYBDINPUT>.size) "
         + "KBDLLHOOKSTRUCT size=\(MemoryLayout<KBDLLHOOKSTRUCT>.size)")
}
#else
@inline(__always) func dlog(_ line: @autoclosure () -> String) {}
@inline(__always) func dwatch(_ reason: String) {}
@inline(__always) func dlogHook(vk: UInt32, scan: UInt32, flags: UInt32, message: UInt) {}
@inline(__always) func dlogStartup() {}
#endif
