// Cuts a take from scripts/demo-vm.sh into the final demo: the camera follows the
// scenario's markers (zoom into the focus rect, eased), the cursor and clicks are
// drawn from events.jsonl, real key presses show as keycaps (reLayout's own synthetic
// keys are left out), each scene gets a caption.
// usage: swift scripts/demo/render.swift TAKE_DIR OUT.mov [WIDTH]
import AVFoundation
import AppKit
import CoreImage

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: render.swift TAKE_DIR OUT.mov [WIDTH]"); exit(1) }
let take = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
let outW = args.count > 3 ? Int(args[3])! : 1600
let fps = 30.0

func jsonl(_ name: String) -> [[String: Any]] {
    ((try? String(contentsOf: take.appendingPathComponent(name), encoding: .utf8)) ?? "")
        .split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
}
let events = jsonl("events.jsonl")
guard let start = events.first, start["type"] as? String == "start" else { print("no start event"); exit(1) }
let screenW = start["w"] as! Double, screenH = start["h"] as! Double
let px = (start["pw"] as! Double) / screenW
let t0 = start["uptime"] as! Double
let outH = Int((Double(outW) * screenH / screenW / 2).rounded()) * 2
let outScale = Double(outW) / screenW

struct Shot { var t: Double; var center: CGPoint; var zoom: Double; var name: String }
let full = Shot(t: 0, center: CGPoint(x: screenW / 2, y: screenH / 2), zoom: 1, name: "")
var shots = [full]
for m in jsonl("markers.jsonl") {
    let t = ((m["uptime"] as! Double) - t0) / 1e9, name = m["name"] as! String
    if let r = m["rect"] as? [Double] {
        let fit = min(screenW / (r[2] * 1.12), screenH / (r[3] * 1.25))
        shots.append(Shot(t: t, center: CGPoint(x: r[0] + r[2] / 2, y: r[1] + r[3] / 2),
                          zoom: max(1, min(m["zoom"] as! Double, fit, r[1] < 30 ? 2.4 : 1.6)), name: name))
    } else {
        shots.append(Shot(t: t, center: full.center, zoom: 1, name: name))
    }
}
struct Pt { var t: Double; var p: CGPoint }
let pointer = events.filter { ["move", "drag", "down", "up"].contains($0["type"] as? String) }
    .map { Pt(t: $0["t"] as! Double, p: CGPoint(x: $0["x"] as! Double, y: $0["y"] as! Double)) }
let clicks = events.filter { $0["type"] as? String == "down" }.map { $0["t"] as! Double }
func cursorAt(_ t: Double) -> CGPoint? {
    guard let i = pointer.lastIndex(where: { $0.t <= t }) else { return pointer.first?.p }
    return pointer[i].p
}

let lead = 0.25
func ease(_ x: Double) -> Double { let x = min(max(x, 0), 1); return x * x * (3 - 2 * x) }
func clampView(_ c: CGPoint, _ z: Double) -> CGRect {
    let w = screenW / z, h = screenH / z
    return CGRect(x: min(max(c.x - w / 2, 0), screenW - w), y: min(max(c.y - h / 2, 0), screenH - h), width: w, height: h)
}
func fitZoom(_ r: CGRect) -> Double { max(1, min(screenW / r.width, screenH / r.height)) }

/// A mouse move that ends in a click: the camera shows the way, then the target.
struct Reach { var start: Double; var click: Double; var from: CGPoint; var to: CGPoint }
var reaches: [Reach] = []
do {
    var segStart: Pt?, last: Pt?
    for e in events {
        guard let type = e["type"] as? String, let t = e["t"] as? Double else { continue }
        let p = CGPoint(x: e["x"] as? Double ?? 0, y: e["y"] as? Double ?? 0)
        if type == "move" {
            if let l = last, t - l.t < 0.25 {} else { segStart = Pt(t: t, p: p) }
            last = Pt(t: t, p: p)
        } else if type == "down", let s = segStart, let l = last, t - l.t < 0.5 {
            reaches.append(Reach(start: s.t, click: t, from: s.p, to: p))
            segStart = nil
        }
    }
}

