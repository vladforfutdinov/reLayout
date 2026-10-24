// Plays the demo scenario in the VM's GUI session: types like a person (physical
// US key positions, the active layout makes the letters), moves and clicks the
// mouse on controls found over Accessibility. Writes MARKERS (jsonl: uptime ns,
// scene name, focus rect in global points) for the camera in post.
// usage: demo-scenario prep | demo-scenario run MARKERS
import Cocoa
import Carbon

setvbuf(stdout, nil, _IOLBF, 0)
let relayoutID = "com.example.relayout.dev"
let src = CGEventSource(stateID: .hidSystemState)
func pause(_ s: Double) { usleep(useconds_t(s * 1_000_000)) }

var markers: FileHandle?
/// `hold`: seconds to wait after the marker, so the scene's caption can be read before the action.
func mark(_ name: String, _ rect: CGRect? = nil, zoom: Double = 1, hold: Double = 0) {
    defer { pause(hold) }
    var d: [String: Any] = ["uptime": clock_gettime_nsec_np(CLOCK_UPTIME_RAW), "name": name, "zoom": zoom]
    if let r = rect { d["rect"] = [r.minX, r.minY, r.width, r.height] }
    if var line = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) {
        line.append(0x0A); markers?.write(line)
    }
    print("▶ \(name)")
}

let codes: [Character: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
    "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
    "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
    "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
    ".": 47, "`": 50, " ": 49, "\n": 36,
]
let shifted: [Character: Character] = [":": ";", "?": "/", "!": "1", "_": "-", "\"": "'"]
let modCode: [(CGEventFlags, CGKeyCode)] = [(.maskControl, 59), (.maskAlternate, 58), (.maskCommand, 55), (.maskShift, 56)]

func post(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
    let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!
    e.flags = flags
    e.post(tap: .cghidEventTap)
}
func modifiers(_ flags: CGEventFlags, down: Bool) {
    var held: CGEventFlags = down ? [] : flags
    for (f, code) in (down ? modCode : modCode.reversed()) where flags.contains(f) {
        if down { held.insert(f) } else { held.remove(f) }
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!
        e.type = .flagsChanged; e.flags = held
        e.post(tap: .cghidEventTap)
        pause(0.03)
    }
}
func press(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
    modifiers(flags, down: true)
    post(code, down: true, flags: flags); pause(0.04)
    post(code, down: false, flags: flags)
    modifiers(flags, down: false)
}
/// Physical keys as on a US keyboard; uppercase and `shifted` symbols add Shift.
func type(_ s: String, speed: Double = 1) {
    for ch in s {
        var flags: CGEventFlags = []
        var base = ch
        if let b = shifted[ch] { base = b; flags = .maskShift }
        else if ch.isUppercase { base = Character(ch.lowercased()); flags = .maskShift }
        guard let code = codes[base] else { print("no key for \(ch)"); continue }
        press(code, flags)
        pause((ch == " " ? 0.16 : 0.09 + Double.random(in: 0...0.06)) / speed)
    }
}
func shiftTwice() {
    for _ in 0..<2 {
        let d = CGEvent(keyboardEventSource: src, virtualKey: 56, keyDown: true)!
        d.type = .flagsChanged; d.flags = .maskShift; d.post(tap: .cghidEventTap)
        pause(0.05)
        let u = CGEvent(keyboardEventSource: src, virtualKey: 56, keyDown: false)!
        u.type = .flagsChanged; u.flags = []; u.post(tap: .cghidEventTap)
        pause(0.09)
    }
}

var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }
func moveTo(_ p: CGPoint, _ dur: Double = 0.55) {
    let a = cursor, steps = max(2, Int(dur * 60))
    for i in 1...steps {
        let t = Double(i) / Double(steps), k = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        let q = CGPoint(x: a.x + (p.x - a.x) * k, y: a.y + (p.y - a.y) * k)
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: q, mouseButton: .left)!.post(tap: .cghidEventTap)
        pause(1.0 / 60)
    }
}
func click() {
    let p = cursor
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)!
        e.setIntegerValueField(.mouseEventClickState, value: 1)
        e.post(tap: .cghidEventTap)
        pause(0.07)
    }
}

