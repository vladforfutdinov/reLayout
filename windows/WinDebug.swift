import WinSDK
import Foundation

// Opt-in diagnostics, off unless HKCU\Software\reLayout\DebugLog = 1. Writes to
// %TEMP%\relayout-debug.log what reLayout sends (SendInput batches) and every key
// event the hook sees, real or injected. That records keystrokes, so the flag is
// for troubleshooting only, set by hand and never by the app.

private let debugEnabled = loadDebugLog()

private let logPath: String = {
    var buf = [WCHAR](repeating: 0, count: 512)
    let n = Int(GetTempPathW(DWORD(buf.count), &buf))
    return String(decoding: buf.prefix(n), as: UTF16.self) + "relayout-debug.log"
}()

func dlog(_ line: @autoclosure () -> String) {
    guard debugEnabled else { return }
    let text = "\(GetTickCount()) \(line())\n"
    guard let data = text.data(using: .utf8) else { return }
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile(); h.write(data); h.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: data)
    }
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