/// Where the camera wants to be at `t`: center and zoom. The scene's shot holds while
/// the mouse works inside it; a reach outside widens the shot just enough to take in
/// the way and the target (and a menu opening under a menu bar click).
func target(at t: Double) -> (CGPoint, Double) {
    let s = shots.last { $0.t - lead <= t } ?? full
    let view = clampView(s.center, s.zoom)
    guard let r = reaches.last(where: { $0.start - 0.15 <= t && t <= $0.click + 0.8 }) else { return (s.center, s.zoom) }
    // A click on the menu bar icon opens its menu (~160x100 pt, right of the click);
    // it stays in frame for that click and for the click on its item.
    let anchor = r.to.y < 30 ? r.to : reaches.last(where: { $0.click < r.click && r.click - $0.click < 3 && $0.to.y < 30 })?.to
    let need = CGRect(x: min(r.from.x, r.to.x), y: min(r.from.y, r.to.y),
                      width: abs(r.to.x - r.from.x), height: abs(r.to.y - r.from.y))
        .insetBy(dx: -60, dy: -40)

    if let a = anchor {
        let menu = CGRect(x: a.x - 70, y: 0, width: 260, height: 130).union(CGRect(origin: r.to, size: .zero).insetBy(dx: -40, dy: -30))
        let box = menu.insetBy(dx: -menu.width * 0.6, dy: -menu.height * 0.6)
        return (CGPoint(x: menu.midX, y: menu.midY), min(2.0, fitZoom(box)))
    }
    if view.insetBy(dx: view.width * 0.06, dy: view.height * 0.06).contains(need) { return (s.center, s.zoom) }
    let box = view.union(need)
    return (CGPoint(x: box.midX, y: box.midY), min(s.zoom, fitZoom(box)))
}

/// Camera state, advanced by a critically damped spring once per rendered frame.
var cam: (x: Double, y: Double, lz: Double, vx: Double, vy: Double, vz: Double, t: Double)?
/// Visible part of the screen at `t`, in points (top-left origin). Call with increasing `t`.
func view(at t: Double) -> CGRect {
    let (c, z) = target(at: t)
    let goal = clampView(c, z)
    let gx = goal.midX, gy = goal.midY, gz = log(z)
    guard var s = cam else { cam = (gx, gy, gz, 0, 0, 0, t); return goal }
    let w = 3.4, steps = 4, dt = min(t - s.t, 1 / fps) / Double(steps)   // a cut is one frame
    for _ in 0..<steps {
        s.vx += (w * w * (gx - s.x) - 2 * w * s.vx) * dt; s.x += s.vx * dt
        s.vy += (w * w * (gy - s.y) - 2 * w * s.vy) * dt; s.y += s.vy * dt
        s.vz += (w * w * (gz - s.lz) - 2 * w * s.vz) * dt; s.lz += s.vz * dt
    }
    s.t = t
    cam = s
    return clampView(CGPoint(x: s.x, y: s.y), exp(s.lz))
}

let labels: [Int: String] = [
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
    14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
    26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L",
    38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 49: "␣", 50: "`",
    51: "⌫", 53: "⎋", 125: "↓", 126: "↑", 123: "←", 124: "→",
]
struct Cap { var t: Double; var text: String; var hotkey: Bool }
var caps: [Cap] = []
var shiftDown: Double?, shiftUsed = false
for e in events where e["synth"] == nil {
    let type = e["type"] as? String, t = e["t"] as? Double ?? 0
    let code = e["code"] as? Int ?? -1, flags = CGEventFlags(rawValue: UInt64(e["flags"] as? Int ?? 0))
    if type == "flags", code == 56 || code == 60 {
        if flags.contains(.maskShift) { shiftDown = t; shiftUsed = false }
        else if let d = shiftDown, !shiftUsed, t - d < 0.4 { caps.append(Cap(t: t, text: "⇧", hotkey: true)) }
        if !flags.contains(.maskShift) { shiftDown = nil }
    } else if type == "keyDown" {
        shiftUsed = true
        var mods = ""
        if flags.contains(.maskControl) { mods += "⌃" }
        if flags.contains(.maskAlternate) { mods += "⌥" }
        if flags.contains(.maskCommand) { mods += "⌘" }
        let key = labels[code] ?? "?"
        caps.append(Cap(t: t, text: mods + key, hotkey: !mods.isEmpty && !flags.contains(.maskCommand)))
    }
}
// Only reLayout's hotkeys (Shift taps, ⌃⌥ combos) show; typing and ⌘ shortcuts stay off screen.
caps = caps.filter(\.hotkey)
/// The burst of keys on screen at `t`: keys less than a second apart, fading after the last.
func burst(at t: Double) -> (caps: [Cap], alpha: Double) {
    guard var i = caps.lastIndex(where: { $0.t <= t }) else { return ([], 0) }
    let end = i
    while i > 0, caps[i].t - caps[i - 1].t < 1.0 { i -= 1 }
    let age = t - caps[end].t
    return (Array(caps[max(i, end - 13)...end]), age < 1.1 ? 1 : max(0, 1 - (age - 1.1) / 0.3))
}

