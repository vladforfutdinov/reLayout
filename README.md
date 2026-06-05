# reLayout

Punto/Caramba-style "retype the selection in the correct keyboard layout" for macOS — a
tiny menu-bar app. Select (or just type) wrong-layout text, hit the hotkey, and it's
retyped in the right layout; the system input source flips so you can keep going.

Works with **any** enabled keyboard layouts — not hard-coded to a specific pair.

## Why it handles `ß`/`æ` → `ы`/`э`

It does **not** map character→character. It maps:

```
char --(source layout reverse)--> physical key + modifiers --(target layout)--> char
```

via Carbon `UCKeyTranslate` over the actually-installed layouts. You type Russian `ы э ъ ё`
on the Ukrainian layout with **Option**; the same physical `Option+key` on US produces
`ß æ …`. Both sit on the same keycode+Option, so they convert automatically — no hand-coded
character tables, and the Option layer just works.

## Install

Grab **`reLayout.dmg`** from the [latest release](https://github.com/vladforfutdinov/reLayout/releases/latest),
open it, and drag **ReLayout** onto **Applications**.

The app is self-signed, not notarized, so Gatekeeper blocks the first launch
("unidentified developer"). Right-click **ReLayout.app → Open → Open** once (or
**System Settings → Privacy & Security → Open Anyway**); subsequent launches are
normal. From the command line: `xattr -dr com.apple.quarantine /Applications/ReLayout.app`.

First launch asks for **Accessibility** (needed to read selection / send keystrokes):
**System Settings → Privacy & Security → Accessibility** → enable **reLayout** → relaunch.

## Build from source

```sh
./make-cert.sh     # one-time: self-signed identity so the Accessibility grant survives rebuilds
./build.sh         # -> ReLayout.app
./make-dmg.sh      # optional: -> reLayout.dmg (drag-to-Applications installer)
open ./ReLayout.app
```

## Use

1. Select the mistyped text — or, with nothing selected, the text from the caret back to
   the start of the line is used.
2. Press the hotkey (default: **tap left Option**).
3. **Undo** — press the hotkey again within ~1.5 s to reverse the conversion (restores the
   original text and the previous input source). Like RuSwitcher's double-Alt.

Conversion is **per word**. The "wrong" words are those typed in the **layout active at the
moment you press the hotkey** (identified by script). Only those are converted; the rest of
the selection is kept. After converting, the system layout switches to the target.

Target layout selection:

- **2 enabled layouts** → the other one.
- **>2 enabled** → the **first** in the input-source list; if the active layout *is* the
  first, the **second**; or, if the rest of the selection is in another script that maps to
  exactly one enabled layout, that one.

`я сказал ghbdtn` (US active) → `я сказал привет`. If nothing in the selection matches the
active layout's script, it's a no-op.

## Settings

Menu-bar **⇄ → Settings…**:

- **Startup** — *Open at login* (`SMAppService`).
- **Layouts** — the enabled input sources, in menu order.
- **Hotkey** — an inline recorder field (like System Settings): click it, then press the
  shortcut. An undo button restores the default. A conflict line warns if the combo is
  already a macOS system shortcut.

Settings persist across restarts (hotkey in `UserDefaults`, login item in the system
registry).

### Hotkey kinds

- **Combo** — a key plus ⌘/⌥/⌃ (e.g. ⌃⌥R).
- **Modifier tap / chord** — tap one or more modifiers alone (press + release, nothing
  else): right Option, both Options, ⌃ + left Option, … Left/right are distinct. Fires only
  if released quickly with no other key/mouse press between, so normal use (Option+click,
  ⌥+letter) doesn't trigger it.

Conflict check covers macOS system shortcuts (`com.apple.symbolichotkeys`) only — per-app
shortcuts aren't centrally registered, combos the system grabs first (e.g. ⌘Space) can't be
captured, and modifier-only taps aren't checked.

## How it reads / writes (and why DeepL stays quiet)

- **Read** — Accessibility (`kAXSelectedText`), no copy event, no clipboard. Only when AX is
  unavailable for the focused element does it fall back to ⌘C (and only trusts it if the
  pasteboard actually changed).
- **Write** — synthesized Unicode keystrokes (`CGEvent` + `keyboardSetUnicodeString`) that
  replace the active selection, like Caramba. No paste, clipboard untouched.

Because there's no synthetic copy, clipboard watchers like DeepL's `Ctrl+C+C` don't fire.

## The menu-bar badge

Mirrors the current input source as a fixed-size template badge (e.g. a filled `A` for ABC,
an outlined `УК` for Ukrainian), tinting/dimming with the menu bar. Updates on layout change.

## Limitations

- Same-script layouts (e.g. ABC vs German) can't be told apart per-word without a dictionary;
  every Latin word is treated as convertible.
- Secure input fields (password boxes) block synthetic keystrokes.
- Needs ≥ 2 enabled keyboard layouts.

## Diagnostics

```sh
./ReLayout.app/Contents/MacOS/ReLayout --enabled    # list enabled sources in order
./ReLayout.app/Contents/MacOS/ReLayout --selftest   # sample conversions, no GUI
```

## Autostart

Toggle *Open at login* in Settings, or System Settings → General → Login Items → `ReLayout.app`.
