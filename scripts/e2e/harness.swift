// End-to-end harness: opens a plain text window, types into it with synthetic
// physical key events, and checks what the running dev app made of the text.
// Driven by scripts/e2e.sh, which isolates the app's preferences around the run.
import AppKit
import Carbon

// US/ABC physical key codes; the app reads the key code, not the event's string.
let keyCodes: [Character: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
    "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "[": 33, "i": 34,
    "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, ",": 43, "n": 45, "m": 46, ".": 47,
    " ": 49, "\r": 36, "\t": 48,
]
let kShift: CGKeyCode = 56
let leftShiftDeviceBit = CGEventFlags(rawValue: 0x02)   // NX_DEVICELSHIFTKEYMASK

final class Harness: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var text: NSTextView!

    func applicationDidFinishLaunching(_ n: Notification) {
        let scroll = NSTextView.scrollableTextView()
        text = (scroll.documentView as! NSTextView)
        text.enabledTextCheckingTypes = 0   // no autocorrect or capitalisation in the way
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.font = .systemFont(ofSize: 18)
        window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 520, height: 160),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "reLayout e2e — hands off the keyboard"
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(text)
        NSApp.activate(ignoringOtherApps: true)
        Thread { exit(Int32(min(runScenarios(self), 125))) }.start()
    }
}

// MARK: - driver (background thread; UI and TIS calls hop to main)

let source = CGEventSource(stateID: .hidSystemState)

func onMain<T>(_ body: () -> T) -> T { DispatchQueue.main.sync(execute: body) }
func pause(_ ms: Int) { usleep(useconds_t(ms * 1000)) }

func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)!
        e.flags = flags
        e.post(tap: .cghidEventTap)
        pause(down ? 8 : 30)
    }
}

func type(_ s: String) {
    for c in s {
        guard let code = keyCodes[Character(c.lowercased())] else { fatalError("no key code for \(c)") }
        key(code, flags: c.isUppercase ? .maskShift : [])
    }
}

/// The default retype hotkey: two clean taps of left Shift.
func hotkey() {
    for _ in 0..<2 {
        for flags in [CGEventFlags.maskShift.union(leftShiftDeviceBit), []] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: kShift, keyDown: !flags.isEmpty)!
            e.type = .flagsChanged
            e.flags = flags
            e.post(tap: .cghidEventTap)
            pause(60)
        }
    }
}

func click(_ h: Harness) {
    let p: CGPoint = onMain {
        let r = h.window.convertToScreen(h.text.convert(h.text.bounds, to: nil))
        let top = NSScreen.screens[0].frame.maxY   // CG coordinates run top-down from the primary screen
        return CGPoint(x: r.midX, y: top - r.maxY + 20)
    }
    for t in [CGEventType.leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: source, mouseType: t, mouseCursorPosition: p, mouseButton: .left)!
            .post(tap: .cghidEventTap)
        pause(40)
    }
}

func enabledLayouts() -> [(id: String, source: TISInputSource)] {
    let filter = [kTISPropertyInputSourceType: kTISTypeKeyboardLayout] as CFDictionary
    let list = TISCreateInputSourceList(filter, false).takeRetainedValue() as! [TISInputSource]
    return list.compactMap { s in
        guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return nil }
        return (Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String, s)
    }
}

func currentLayoutID() -> String {
    onMain {
        let s = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        return Unmanaged<CFString>.fromOpaque(TISGetInputSourceProperty(s, kTISPropertyInputSourceID))
            .takeUnretainedValue() as String
    }
}

// MARK: - scenarios

var latin = "", cyrillic = ""
var failures = 0

func select(_ id: String) {
    onMain { _ = enabledLayouts().first { $0.id == id }.map { TISSelectInputSource($0.source) } }
    pause(150)
}

/// Stops the run rather than type into whatever app has focus instead.
func requireFocus(_ h: Harness) {
    for _ in 0..<100 {
        if onMain({ NSApp.isActive && h.window.isKeyWindow }) { return }
        onMain { NSApp.activate(ignoringOtherApps: true); h.window.makeKeyAndOrderFront(nil) }
        pause(50)
    }
    print("ABORT the test window lost focus; nothing more is typed")
    exit(3)
}

