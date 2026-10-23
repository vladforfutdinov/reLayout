# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

reLayout is a tiny menu-bar macOS app (with a Windows port) that retypes selected text in the correct keyboard layout — Punto/Caramba style. Hotkey → read selection → convert via the active OS keyboard layouts → type back → switch system input source. Press the hotkey again (before typing or clicking anything else) to cycle the remaining layouts, then to undo.

## Session handoff (context across sessions)

Three files keep context between sessions — read all at the start of a session and after `/clear`, before starting new work:

- **[`docs/SNAPSHOT.md`](docs/SNAPSHOT.md)** — operational "where are we right now": what's done recently, in progress, known issues, next steps, test status, uncommitted work. **Overwrite sections each session — don't append.** This is a current-state snapshot, not a log.
- **[`docs/HISTORY.md`](docs/HISTORY.md)** — append-only chronology, newest milestone on top, one block per coherent unit of work (not per commit). This is the durable record.
- **[`docs/BACKLOG.md`](docs/BACKLOG.md)** — committed backlog of planned-but-not-started work (one section per item, with rationale + remaining steps). Move an item out once it's in progress. Travels with the repo, unlike `SNAPSHOT.md`.

At the end of a session (or before `/clear`): run **`/handoff`** — it updates `docs/SNAPSHOT.md` to the new current state and appends a `docs/HISTORY.md` block for any milestone completed. `docs/HISTORY.md` is committed (travels with the repo); `docs/SNAPSHOT.md` is gitignored — a per-clone working note.

## Layout

```
Core/        shared platform-free engine, auto-mode state machine, trigram model, .strings reader (SwiftPM module ReLayoutCore)
macos/       macOS app — main.swift, tests.swift, Info.plist
windows/     Windows port — Win*.swift + main.swift, native/ (C++: UI Automation, WinHTTP, theme)
Resources/   macOS bundle resources — <lang>.lproj + icon PNGs + trigram/<lang>.txt
Tests/       SwiftPM engine tests
scripts/     build.sh, run-tests.sh, e2e.sh / e2e-win.ps1 (+ e2e/), make-cert.sh, make-dmg.sh, notarize.sh, trigram/
packaging/   Homebrew cask template + tap-push script, windows/relayout.iss (Inno Setup installer)
docs/        ARCHITECTURE.md, RELEASING.md, HISTORY.md, SNAPSHOT.md, BACKLOG.md, release-notes/
assets/      source art (rL-logo.svg) — not bundled
dist/        build output (.app/.dmg/.zip) — gitignored
```

## Commands

```sh
./scripts/make-cert.sh   # one-time: self-signed identity so Accessibility grant survives rebuilds
./scripts/run.sh         # dev loop: killall + dev build (traces to /tmp/relayout.log) + relaunch
./scripts/build.sh       # -> ReLayout.app (or "ReLayout (dev).app" for non-tag builds)
./scripts/run-tests.sh   # build & run unit tests (-DTESTING; entry point swaps to macos/tests.swift)
./scripts/e2e.sh         # macOS end-to-end: types into a test window against the dev build (hands off; needs Accessibility for the terminal)
./scripts/e2e-mac-vm.sh  # the same in a macOS test VM over SSH (keyboard stays free; setup in docs/ARCHITECTURE.md)
scripts/e2e-win.ps1      # on Windows: the same against dist\win built with -DebugLog (-Trace prints the key log on failure)
./scripts/demo-vm.sh setup|take       # demo take in the macOS VM: scripts/demo/scenario.swift played, screen + key/mouse log -> dist/demo/<take>/
swift scripts/demo/render.swift dist/demo/<take> out.mov   # cut: camera zooms, cursor, keycaps, captions; then make-demo-gif.sh
./scripts/make-dmg.sh    # -> reLayout.dmg drag-to-Applications installer
swift test               # cross-platform engine tests via SwiftPM (Tests/ReLayoutCoreTests)
scripts/build-windows.ps1  # on Windows: release build of the port into dist\win (exe + trigram/ + lang/)
```

