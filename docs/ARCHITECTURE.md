# reLayout — Architecture & Build Reference

Deep reference. For day-one orientation read [`CLAUDE.md`](../CLAUDE.md) first; this is
the detail it links to.

## Build env vars (read by `scripts/build.sh`)

- `RELAYOUT_VERSION` — override version string.
- `RELAYOUT_RELEASE=1` / `RELAYOUT_DEV=1` — force release vs dev bundle id/name.
- `WITH_SPARKLE=1` — fetch & embed Sparkle 2.6.4 framework, compile with `-D SPARKLE`. CI uses this for releases.
- `SIGN_IDENTITY` — Developer ID Application identity. Triggers Hardened Runtime + secure timestamp (notarization-ready). Without it, uses `ReLayout Self Signed` if present, else ad-hoc.

Owner identity — **no owner values are hardcoded in the repo.** Resolution order in
`build.sh`: `RELAYOUT_*` env vars (CI sets them from repository *variables*) →
`scripts/identity.env` (gitignored local file; copy `identity.env.example`) →
neutral fallbacks (`com.example.relayout`, repo slug derived from the git origin
remote, Sparkle disabled). Release builds (`RELAYOUT_RELEASE=1` / exact tag)
**fail** under the neutral id. See [`RELEASING.md`](RELEASING.md) → "Forking".

- `RELAYOUT_BUNDLE_ID` — base bundle id (dev builds append `.dev`).
- `RELAYOUT_DISPLAY_NAME` — app display name (dev appends ` (dev)`).
- `RELAYOUT_REPO_SLUG` — GitHub `owner/repo` for the About link (injected into the bundle as `RLRepoSlug`; empty hides the link) and the Homebrew cask.
- `RELAYOUT_FEED_URL` — Sparkle `SUFeedURL`. Empty → Sparkle keys removed from the bundle, automatic checks disabled.
- `RELAYOUT_SU_PUBLIC_KEY` — Sparkle `SUPublicEDKey`; **pairs with the `SPARKLE_ED_PRIVATE_KEY` secret** — replace both together.
- `RELAYOUT_TAP_REPO` — Homebrew tap `owner/name` (read by `packaging/homebrew/update-cask.sh`, not build.sh).

## Release flow

Tag `vX.Y.Z` → `.github/workflows/build.yml` signs (Developer ID), notarizes
(`notarize.sh`, App Store Connect API key), staples, publishes a GitHub Release with
`reLayout.dmg` + `reLayout.zip`, updates the Sparkle appcast + Homebrew cask. See
[`RELEASING.md`](RELEASING.md) for the secret list.

Dev vs release builds use **different bundle IDs** (the base `RELAYOUT_BUNDLE_ID` vs
the same id + `.dev`) and different `.app` names so macOS keeps separate
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

`lastWrongWindow(_:)` handles the **no-selection** case, where the app grabs the whole caret line (which mixes already-correct text with the wrong-layout tail). It anchors the wrong script on the line's last letter, walks back over same-script and neutral chars, stops at the first letter of another script, and trims a mid-word remainder — so only that tail is converted and the correct prefix is left verbatim. The macOS app passes the grabbed line through this only on the line-grab path (`convert(_:lineGrab:)`); an explicit selection converts as a whole.

`Core/Trigram.swift` — a character-trigram language model used by the auto-correct mode. `TrigramModel.score(_:)` returns a word's length-normalized mean trigram log-prob under a per-language model; models are generated offline (`scripts/trigram/gen.py`) from frequency word lists and shipped as `Resources/trigram/<lang>.txt`. Platform-free, so it lives in the engine.

## macOS app (`macos/main.swift`, single file)

Holds everything outside the engine:
- `Loc` / `L(_:)` — localization. UI strings live in `Resources/<lang>.lproj/Localizable.strings`. Languages are discovered from shipped `.lproj` bundles; user override in `UserDefaults["language"]` switches live, no relaunch.
- Hotkey system — supports **combos** (e.g. ⌃⌥R via `RegisterEventHotKey`) and **modifier taps/chords** (e.g. tap left Option). Tap/chord detection uses a `CGEventTap` and fires only on release with no other key/mouse press in between; a `tapPolluted` guard ignores cycles where an out-of-set modifier appeared. A hotkey can also be a **tap sequence** (`hotKeyTaps` — N activations within `doubleTapWindow`, e.g. double-tap Shift), recorded by repeating it in the `ShortcutField`.
- Auto-correct mode (`autoMode`, default off) — a second `CGEventTap` (keyDown) buffers the current word and, on a word boundary, runs `autoDecide` (trigram scores, cross-script targets only) → `autoCorrect` deletes + retypes the fixed word and switches layout. Punctuation that is a letter on an enabled Cyrillic layout (`,`=б, `'`=э, `;`=ж, `[`=х …) buffers as word material, so ",skj" fixes to "было"; `autoWordCore` (engine) vets the shape — a trailing mapped char is ambiguous ("знаю" vs "зна.") and never converts, and punctuation-bearing words must clear an absolute plausibility gate (`autoPunctPlausible`) on top of the usual margin. A user deny-list (`autoExcludedApps`, edited via the Exceptions sheet) plus a secure-text-field check gate it per app; our own synthesized events carry `synthMarker` so the monitor ignores them.
- Selection read/write — Accessibility API first (so DeepL etc. don't see clipboard churn); clipboard fallback reads an explicit selection with **Cmd+C** (copy keeps the selection and typing replaces exactly it — smart cut-and-paste in Word-like apps would otherwise swallow an adjacent space along with a cut word) and uses **Cmd+X (cut)** only for the no-selection line-grab (C-then-X — still no Cmd+C-Cmd+C pair for DeepL's watcher). Saves/restores pasteboard.
- Input source switching — Text Input Sources / TISSelectInputSource.
- Settings — a single window that also holds the About info (logo / version / link). Menu-bar item (`NSStatusItem`), login item (`SMAppService`), conflict check against `com.apple.symbolichotkeys`. The live hotkey + auto-correct are suspended only while the shortcut recorder field is actively capturing (`recordingHotkey`, set by `ShortcutField.onRecordingChanged`), so the keys being recorded can't trigger a conversion — merely having Settings open leaves the hotkey live. `finalizeSequence` commits a tap sequence and re-applies the hotkey while the field is still focused, so the gate holds the re-apply off until the recorder stops. `Cmd+W`/`Cmd+Q` handled by physical keyCode (no main menu).
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