/// Fresh field: a click ends the app's word buffer and undo window, then the text
/// is set (optionally selected) and the Latin layout made current.
func reset(_ h: Harness, _ s: String = "", selectAll: Bool = false) {
    requireFocus(h)
    click(h)
    onMain {
        h.text.string = s
        let n = s.utf16.count
        h.text.setSelectedRange(selectAll ? NSRange(location: 0, length: n) : NSRange(location: n, length: 0))
    }
    select(latin)
}

/// Waits until the field reads `want` (up to `timeout`), or for `settle` ms when
/// the point is that nothing changes.
func expect(_ h: Harness, _ name: String, _ want: String, layout: String? = nil,
            timeout: Int = 2500, settle: Int = 0) {
    if settle > 0 { pause(settle) }
    var got = ""
    for _ in 0..<(timeout / 50) {
        got = onMain { h.text.string }
        if got == want { break }
        pause(50)
    }
    pause(150)   // let the layout switch land
    let lay = currentLayoutID()
    if got == want, layout.map({ $0 == lay }) ?? true {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)\n      want \(want.debugDescription)\(layout.map { " on \($0)" } ?? "")"
              + "\n      got  \(got.debugDescription) on \(lay)")
    }
}

/// Types `text` and a space, then waits until the field has not changed for `quiet`
/// ms. Returns the ms from the space's key-down to the field's last change (0 when
/// it was done before) and whether the field ended up other than the keys typed.
/// After a fix switches the layout the rest of a phrase types right, so for a phrase
/// this is the tail of the work: the first word's fix and the keys held meanwhile.
func timedFix(_ h: Harness, _ text: String, quiet: Int = 400, limit: Int = 3000) -> (ms: Int, changed: Bool) {
    reset(h); type(text)
    let start = DispatchTime.now().uptimeNanoseconds
    type(" ")
    var last = onMain { h.text.string }, changed = start
    while true {
        pause(2)
        let now = DispatchTime.now().uptimeNanoseconds
        let cur = onMain { h.text.string }
        if cur != last { last = cur; changed = now }
        if Int((now - changed) / 1_000_000) >= quiet || Int((now - start) / 1_000_000) >= limit { break }
    }
    return (Int((changed - start) / 1_000_000), last != text + " ")
}

// Russian words, each typed once: a word fixed and typed again after the field is
// reset reads as reverting the fix and is learned as kept, which a timing must avoid.
let perfWords = """
    привет книга слово дорога работа город время человек жизнь рука место вопрос ответ страна сейчас
    может хорошо всегда сегодня завтра вечер утро письмо машина деньги погода музыка история неделя правда
    солнце дерево окно стол улица море небо голос школа друг семья ночь дождь ветер поле
    мама папа брат сестра собака кошка лето зима осень весна река гора лес цветок птица
    """.split(whereSeparator: \.isWhitespace).map(String.init)
let ruKeys: [Character: Character] = [
    "й": "q", "ц": "w", "у": "e", "к": "r", "е": "t", "н": "y", "г": "u", "ш": "i", "щ": "o", "з": "p", "х": "[",
    "ф": "a", "ы": "s", "в": "d", "а": "f", "п": "g", "р": "h", "о": "j", "л": "k", "д": "l", "ж": ";", "э": "'",
    "я": "z", "ч": "x", "с": "c", "м": "v", "и": "b", "т": "n", "ь": "m", "б": ",", "ю": ".",
]
/// A Russian word as typed on the Latin keys.
func onLatinKeys(_ word: String) -> String { String(word.map { ruKeys[$0] ?? $0 }) }

