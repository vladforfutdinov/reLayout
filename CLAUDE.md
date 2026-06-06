# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

reLayout is a tiny menu-bar macOS app (with a nascent Windows port) that retypes selected text in the correct keyboard layout — Punto/Caramba style. Hotkey → read selection → convert via the active OS keyboard layouts → type back → switch system input source. Press the hotkey again within ~1.5 s to undo.

## Session handoff (context across sessions)

Two files keep context between sessions — read both at the start of a session and after `/clear`, before starting new work:

- **[`docs/SNAPSHOT.md`](docs/SNAPSHOT.md)** — operational "where are we right now": what's done recently, in progress, known issues, next steps, test status, uncommitted work. **Overwrite sections each session — don't append.** This is a current-state snapshot, not a log.
- **[`docs/HISTORY.md`](docs/HISTORY.md)** — append-only chronology, newest milestone on top, one block per coherent unit of work (not per commit). This is the durable record.

At the end of a session (or before `/clear`): run **`/handoff`** — it updates `docs/SNAPSHOT.md` to the new current state and appends a `docs/HISTORY.md` block for any milestone completed. `docs/HISTORY.md` is committed (travels with the repo); `docs/SNAPSHOT.md` is gitignored — a per-clone working note.

## Layout

```
Core/        shared platform-free engine (SwiftPM module ReLayoutCore)
macos/       macOS app — main.swift, tests.swift, Info.plist
windows/     Windows MVP — Win*.swift + main.swift
Resources/   macOS bundle resources — <lang>.lproj + icon PNGs
Tests/       SwiftPM engine tests
scripts/     build.sh, run-tests.sh, make-cert.sh, make-dmg.sh, notarize.sh
packaging/   Homebrew cask template + tap-push script
docs/        ARCHITECTURE.md, RELEASING.md, HISTORY.md, SNAPSHOT.md
assets/      source art (rL-logo.svg) — not bundled
dist/        build output (.app/.dmg/.zip) — gitignored
```

## Commands

```sh
./scripts/make-cert.sh   # one-time: self-signed identity so Accessibility grant survives rebuilds
./scripts/build.sh       # -> ReLayout.app (or "ReLayout (dev).app" for non-tag builds)
./scripts/run-tests.sh   # build & run unit tests (-DTESTING; entry point swaps to macos/tests.swift)
./scripts/make-dmg.sh    # -> reLayout.dmg drag-to-Applications installer
swift test               # cross-platform engine tests via SwiftPM (Tests/ReLayoutCoreTests)
```

Scripts `cd` to the repo root, so they work from anywhere. Build output (`ReLayout.app`, `reLayout.dmg`, `reLayout.zip`) lands under `dist/` (gitignored).

Dev vs release builds use **different bundle IDs** (`com.vlad.relayout` vs `com.vlad.relayout.dev`) and different `.app` names so macOS keeps separate Accessibility grants and UserDefaults.

Build env vars, the release/notarization flow, and the full architecture (engine algorithm, macOS file map, Windows port) live in **[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)**. Release secrets are in [`docs/RELEASING.md`](docs/RELEASING.md).

## Architecture (one screen)

- **`Core/Engine.swift`** — platform-free conversion engine (no AppKit/Carbon/WinSDK). Shared verbatim by the macOS app, the Windows port (`ReLayoutCore` SwiftPM module), and the tests. Algorithm: `char → (reverse source layout) → KeyStroke → (target layout) → char`, over the actually-installed layouts. Not a char→char table.
- **`macos/main.swift`** — the macOS app (single file): localization, hotkey system (combos + modifier taps), AX-first selection read/write, input-source switching, Settings/menu-bar/login-item, Sparkle.
- **`windows/`** — Windows MVP (`WinLayout`/`WinInput`/`WinTray` + `main.swift`), built only under `#if os(Windows)`.

Details for each → [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Conventions worth knowing

- When changing the conversion algorithm, edit `Core/Engine.swift` and add a test in `Tests/ReLayoutCoreTests/EngineTests.swift` — both platforms then pick it up. Don't duplicate engine code into `macos/main.swift`.
- Localizable keys: add to **every** `Resources/<lang>.lproj/Localizable.strings`. Missing keys fall back to the key string itself, which ships visibly broken UI.
- App icon and "rL" wordmark are generated inline by `scripts/build.sh` (a tiny Swift snippet using `NSImage`) from `Resources/for-{light,dark}-text-1024.png`. The menu-bar icon is appearance-aware (white on dark, black on light) loaded via `NSImage(named:)`.
- Carbon (`UCKeyTranslate`, `RegisterEventHotKey`) is intentional — there is no modern Swift replacement that exposes layouts at this level. Don't try to "modernize" it away.