Scripts `cd` to the repo root, so they work from anywhere. Build output (`ReLayout.app`, `reLayout.dmg`, `reLayout.zip`) lands under `dist/` (gitignored).

Dev vs release builds use **different bundle IDs** (base `RELAYOUT_BUNDLE_ID` vs the same + `.dev`) and different `.app` names so macOS keeps separate Accessibility grants and UserDefaults. Owner identity (bundle id, repo slug, Sparkle feed/key, tap) is **not hardcoded** — it comes from `RELAYOUT_*` env vars / CI repository variables / gitignored `scripts/identity.env` (copy `identity.env.example`), with neutral fallbacks for identity-less dev builds.

Build env vars, the release/notarization flow, and the full architecture (engine algorithm, macOS file map, Windows port) live in **[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)**. Release secrets are in [`docs/RELEASING.md`](docs/RELEASING.md).

## Architecture (one screen)

- **`Core/Engine.swift`** — platform-free conversion engine (no AppKit/Carbon/WinSDK). Shared verbatim by the macOS app, the Windows port (`ReLayoutCore` SwiftPM module), and the tests. Algorithm: `char → (reverse source layout) → KeyStroke → (target layout) → char`, over the actually-installed layouts. Not a char→char table.
- **`Core/Trigram.swift`** — char-trigram language model for the auto-correct mode. Models generated offline by `scripts/trigram/gen.py`, shipped as `Resources/trigram/<lang>.txt`. Auto-correct fires between scripts (ru/uk ↔ en/de/fr/es/pl/pt; a layout whose language has no model gets no auto-correct) and, as an experimental opt-in, between same-script layouts of different languages (ru ↔ uk); default off.
- **`macos/main.swift`** — the macOS app (single file): localization, hotkey system (combos + modifier taps), AX-first selection read, synthetic-keystroke write, input-source switching, Settings/menu-bar/login-item, Sparkle.
- **`Core/Auto.swift`** — what both apps share beyond conversion: the auto-mode decision (`decideAutoTarget`), the typed-word state machine (`AutoRun`), the hotkey's layout choice (`planRetype`, `fixMixedWord`). `Core/Learned.swift`: the full auto decision chain (`autoDecision`) and the learned-verdict rules (`LearnedWords`). `Core/Boundary.swift`: the word-boundary step (`evaluateBoundary`), the Enter fix (`enterFixPlan`), which keys arm learning by revert (`mayEditText`). `Core/Retype.swift`: where the hotkey's text comes from (`retypeSource`). `Core/FieldCheck.swift`: the asynchronous password-field check. `Core/PressAgain.swift`: the press-again record. `Core/KeyGate.swift`: keys held during a fix. `Core/HotkeyTaps.swift`: multi-press and modifier-only hotkeys. Platform code only feeds keystrokes, stores the lists and performs what these return.
- **`windows/`** — Windows port: hook-based hotkey + auto mode, UI Automation read, Settings/tray, built only under `#if os(Windows)`. CI builds it on manual dispatch and on `v*` tags, attaching the unsigned installer and portable exe to the Release.

Details for each → [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Conventions worth knowing

- Work branches merge into the **local `main`** only (`git merge` in this checkout) — never merge or push a branch into `origin/main` directly. The user builds from the local checkout; a merge that lands only on origin leaves it stale.
- When changing the conversion algorithm or an auto-mode rule, edit `Core/` and add a test in `Tests/ReLayoutCoreTests/` — both platforms then pick it up. Don't duplicate engine code into `macos/main.swift` or `windows/`.
- Localizable keys: add to **every** `Resources/<lang>.lproj/Localizable.strings` — both apps read them, and `StringsTests` fails when a language lacks an English key. On macOS a missing key shows the key string itself.
- App icon and "rL" wordmark are generated inline by `scripts/build.sh` (a tiny Swift snippet using `NSImage`) from `Resources/for-{light,dark}-text-1024.png`. The menu-bar icon is appearance-aware (white on dark, black on light) loaded via `NSImage(named:)`.
- Carbon (`UCKeyTranslate`, `RegisterEventHotKey`) is intentional — there is no modern Swift replacement that exposes layouts at this level. Don't try to "modernize" it away.