/// RELAYOUT_E2E_PERF=n: times auto-correct instead of checking it — up to n
/// wrong-layout words and n three-word phrases (Russian, each word once), each from
/// the last space's key-down to a still field.
func runPerf(_ h: Harness, _ n: Int) -> Int {
    func run(_ name: String, _ texts: [String]) {
        let runs = texts.map { timedFix(h, $0) }
        let s = runs.filter(\.changed).map(\.ms).sorted()
        guard !s.isEmpty else { print("PERF  \(name): nothing fixed in \(texts.count)"); return }
        print("PERF  \(name): fixed \(s.count)/\(texts.count) median=\(s[s.count / 2]) p90=\(s[s.count * 9 / 10]) max=\(s.last!) ms")
    }
    let words = perfWords.map(onLatinKeys)
    let count = min(n, words.count / 4)
    run("word fix", Array(words.prefix(count)))
    run("phrase fix", (0..<count).map { i in words[count + 3 * i ..< count + 3 * i + 3].joined(separator: " ") })
    return 0
}

func runScenarios(_ h: Harness) -> Int {
    requireFocus(h)
    pause(300)
    let ids = onMain { enabledLayouts().map(\.id) }
    guard let l = ids.first(where: { ["com.apple.keylayout.ABC", "com.apple.keylayout.US"].contains($0) }),
          let c = ids.first(where: { $0.contains("Russian") || $0.contains("Ukrainian") }) else {
        print("SKIP  need ABC or U.S. and a Russian or Ukrainian layout enabled; have \(ids)")
        return 1
    }
    latin = l; cyrillic = c
    // (typed on Latin keys, what it reads as in the Cyrillic layout)
    let hello = c.contains("Russian") ? ("ghbdtn", "привет") : ("ghbdsn", "привіт")
    let word = ("ckjdj", "слово")   // its undo below learns it as kept: later scenarios use `book`
    let book = ("rybuf", "книга")
    // Each fixed word is used once more at most: retyping a just-fixed word after a
    // click reads as reverting the fix (learning by revert) and is then kept.
    let world = c.contains("Russian") ? ("cdtn", "свет") : ("cdsn", "світ")
    print("using \(l) + \(c)")
    if let n = Int(ProcessInfo.processInfo.environment["RELAYOUT_E2E_PERF"] ?? "") {
        return runPerf(h, n)
    }

    reset(h); type(hello.0 + " ")
    expect(h, "auto: wrong-layout word is fixed", hello.1 + " ", layout: cyrillic)

    reset(h); type("hello ")
    expect(h, "auto: right-layout word stays", "hello ", layout: latin, settle: 700)

    reset(h, hello.0, selectAll: true); hotkey()
    expect(h, "hotkey: selection is converted", hello.1, layout: cyrillic)
    // With Russian enabled too, Ukrainian "ghbdsn" has a second reading: the press
    // after the conversion types it, and the next one undoes (three layouts cycle).
    if c.contains("Ukrainian"), let ru = ids.first(where: { $0.contains("Russian") }) {
        hotkey()
        expect(h, "hotkey again: next reading", "привыт", layout: ru)
    }
    hotkey()
    expect(h, "hotkey again: conversion is undone", hello.0, layout: latin)

    reset(h); type(word.0 + " "); expect(h, "auto: fix before the undo", word.1 + " ")
    hotkey()
    expect(h, "hotkey after auto-fix: fix is undone", word.0 + " ", layout: latin)

    reset(h); type(hello.0 + " ")
    expect(h, "auto: fix before typing on", hello.1 + " ")
    type("rfr"); hotkey()   // "как", typed after the fix: the hotkey converts it, not undo
    expect(h, "hotkey after typing: new word converts", hello.1 + " rfr", layout: latin)

    // Keys typed while a fix runs are held, then replayed through the word buffer.
    reset(h); type(world.0 + " rfr ")
    expect(h, "auto: keys typed during a fix land in the new layout", world.1 + " как ")

    reset(h); type("d\t" + book.0 + " ")   // a Tab may move focus: no fix reaches back across it
    expect(h, "auto: short word before a Tab is left alone", "d\t" + book.1 + " ")

    reset(h); type(hello.0 + "\r")
    expect(h, "enter: word above the new line is fixed", hello.1 + "\n", layout: cyrillic)

    print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
    return failures
}

guard AXIsProcessTrusted() else {
    print("SKIP  this terminal has no Accessibility permission to post key events "
          + "(System Settings → Privacy & Security → Accessibility)")
    exit(2)
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Harness()
app.delegate = delegate
app.run()
