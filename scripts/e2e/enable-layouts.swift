// Enables installed keyboard layouts by input-source id, for e2e on a fresh machine
// (CI): `swift scripts/e2e/enable-layouts.swift com.apple.keylayout.Russian …`.
// Exits non-zero if one of them is not installed or not enabled afterwards.
import Carbon

let wanted = Set(CommandLine.arguments.dropFirst())
let filter = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource] as CFDictionary
let all = TISCreateInputSourceList(filter, true).takeRetainedValue() as! [TISInputSource]

func id(_ s: TISInputSource) -> String {
    Unmanaged<CFString>.fromOpaque(TISGetInputSourceProperty(s, kTISPropertyInputSourceID)).takeUnretainedValue() as String
}

var missing = wanted
for s in all where wanted.contains(id(s)) {
    let status = TISEnableInputSource(s)
    print("\(id(s)): enable status \(status)")
    if status == noErr { missing.remove(id(s)) }
}
let enabled = (TISCreateInputSourceList(filter, false).takeRetainedValue() as! [TISInputSource]).map(id)
print("enabled now: \(enabled)")
if !missing.isEmpty { print("not enabled: \(missing.sorted())"); exit(1) }
