#!/usr/bin/env swift
// Diagnostic for the doubled first letter after a Globe layout switch — docs/HISTORY.md,
// "the doubled first letter is macOS, not reLayout". Quit reLayout, run
// `swift scripts/keyspy.swift`, switch layouts with Globe while typing; a keyDown re-posted
// by TextInputSwitcher prints with "<<< INJECTED". Logs key codes and source pids only,
// never characters. Needs Input Monitoring for the terminal running it.
import Cocoa
setvbuf(stdout, nil, _IOLBF, 0)
var last: CGEventTimestamp = 0
let cb: CGEventTapCallBack = { _, type, e, _ in
    if type == .keyDown {
        let pid = e.getIntegerValueField(.eventSourceUnixProcessID)
        let kbd = e.getIntegerValueField(.keyboardEventKeyboardType)
        let code = e.getIntegerValueField(.keyboardEventKeycode)
        let dt = (e.timestamp &- last) / 1_000_000; last = e.timestamp
        let name = pid == 0 ? "" : (NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName ?? "?")
        print("\(Date()) dt=\(dt)ms code=\(code) pid=\(pid) kbd=\(kbd) rep=\(e.getIntegerValueField(.keyboardEventAutorepeat)) \(name)\(pid != 0 ? "  <<< INJECTED" : "")")
    }
    return Unmanaged.passUnretained(e)
}
guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
    eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue), callback: cb, userInfo: nil) else { print("tap failed"); exit(1) }
CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
print("listening"); CFRunLoopRun()