let captionText: [String: String] = [
    "hotkey": "Wrong layout? Tap Shift twice",
    "settings": "Settings",
    "nodot": "Auto-correct off: no dot on the icon",
    "dot": "Auto-correct on: a dot on the icon",
    "auto": "Auto-correct fixes it as you type",
    "learn": "Shift twice undoes a fix, and it is remembered",
    "learned": "Learned words",
    "terminal": "Terminals: reLayout stays out by default",
    "apps": "Per-app features: allow the hotkey in Terminal",
    "terminal2": "Now the hotkey works there",
    "off": "⌃⌥A: auto-correct off",
]
/// Caption text, its opacity, and whether it goes low (the shot looks at the menu bar).
/// A scene's caption fades out for good once the mouse heads for the menu bar.
func caption(at t: Double) -> (String, Double, Bool)? {
    guard let s = shots.last(where: { $0.t - lead <= t }), let text = captionText[s.name] else { return nil }
    let next = shots.first { $0.t > s.t }?.t ?? .infinity
    var a = min(ease((t - s.t + lead) / 0.3), ease((next - lead - t) / 0.3))
    if let r = reaches.first(where: { $0.to.y < 30 && $0.start > s.t - lead }) {
        a = min(a, ease((r.start - 0.15 - t) / 0.25))
    }
    return (text, a, s.center.y < 60)
}

/// The system arrow, captured in the VM by scripts/demo/cursor.swift (demo-vm.sh setup).
let cursorDir = take.deletingLastPathComponent()
guard let cursorSrc = CGImageSourceCreateWithURL(cursorDir.appendingPathComponent("cursor.png") as CFURL, nil),
      let cursorImage = CGImageSourceCreateImageAtIndex(cursorSrc, 0, nil),
      let cursorMeta = try? JSONSerialization.jsonObject(with: Data(contentsOf: cursorDir.appendingPathComponent("cursor.json"))) as? [String: Double]
else { print("no cursor.png/cursor.json next to the take: run scripts/demo-vm.sh setup"); exit(1) }
func drawPill(_ ctx: CGContext, _ rect: CGRect, fill: NSColor, radius: CGFloat) {
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(fill.cgColor); ctx.fillPath()
}
func textSize(_ s: String, _ font: NSFont) -> CGSize { (s as NSString).size(withAttributes: [.font: font]) }
func draw(_ s: String, at p: CGPoint, _ font: NSFont, _ color: NSColor) {
    (s as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: color])
}

func overlay(_ ctx: CGContext, t: Double, v: CGRect) {
    let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
    NSGraphicsContext.current = ns
    let k = Double(outW) / v.width
    func out(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - v.minX) * k, y: (p.y - v.minY) * k) }
    let H = Double(outH), W = Double(outW), u = W / 1600

    for c in clicks where t >= c && t < c + 0.45 {
        guard let p = cursorAt(c) else { continue }
        let q = out(p), f = (t - c) / 0.45, r = (10 + 26 * f) * u * min(k / outScale, 2)
        ctx.setStrokeColor(NSColor(calibratedRed: 0.35, green: 0.6, blue: 1, alpha: 0.9 * (1 - f)).cgColor)
        ctx.setLineWidth(3 * u)
        ctx.strokeEllipse(in: CGRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r))
    }
    if let p = cursorAt(t) {
        let q = out(p), s = 1.3 * min(k, outScale * 2.2)
        let w = cursorMeta["w"]! * s, h = cursorMeta["h"]! * s
        ctx.saveGState()
        ctx.translateBy(x: q.x - cursorMeta["hx"]! * s, y: q.y - cursorMeta["hy"]! * s + h); ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(cursorImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.restoreGState()
    }

    let (keys, alpha) = burst(at: t)
    if alpha > 0, !keys.isEmpty {
        let font = NSFont.systemFont(ofSize: 30 * u, weight: .semibold)
        let pad = 14 * u, gap = 8 * u, h = 54 * u
        let widths = keys.map { max(h, textSize($0.text, font).width + 2 * pad) }
        let total = widths.reduce(0, +) + gap * Double(keys.count - 1)
        var x = (W - total) / 2
        let y = H - h - 36 * u
        ctx.setAlpha(alpha)
        for (cap, w) in zip(keys, widths) {
            let r = CGRect(x: x, y: y, width: w, height: h)
            drawPill(ctx, r.offsetBy(dx: 0, dy: 3 * u), fill: NSColor(white: 0, alpha: 0.35), radius: 10 * u)
            drawPill(ctx, r, fill: cap.hotkey ? NSColor(calibratedRed: 0.2, green: 0.47, blue: 0.96, alpha: 0.95)
                                              : NSColor(white: 0.16, alpha: 0.92), radius: 10 * u)
            ctx.addPath(CGPath(roundedRect: r.insetBy(dx: u, dy: u), cornerWidth: 9 * u, cornerHeight: 9 * u, transform: nil))
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.28).cgColor); ctx.setLineWidth(1.5 * u); ctx.strokePath()
            let ts = textSize(cap.text, font)
            draw(cap.text, at: CGPoint(x: r.midX - ts.width / 2, y: r.midY - ts.height / 2), font, .white)
            x += w + gap
        }
        ctx.setAlpha(1)
    }

    if let (text, a, low) = caption(at: t), a > 0 {
        let font = NSFont.systemFont(ofSize: 30 * u, weight: .bold)
        let ts = textSize(text, font), padX = 26 * u, padY = 12 * u, h = ts.height + 2 * padY
        let r = CGRect(x: (W - ts.width) / 2 - padX, y: low ? H - h - 120 * u : 30 * u, width: ts.width + 2 * padX, height: h)
        ctx.setAlpha(a)
        drawPill(ctx, r, fill: NSColor(white: 1, alpha: 0.94), radius: r.height / 2)
        draw(text, at: CGPoint(x: r.minX + padX, y: r.minY + padY), font, NSColor(white: 0.08, alpha: 1))
        ctx.setAlpha(1)
    }
    NSGraphicsContext.current = nil
}

