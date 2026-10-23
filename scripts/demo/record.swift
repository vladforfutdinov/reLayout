// Records the main display for the demo video: OUT/screen.mov without the cursor,
// and OUT/events.jsonl with every key, modifier, click, move and scroll, timed in
// seconds from the first recorded frame — the cursor and key overlay are drawn in
// post from it. Keys reLayout types itself carry "synth":true.
// usage: demo-record OUT_DIR   (stop with SIGINT/SIGTERM)
// Needs Screen Recording and Accessibility (or Input Monitoring); run in the GUI session.
import Cocoa
import ScreenCaptureKit

setvbuf(stdout, nil, _IOLBF, 0)
let dir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let logURL = dir.appendingPathComponent("events.jsonl")
FileManager.default.createFile(atPath: logURL.path, contents: nil)
let log = try FileHandle(forWritingTo: logURL)
let synthMarker: Int64 = 0x52_4C_41_59   // AppController.synthMarker in macos/main.swift
var t0: UInt64 = 0

func emit(_ fields: [String: Any]) {
    guard t0 != 0 else { return }
    var d = fields
    d["t"] = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e9
    guard var line = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) else { return }
    line.append(0x0A)
    log.write(line)
}

let names: [CGEventType: String] = [
    .keyDown: "keyDown", .keyUp: "keyUp", .flagsChanged: "flags", .mouseMoved: "move",
    .leftMouseDown: "down", .leftMouseUp: "up", .leftMouseDragged: "drag",
    .rightMouseDown: "rdown", .rightMouseUp: "rup", .rightMouseDragged: "drag", .scrollWheel: "scroll",
]
var tap: CFMachPort?
let callback: CGEventTapCallBack = { _, type, e, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(e)
    }
    guard let name = names[type] else { return Unmanaged.passUnretained(e) }
    let p = e.location
    var d: [String: Any] = ["type": name, "x": p.x, "y": p.y, "flags": e.flags.rawValue]
    if [.keyDown, .keyUp, .flagsChanged].contains(type) {
        d["code"] = e.getIntegerValueField(.keyboardEventKeycode)
        var len = 0
        var buf = [UniChar](repeating: 0, count: 8)
        e.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &len, unicodeString: &buf)
        if len > 0 { d["chars"] = String(utf16CodeUnits: buf, count: len) }
        if e.getIntegerValueField(.keyboardEventAutorepeat) != 0 { d["repeat"] = true }
    }
    if type == .scrollWheel {
        d["dy"] = e.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        d["dx"] = e.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
    }
    if e.getIntegerValueField(.eventSourceUserData) == synthMarker { d["synth"] = true }
    emit(d)
    return Unmanaged.passUnretained(e)
}
let mask = names.keys.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                eventsOfInterest: mask, callback: callback, userInfo: nil) else {
    print("event tap failed: grant Accessibility / Input Monitoring"); exit(1)
}
tap = t
CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)

final class Recorder: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) { print("stream stopped: \(error)") }
    var stream: SCStream?
    var size: [String: Any] = [:]
    func recordingOutputDidStartRecording(_ out: SCRecordingOutput) {
        t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        emit(["type": "start", "uptime": t0].merging(size) { a, _ in a })
        print("recording → \(dir.path)")
    }
    func recordingOutput(_ out: SCRecordingOutput, didFailWithError error: Error) {
        print("recording failed: \(error)"); exit(1)
    }
    func recordingOutputDidFinishRecording(_ out: SCRecordingOutput) {
        try? log.synchronize()
        print("saved at \(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e9) s"); exit(0)
    }
}
let recorder = Recorder()

Task {
    do {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
        else { print("no display"); exit(1) }
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let pw = mode?.pixelWidth ?? display.width, ph = mode?.pixelHeight ?? display.height
        recorder.size = ["w": display.width, "h": display.height, "pw": pw, "ph": ph]
        let cfg = SCStreamConfiguration()
        cfg.width = pw
        cfg.height = ph
        cfg.showsCursor = false
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.queueDepth = 6
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: recorder)
        let rc = SCRecordingOutputConfiguration()
        rc.outputURL = dir.appendingPathComponent("screen.mov")
        rc.outputFileType = .mov
        rc.videoCodecType = .h264
        try stream.addRecordingOutput(SCRecordingOutput(configuration: rc, delegate: recorder))
        try await stream.startCapture()
        recorder.stream = stream
    } catch {
        print("capture failed: \(error) (Screen Recording granted?)"); exit(1)
    }
}

let signalSources = [SIGINT, SIGTERM].map { sig in
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        guard let stream = recorder.stream else { exit(0) }
        Task { try? await stream.stopCapture() }
    }
    src.resume()
    return src
}
CFRunLoopRun()
