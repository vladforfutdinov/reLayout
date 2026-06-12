# reLayout

**Website:** [relayout.forfutdinov.com](https://relayout.forfutdinov.com/)

Punto/Caramba-style "retype the selection in the correct keyboard layout" for macOS — a
tiny menu-bar app. Select (or just type) wrong-layout text, hit the hotkey, and it's
retyped in the right layout; the system input source flips so you can keep going.

Works with **any** enabled keyboard layouts — not hard-coded to a specific pair. An optional
**auto-correct** mode (default off) fixes wrong-layout words as you type, no hotkey needed.

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

**Homebrew:**

```sh
brew install --cask vladforfutdinov/relayout/relayout
```

**Or** grab **`reLayout.dmg`** from the [latest release](https://github.com/vladforfutdinov/reLayout/releases/latest),
open it, and drag **ReLayout** onto **Applications**.

Releases are signed with a Developer ID and **notarized by Apple**, so they open
without any Gatekeeper warning. (Builds ≤ 1.1 were self-signed and needed a
one-time right-click **Open**.)

First launch asks for **Accessibility** (needed to read selection / send keystrokes):
**System Settings → Privacy & Security → Accessibility** → enable **reLayout** → relaunch.

## Build from source

```sh
./scripts/make-cert.sh     # one-time: self-signed identity so the Accessibility grant survives rebuilds
./scripts/build.sh         # -> dist/ReLayout.app
./scripts/make-dmg.sh      # optional: -> dist/reLayout.dmg (drag-to-Applications installer)
open ./dist/ReLayout.app
```

Signed/notarized release builds are produced by CI on a `vX.Y.Z` tag — see
[RELEASING.md](docs/RELEASING.md) for the signing setup and required secrets.
Forks can release under their own identity (bundle id, repo, Sparkle feed,
Homebrew tap) via repository variables — see "Forking" in
[RELEASING.md](docs/RELEASING.md); the install links above are the upstream
project's values.

## Use

1. Select the mistyped text — or, with nothing selected, the line from the caret back to
   its start is grabbed and narrowed to just the wrong-layout tail you typed last (the
   already-correct text ahead of it is left untouched).
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

## Auto-correct (optional, default off)

A live mode that fixes a wrong-layout word **as you type** — no hotkey. On each word
boundary it scores the just-typed word with a per-language character-trigram model; if the
word is improbable in the active layout's language but its converted form is a plausible word
in the other, it's silently corrected (and the system layout switched). Press the hotkey
right after to undo.

- **Cross-script only** (Cyrillic ↔ Latin: ru/uk ↔ en). Latin↔Latin pairs (de/fr/es) are
  deliberately excluded — calibration couldn't hit a safe precision there.
- **Precision-first:** tuned offline (`scripts/trigram/`) for ≥99% precision, so it stays
  quiet when unsure.
- **Per-app exceptions:** a deny-list (seeded with terminals/IDEs) — *Settings → Auto-correct
  → Exceptions…*. Secure text fields (passwords) are always skipped.

## Settings

Menu-bar **rL → Settings…** (the window also shows the About info — version, link, copyright):

- **Open at login** (`SMAppService`), and **Automatically check for updates** (release builds).
- **Auto-correct wrong layout** + **Exceptions…** (see above).
- **Language** — UI language (System Default or a bundled one).
- **Hotkey** — an inline recorder field (like System Settings): click it, then press the
  shortcut. A reset button restores the default. A conflict line warns if the combo is
  already a macOS system shortcut.

Settings persist across restarts (`UserDefaults`; login item in the system registry).

### Hotkey kinds

- **Combo** — a key plus ⌘/⌥/⌃ (e.g. ⌃⌥R).
- **Modifier tap / chord** — tap one or more modifiers alone (press + release, nothing
  else): right Option, both Options, ⌃ + left Option, … Left/right are distinct. Fires only
  if released quickly with no other key/mouse press between, so normal use (Option+click,
  ⌥+letter) doesn't trigger it.
- **Tap sequence** — repeat any of the above N times within a short window (e.g. double-tap
  left Shift). Just record it that many times; there's no separate toggle. Press-again-undo
  is kept for single-tap hotkeys.

The hotkey is paused while the Settings (or Exceptions) window is focused, so recording a new
one can't trigger a conversion.

Conflict check covers macOS system shortcuts (`com.apple.symbolichotkeys`) only — per-app
shortcuts aren't centrally registered, combos the system grabs first (e.g. ⌘Space) can't be
captured, and modifier-only taps aren't checked.

## How it reads / writes (and why DeepL stays quiet)

- **Read** — Accessibility (`kAXSelectedText`), no copy event, no clipboard. Only when AX is
  unavailable for the focused element does it fall back to ⌘C (and only trusts it if the
  pasteboard actually changed); with nothing selected it grabs the caret line via ⇧⌘← + ⌘X.
  Copy (not cut) on a real selection, so apps with smart cut-and-paste can't eat the
  adjacent space.
- **Write** — synthesized Unicode keystrokes (`CGEvent` + `keyboardSetUnicodeString`) that
  replace the active selection, like Caramba. No paste, clipboard untouched.

The AX path posts no clipboard events at all, and the fallback posts at most one ⌘C per
retype — so clipboard watchers like DeepL's `Ctrl+C+C` don't fire.

## Privacy & security

Reading selected text and sending keystrokes needs Accessibility — the same permission a
text expander or a clipboard manager asks for. Here's exactly what the app does and doesn't do
with it; all of this is verifiable in the source (it's MIT, ~3000 lines):

- **Your text never leaves the machine.** There is no analytics, no telemetry, no crash
  reporting, no account, no "phone home." The only network connection the app makes is the
  [Sparkle](https://sparkle-project.org) update check, which fetches a signed appcast and
  nothing else — turn it off with *Settings → Automatically check for updates*.
- **Your text is never written to disk.** Selected text is converted in memory and typed
  back; nothing is persisted. (A debug trace that includes selected text exists only under a
  `-DDEBUG` build and is compiled out of every release — see `dbg()` in `macos/main.swift`.)
- **Accessibility is used only to read the current selection and inject the corrected
  keystrokes** — the same read/write described above. The clipboard is left untouched on the
  AX path, and the ⌘C fallback only reads, never writes.
- **Password fields are skipped.** Secure text fields block synthetic keystrokes, and
  auto-correct never runs in them.
- **What's persisted** is only your settings (hotkey, language, auto-correct on/off, the
  per-app exception list) in `UserDefaults` — no text content.

The Accessibility grant gives any app broad input access; the point of open-sourcing this one
is that you don't have to take the above on faith.

## The menu-bar badge

Mirrors the current input source as a fixed-size template badge (e.g. a filled `A` for ABC,
an outlined `УК` for Ukrainian), tinting/dimming with the menu bar. Updates on layout change.

## Localization

The UI follows the system language, localized to 12: English, Russian, Ukrainian, Belarusian,
German, French, Spanish, Portuguese, Polish, Simplified Chinese, Japanese, Korean. Strings live
in `Resources/<lang>.lproj/Localizable.strings`; `scripts/build.sh` copies them into the bundle. (The
names of conflicting macOS system shortcuts shown in Settings are reported in English.)

## Limitations

- Same-script layouts (e.g. ABC vs German) can't be told apart per-word without a dictionary;
  every Latin word is treated as convertible.
- Secure input fields (password boxes) block synthetic keystrokes.
- Needs ≥ 2 enabled keyboard layouts.

## Diagnostics

```sh
./dist/ReLayout.app/Contents/MacOS/ReLayout --enabled    # list enabled sources in order
./dist/ReLayout.app/Contents/MacOS/ReLayout --selftest   # sample conversions, no GUI
```

## Updates

Release builds auto-update via [Sparkle](https://sparkle-project.org) (EdDSA-signed
appcast, checked in the background). Or trigger it from the menu-bar
**rL → Check for Updates…**.

## Autostart

Toggle *Open at login* in Settings, or System Settings → General → Login Items → `ReLayout.app`.

## Credits

The auto-correct trigram models in `Resources/trigram/` are built offline from
[FrequencyWords](https://github.com/hermitdave/FrequencyWords) by Hermit Dave (MIT-licensed
frequency lists derived from the OpenSubtitles corpus). reLayout ships only the derived
char-trigram statistics, not the word lists themselves.

> MIT License — Copyright (c) 2016 Hermit Dave

App updates use [Sparkle](https://sparkle-project.org).

## License

[MIT](LICENSE) © 2026 Volodymyr Forfutdinov.
