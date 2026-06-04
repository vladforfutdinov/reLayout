# ReLayout

Punto-style "retype selection in the other layout" for macOS. Fixed **US (ABC) ⇄ Ukrainian**.

Select wrong-layout text, press the hotkey — it gets retyped in the correct layout and the
system input source flips so you can keep typing.

## Why it handles `ß`/`æ` → `ы`/`э`

It does **not** map character→character. It maps:

```
char --(source layout reverse)--> physical key + modifiers --(target layout)--> char
```

using Carbon `UCKeyTranslate` over the actual installed layouts. Because you type Russian
`ы э ъ ё` on the Ukrainian layout with **Option** (they're missing from the base layer), and
the same physical `Option+key` on US produces `ß æ …`, both sit on the same keycode+Option —
so they convert automatically. No hand-coded tables.

## Build

```sh
./build.sh
```

Produces `ReLayout.app` (ad-hoc signed, menu-bar agent — no Dock icon).

## Run

```sh
open ./ReLayout.app
```

First launch macOS asks for **Accessibility** (needed to send ⌘C/⌘V and read modifiers):
**System Settings → Privacy & Security → Accessibility** → enable **ReLayout** → relaunch.

## Use

1. Select the mistyped text.
2. Press **⌃⌥R** (Control+Option+R).

Conversion is **per word**, and the marker for "wrong" is the **layout active at the
moment you press the hotkey** (= the layout that produced the mistake):

- Active layout **US** → only Latin-script words are converted to Ukrainian
  (incl. the Option layer `ß/æ → ы/э`); Cyrillic words are left untouched.
- Active layout **Ukrainian** → only Cyrillic words are converted to US; Latin
  words are left untouched.

So `я сказал ghbdtn` (US active) → `я сказал привет`, and `I said привет`
(UA active) → `I said ghbdtn`. After converting, the system layout flips to the
correct one. If nothing in the selection matches the active script, it's a no-op.

No dictionary — the only signal is "this script ≠ what the active layout should
produce". Press the hotkey right after the mistake, while the wrong layout is still
active.

Menu-bar **⇄** icon shows the active pair and has a manual "Retype selection" item + Quit.

## Self-test (no GUI)

```sh
./ReLayout.app/Contents/MacOS/ReLayout --selftest
```

Prints the detected layouts, every installed keyboard layout id, and sample conversions
(`ghbdtn → привет`, `ß → ы`, …).

## Settings

Menu-bar **⇄ → Settings…** (⌘,). Window has:

- **Hotkey** — current shortcut + **Change…** (opens the recorder as a sheet).
- **Startup** — *Open ReLayout at login* (via `SMAppService`). The login item points at
  the app's current path — if you move the `.app`, toggle it off/on again.
- **Layouts** — the detected `US ⇄ Ukrainian` pair.

All settings persist across restarts (hotkey in `UserDefaults`, login item in the
system's login-items registry).

## Hotkey

Set via **Settings… → Change…**. Two kinds:

- **Combo** — a normal key plus ⌘/⌥/⌃ (e.g. ⌃⌥R).
- **Single modifier tap** — tap one modifier alone (press + release, nothing else),
  e.g. right Option. Left/right are distinct. A tap fires only if released within
  0.5 s with no other key or mouse press in between, so using the modifier normally
  (Option+click, ⌥+letter) does not trigger it.

The window shows the captured shortcut; nothing is applied until **Save**. The choice
persists in UserDefaults across restarts.

**Conflict check** — when you capture a key combo, ReLayout looks it up in macOS's
system shortcuts (`com.apple.symbolichotkeys`) and, if taken, shows the owner
(e.g. "select previous input source", "Spotlight search"). The warning is advisory —
Save still overrides. Caveats: only system shortcuts are visible (per-app shortcuts
aren't centrally registered); combos the system grabs first (e.g. ⌘Space) can't be
captured at all; modifier-only taps aren't checked (macOS has no registry for them).

## Customise (code)

- **Layouts** — `applicationDidFinishLaunching`: the `idContains:` needle lists. `find()`
  prefers your *enabled* layout, exact id over substring. Swap `"Ukrainian"` for e.g.
  `"Russian"` for a US⇄Russian build.

## How it reads the selection (and why DeepL stays quiet)

Primary path: the **Accessibility API** (`kAXSelectedText` on the focused element) — reads and
replaces the selection in place with **no synthetic copy and no clipboard use**. Tools that
synthesize a copy keystroke (RuSwitcher-style) trip clipboard watchers like DeepL's
`Ctrl+C+C`; this doesn't. Same approach as Caramba.

Fallback path: clipboard ⌘C/⌘V round-trip, used only for apps that don't expose AX text
(some Electron/web views). Clipboard is saved and restored.

## Limitations

- AX in-place replace works in native text fields; unsupported apps fall back to clipboard.
- Secure input fields (password boxes) block synthetic ⌘C/⌘V — fallback is a no-op there.
- Needs both layouts present; if missing, an alert lists what was found.

## Autostart (optional)

System Settings → General → Login Items → add `ReLayout.app`.