let asset = AVURLAsset(url: take.appendingPathComponent("screen.mov"))
let track = asset.tracks(withMediaType: .video)[0]
let reader = try AVAssetReader(asset: asset)
let readOut = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
reader.add(readOut)
reader.startReading()

try? FileManager.default.removeItem(at: outURL)
let writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: outW, AVVideoHeightKey: outH,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000],
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: outW, kCVPixelBufferHeightKey as String: outH,
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let ci = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
let firstShot = shots.dropFirst().first?.t ?? 0
let tStart = max(0, firstShot - 0.6)
// Ends on the last scene, before the "outro" marker zooms back out.
let tEnd = min(asset.duration.seconds - 0.1, shots.last { $0.name == "outro" }.map { $0.t - lead } ?? (shots.last?.t ?? 0) + 1.2)

var current: CIImage?
func nextSample() -> (Double, CIImage)? {
    guard let s = readOut.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(s) else { return nil }
    return (CMSampleBufferGetPresentationTimeStamp(s).seconds, CIImage(cvPixelBuffer: pb))
}
var upcoming = nextSample()
let H = Double(start["ph"] as! Double)
func ciRect(_ r: CGRect) -> CGRect { CGRect(x: r.minX * px, y: H - r.maxY * px, width: r.width * px, height: r.height * px) }

var n = 0
var t = tStart
// Dead time cut: reLayout builds its Settings window ~1.5 s after the menu click.
let cuts: [(Double, Double)] = clicks.compactMap { c in
    guard let next = shots.first(where: { $0.t > c }), next.name == "settings", next.t - c > 0.6,
          !clicks.contains(where: { $0 > c && $0 < next.t }) else { return nil }   // only after the item click
    return (c + 0.35, next.t - lead - 0.1)
}
while t <= tEnd {
    for c in cuts where t > c.0 && t < c.1 { t = c.1 }
    while let u = upcoming, u.0 <= t { current = u.1; upcoming = nextSample() }
    guard let img = current else { t += 1 / fps; continue }
    let v = view(at: t)
    while !input.isReadyForMoreMediaData { usleep(2000) }
    var pbOut: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pbOut)
    let pb = pbOut!
    let src = ciRect(v)
    let scaled = img.cropped(to: src)
        .transformed(by: CGAffineTransform(translationX: -src.minX, y: -src.minY))
        .transformed(by: CGAffineTransform(scaleX: Double(outW) / src.width, y: Double(outH) / src.height))
    ci.render(scaled, to: pb, bounds: CGRect(x: 0, y: 0, width: outW, height: outH), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    CVPixelBufferLockBaseAddress(pb, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: outW, height: outH, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.translateBy(x: 0, y: Double(outH)); ctx.scaleBy(x: 1, y: -1)
    overlay(ctx, t: t, v: v)
    CVPixelBufferUnlockBaseAddress(pb, [])
    adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(n), timescale: CMTimeScale(fps)))
    n += 1; t += 1 / fps
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print(writer.status == .completed ? "✓ \(outURL.path) — \(n) frames, \(outW)x\(outH)" : "failed: \(String(describing: writer.error))")
