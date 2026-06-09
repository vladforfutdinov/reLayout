# reLayout — Architecture & Build Reference

Deep reference. For day-one orientation read [`CLAUDE.md`](../CLAUDE.md) first; this is
the detail it links to.

## Build env vars (read by `scripts/build.sh`)

- `RELAYOUT_VERSION` — override version string.
- `RELAYOUT_RELEASE=1` / `RELAYOUT_DEV=1` — force release vs dev bundle id/name.
- `WITH_SPARKLE=1` — fetch & embed Sparkle 2.6.4 framework, compile with `-D SPARKLE`. CI uses this for releases.
- `SIGN_IDENTITY` — Developer ID Application identity. Triggers Hardened Runtime + secure timestamp (notarization-ready). Without it, uses `ReLayout Self Signed` if present, else ad-hoc.

## Release flow

Tag `vX.Y.Z` → `.github/workflows/build.yml` signs (Developer ID), notarizes
(`notarize.sh`, App Store Connect API key), staples, publishes a GitHub Release with
`reLayout.dmg` + `reLayout.zip`, updates the Sparkle appcast + Homebrew cask. See
[`RELEASING.md`](RELEASING.md) for the secret list.

Dev vs release builds use **different bundle IDs** (`com.vladforfutdinov.relayout` vs
`com.vladforfutdinov.relayout.dev`) and different `.app` names so macOS keeps separate
Accessibility grants and UserDefaults.

## Conversion engine (`Core/Engine.swift`)

Platform-free Swift. **No** AppKit/Carbon/WinSDK imports. Shared verbatim by:
- macOS app — compiled together with `macos/main.swift` by `scripts/build.sh`.
- Windows port — imported as the `ReLayoutCore` SwiftPM module (`Package.swift`).
- Tests — both `scripts/run-tests.sh` (links into the macOS binary with `-DTESTING`) and `swift test` (uses `Tests/ReLayoutCoreTests`).

The core algorithm is **not** a character→character table. It is:

```
char --(source layout reverse)--> KeyStroke (physical key + mods)
     --(target layout)         --> char
```

Each platform builds a `LayoutMaps` (`charToStroke`, `strokeToChar`, `isCyrillic`) over the actually-installed layouts:
- macOS: Carbon `UCKeyTranslate`.
- Windows: `ToUnicodeEx`.

This is why the Option/AltGr layer (`ß`/`æ` ↔ `ы`/`э`) works automatically — both produce the same `keyCode + Option`, so the reverse-then-forward lookup converts them without hand-coded tables.

`transliterate(_:from:to:)` is the entry point. Word-level "is this the wrong layout?" detection uses script heuristics (`hasCyr`, `isLatinLetter`) — only words in the script of the **currently active** layout are converted; the rest of the selection is preserved. `dominantScript` / `textHasScript` / `wordTokens` back a hybrid fallback: when the active layout no longer matches what was typed (user switched after mistyping), the source is inferred from the text's majority script instead of the system layout.

`Core/Trigram.swift` — a character-trigram language model used by the auto-correct mode. `TrigramModel.score(_:)` returns a word's length-normalized mean trigram log-prob under a per-language model; models are generated offline (`scripts/trigram/gen.py`) from frequency word lists and shipped as `Resources/trigram/<lang>.txt`. Platform-free, so it lives in the engine.

## macOS app (`macos/main.swift`, single file)

Holds everything outside the engine:
- `Loc` / `L(_:)` — localization. UI strings live in `Resources/<lang>.lproj/Localizable.strings`. Languages are discovered from shipped `.lproj` bundles; user override in `UserDefaults["language"]` switches live, no relaunch.
- Hotkey system — supports **combos** (e.g. ⌃⌥R via `RegisterEventHotKey`) and **modifier taps/chords** (e.g. tap left Option). Tap/chord detection uses a `CGEventTap` and fires only on release with no other key/mouse press in between; a `tapPolluted` guard ignores cycles where an out-of-set modifier appeared. A hotkey can also be a **tap sequence** (`hotKeyTaps` — N activations within `doubleTapWindow`, e.g. double-tap Shift), recorded by repeating it in the `ShortcutField`.
- Auto-correct mode (`autoMode`, default off) — a second `CGEventTap` (keyDown) buffers the current word and, on a word boundary, runs `autoDecide` (trigram scores, cross-script targets only) → `autoCorrect` deletes + retypes the fixed word and switches layout. A user deny-list (`autoExcludedApps`, edited via the Exceptions sheet) plus a secure-text-field check gate it per app; our own synthesized events carry `synthMarker` so the monitor ignores them.
- Selection read/write — Accessibility API first (so DeepL etc. don't see clipboard churn); clipboard fallback uses **Cmd+X (cut)**, which dodges DeepL's Cmd+C-Cmd+C watcher and removes the selection in one step. Saves/restores pasteboard.
- Input source switching — Text Input Sources / TISSelectInputSource.
- Settings — a single window that also holds the About info (logo / version / link). Menu-bar item (`NSStatusItem`), login item (`SMAppService`), conflict check against `com.apple.symbolichotkeys`. The live hotkey + auto-correct are suspended while a config window (Settings or the Exceptions sheet) is key, so recording can't trigger a conversion. `Cmd+W`/`Cmd+Q` handled by physical keyCode (no main menu).
- Press-again undo: a second hotkey within `undoWindow` (1.5 s) of a conversion reverses it (single-tap hotkeys only).
- Sparkle auto-update under `#if SPARKLE` (only compiled when `WITH_SPARKLE=1`).
- `dbg(_:)` writes to `/tmp/relayout.log` only under `-DDEBUG`. Release builds **must never** write selection text to disk — the empty release body is inlined away under `-O`. Don't add prints of user text outside this guard.

`macos/tests.swift` provides a `@main` entry under `-DTESTING` that replaces the GUI bootstrap so the unit tests exercise the **real** engine + helpers, not copies.

## Windows port (`windows/`, MVP)

- `windows/main.swift` — registers `Ctrl+Alt+R` hotkey, message loop, drives the retype.
- `WinLayout.swift` — builds `LayoutMaps` via `ToUnicodeEx`, lists/switches HKLs.
- `WinInput.swift` — clipboard read (Ctrl+C fallback), `SendInput` Unicode write.
- `WinTray.swift` — system tray with right-click Quit.

Only built when host OS is Windows (`#if os(Windows)` gate in `Package.swift`); macOS `swift test` ignores the executable target. No GUI/settings yet; selection read is Ctrl+C only (UI Automation is TODO).