func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}
func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt); AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}
func texts(_ e: AXUIElement) -> [String] {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXIdentifierAttribute].compactMap { attr(e, $0) as? String }
}
func app(_ bundle: String) -> AXUIElement {
    for _ in 0..<50 {
        if let a = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
            return AXUIElementCreateApplication(a.processIdentifier)
        }
        pause(0.1)
    }
    fatalError("\(bundle) is not running")
}
func find(_ root: AXUIElement, role: String? = nil, _ text: String? = nil, exact: Bool = false, timeout: Double = 5) -> AXUIElement {
    guard let e = tryFind(root, role: role, text, exact: exact, timeout: timeout) else {
        fatalError("not found: \(role ?? "*") \(text ?? "*")")
    }
    return e
}
func tryFind(_ root: AXUIElement, role: String? = nil, _ text: String? = nil, exact: Bool = false, timeout: Double = 5) -> AXUIElement? {
    let end = Date().addingTimeInterval(timeout)
    repeat {
        var queue = [root], seen = 0
        while !queue.isEmpty, seen < 4000 {
            let e = queue.removeFirst(); seen += 1
            if (role == nil || attr(e, kAXRoleAttribute) as? String == role),
               (text == nil || texts(e).contains { $0 == text || (!exact && $0.hasPrefix(text!)) }) { return e }
            queue += (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        pause(0.15)
    } while Date() < end
    return nil
}
/// The sheet or window that shows `title` as its heading or title.
func panel(_ title: String) -> AXUIElement {
    var e = find(app(relayoutID), title, exact: true)
    while !["AXSheet", "AXWindow"].contains(attr(e, kAXRoleAttribute) as? String ?? ""),
          let up = attr(e, kAXParentAttribute) { e = up as! AXUIElement }
    return e
}
/// The check box of `flag` ("auto" or "hotkey") in the Per-app features row of `app`.
func appCheckbox(_ panel: AXUIElement, app name: String, flag: String) -> AXUIElement {
    var queue = [panel]
    while !queue.isEmpty {
        let e = queue.removeFirst()
        if attr(e, kAXRoleAttribute) as? String == "AXRow", tryFind(e, name, exact: true, timeout: 0) != nil,
           let box = tryFind(e, role: "AXCheckBox", flag, exact: true, timeout: 0) { return box }
        queue += (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
    fatalError("no \(flag) check box for \(name)")
}
func clickOn(_ e: AXUIElement, dur: Double = 0.55) {
    guard let r = frame(e) else { fatalError("no frame") }
    moveTo(CGPoint(x: r.midX, y: r.midY), dur); pause(0.12); click()
}
func statusItem() -> AXUIElement {
    guard let bar = attr(app(relayoutID), "AXExtrasMenuBar") else { fatalError("no status item") }
    return (attr(bar as! AXUIElement, kAXChildrenAttribute) as! [AXUIElement])[0]
}
/// Rests the pointer just under the menu bar icon, so the icon stays visible.
func pointAtIcon() {
    guard let r = frame(statusItem()) else { return }
    moveTo(CGPoint(x: r.midX + 4, y: r.maxY + 6), 0.8)
}
/// The app's window titled `title`, from its window list: quick, unlike a walk of the whole tree.
func window(_ bundle: String, _ title: String, timeout: Double) -> AXUIElement? {
    let end = Date().addingTimeInterval(timeout)
    repeat {
        let ws = attr(app(bundle), kAXWindowsAttribute) as? [AXUIElement] ?? []
        if let w = ws.first(where: { attr($0, kAXTitleAttribute) as? String == title }) { return w }
        pause(0.05)
    } while Date() < end
    return nil
}
/// Opens Settings from the menu bar icon, retrying if the window does not show.
func openSettings() -> AXUIElement {
    for _ in 0..<3 {
        guard let icon = frame(statusItem()) else { fatalError("no status item frame") }
        moveTo(CGPoint(x: icon.midX, y: icon.midY), 0.7); pause(0.12); click(); pause(0.45)
        // Settings… is the menu's first item: clicked by its offset, since walking the app's
        // AX tree while the menu tracks stalls reLayout and the click got lost.
        moveTo(CGPoint(x: icon.midX + 59, y: icon.midY + 33), 0.35); pause(0.12); click()
        if let w = window(relayoutID, "reLayout Settings", timeout: 8) { return w }   // first build after a rebuild can take >3 s
    }
    fatalError("Settings did not open")
}
func selectLayout(_ id: String) {
    let list = TISCreateInputSourceList([kTISPropertyInputSourceID: id] as CFDictionary, false).takeRetainedValue() as! [TISInputSource]
    TISSelectInputSource(list[0])
}

let screen = NSScreen.main!.frame
let menuBar = CGRect(x: screen.width - 330, y: 0, width: 330, height: 30)
let editor = CGRect(x: 90, y: 80, width: 760, height: 420)
let term = CGRect(x: 90, y: 80, width: 760, height: 420)   // both match the bounds in scripts/demo-vm.sh

/// Windows are placed by scripts/demo-vm.sh (AppleScript runs there, under the SSH session's consent).
func prep() {
    selectLayout("com.apple.keylayout.ABC")
    moveTo(CGPoint(x: editor.midX + 120, y: editor.maxY + 120), 0.3)
    print("prep done")
}

/// Top part of the app's front window: where the typing happens.
func typingArea(_ bundle: String, height: Double) -> CGRect {
    let r = frame(find(app(bundle), role: "AXWindow")) ?? editor
    return CGRect(x: r.minX, y: r.minY + 30, width: min(r.width, 760), height: height)
}

func run() {
    let editorText = typingArea("com.apple.TextEdit", height: 180)
    mark("intro", nil)
    pause(1.0)

    // 1. The hotkey: a word typed on the wrong layout, Shift twice.
    mark("hotkey", editorText, zoom: 1.8, hold: 1.6)
    type("ghbdsn"); pause(0.7)
    shiftTwice(); pause(0.9)
    type(" zr cghfdb"); pause(0.3)          // " як справи" on the Ukrainian layout
    type("\n"); pause(0.6)

    // 2. Settings: auto-correct on, the dot on the icon, a hotkey to toggle it.
    mark("nodot", menuBar, zoom: 3.6, hold: 0.4)
    pointAtIcon(); pause(1.5)
    var settings = openSettings()
    mark("settings", frame(settings), zoom: 1.5, hold: 0.6)
    clickOn(find(settings, role: "AXCheckBox", "Auto-correct wrong layout"), dur: 0.8); pause(0.4)
    mark("dot", menuBar, zoom: 3.6)
    pointAtIcon(); pause(1.4)
    mark("settings", frame(settings), zoom: 1.5)
    clickOn(find(settings, role: "AXButton", "Auto-correct on/off")); pause(0.5)
    press(0, [.maskControl, .maskAlternate]); pause(1.0)          // ⌃⌥A
    press(13, .maskCommand); pause(0.6)                            // ⌘W

    // 3. Auto-correct: both directions fixed on space, no key pressed.
    clickOn(find(app("com.apple.TextEdit"), role: "AXTextArea"), dur: 0.5)
    press(125, .maskCommand); pause(0.3)                           // ⌘↓: end of text
    mark("auto", editorText, zoom: 1.8, hold: 1.6)
    type("psldpjybvjcm e "); pause(0.2)    // "зідзвонимось у " on the Ukrainian layout
    type("Zoom "); pause(1.0)              // typed on Ukrainian: "Ящщь" → Zoom
    type("\n"); pause(0.4)

    // 4. Learning: auto-correct got a login wrong; Shift twice undoes and remembers.
    mark("learn", editorText, zoom: 1.8, hold: 1.8)
    type("login: "); type("ghbdtn "); pause(0.8)
    shiftTwice(); pause(1.2)
    type("\n"); pause(0.5)

    // 5. Learned words in Settings.
    settings = openSettings()
    mark("settings", frame(settings), zoom: 1.5, hold: 1.0)
    clickOn(find(settings, role: "AXButton", "View"), dur: 0.9); pause(0.8)
    let learned = panel("Learned words")
    mark("learned", frame(learned), zoom: 1.7); pause(2.2)
    clickOn(find(learned, role: "AXButton", "Done")); pause(0.4)
    press(13, .maskCommand); pause(0.5)

    // 6. Terminal: a listed app starts with both features off, so Shift twice does nothing.
    mark("wide", nil)
    clickOn(find(app("com.apple.dock"), role: "AXDockItem", "Terminal"), dur: 0.8); pause(1.2)
    mark("terminal", typingArea("com.apple.Terminal", height: 200), zoom: 1.7, hold: 1.8)
    type("echo ghbdsn "); pause(0.8)
    shiftTwice(); pause(1.4)
    type("\n"); pause(0.8)

    // 7. Per-app features: allow the hotkey in Terminal.
    settings = openSettings()
    mark("settings", frame(settings), zoom: 1.5, hold: 1.0)
    clickOn(find(settings, role: "AXButton", "Apps"), dur: 0.9); pause(0.8)
    let apps = panel("Per-app features")
    mark("apps", frame(apps), zoom: 1.6, hold: 1.8)
    clickOn(appCheckbox(apps, app: "Terminal", flag: "hotkey"), dur: 0.8); pause(1.2)
    clickOn(find(apps, role: "AXButton", "Done")); pause(0.4)
    press(13, .maskCommand); pause(0.5)

    // Back in Terminal: now the hotkey works there.
    if let w = frame(find(app("com.apple.Terminal"), role: "AXWindow")) {
        moveTo(CGPoint(x: w.midX, y: w.midY), 0.8); pause(0.1); click(); pause(0.4)
    }
    mark("terminal2", typingArea("com.apple.Terminal", height: 200), zoom: 1.7, hold: 1.4)
    type("echo ghbdsn"); pause(0.8)
    shiftTwice(); pause(1.0)
    type("\n"); pause(1.0)

    // 8. ⌃⌥A turns auto-correct off: the dot goes.
    mark("off", menuBar, zoom: 3.6, hold: 1.2)
    pointAtIcon(); pause(0.5)
    press(0, [.maskControl, .maskAlternate]); pause(1.6)
    mark("outro", nil); pause(1.5)
}

switch CommandLine.arguments.dropFirst().first {
case "prep": prep()
case "run":
    let path = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/markers.jsonl"
    FileManager.default.createFile(atPath: path, contents: nil)
    markers = FileHandle(forWritingAtPath: path)
    run()
default: print("usage: demo-scenario prep | run MARKERS"); exit(1)
}
