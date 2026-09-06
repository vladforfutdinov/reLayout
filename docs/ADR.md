<!-- Exported from codebase-memory-mcp manage_adr on 2026-09-06. Source of truth is this file; re-import with manage_adr(mode="update") after editing. -->

# ADR — relayout

## Context

reLayout is a keyboard-driven "retype the selection in the correct layout" utility
(Punto/Caramba-style): a macOS menu-bar app (`macos/main.swift`, ~98K) and a Windows
tray-app port (`windows/*.swift`), sharing one conversion engine (`Core/Engine.swift`,
`ReLayoutCore`) built/tested cross-platform via SwiftPM (`Package.swift`, `core.yml`).
v1.2.x; released via Homebrew cask and signed/notarized GitHub releases
(`RELEASING.md`, `scripts/`). Past decisions/fixes: `docs/HISTORY.md`.

## Decisions

1. **Shared engine as a SwiftPM library; platform shells are separate targets.**
   `Core/Engine.swift` (`convertWrong`, `tokenize`, `hasCyr`/`hasLatin`,
   `convertScriptRuns`) is the `ReLayoutCore` library; `macos/` and `windows/` import it.
   *Rationale:* one engine, two UIs — `swift test` validates the same logic on both
   OSes (`core.yml`), so a bug fixed once is fixed everywhere.
   *Consequence:* the macOS shell isn't SwiftPM-built (#2) — the engine is the only
   piece both build systems share; keep new cross-platform logic in `Core/`.

2. **macOS app is a single `main.swift`, built by a shell script, not Xcode/SwiftPM.**
   `macos/main.swift` + `Info.plist` is the whole app; `scripts/build.sh` runs
   `swiftc` directly into a `.app` bundle.
   *Rationale:* a menu-bar-only app with no storyboard needs no Xcode project; one
   file keeps the event-tap/hotkey/menu/settings surface in one place to grep.
   *Consequence:* no per-feature file boundaries — the `main` package (123 nodes) is
   one flat namespace; symbol tools (`get_function_source`), not "open the file",
   are how it's navigated.

3. **CGEventTap + synthetic `CGEvent` posting**, not the Accessibility text-replace
   API. `postKey` (main.swift:1363) builds keyDown/keyUp events tagged via
   `markSynth`, posted at `.cghidEventTap`.
   *Rationale:* works uniformly regardless of whether the target app exposes an AX
   text API; looks like a human retyping.
   *Consequence:* needs the Accessibility permission (`promptAccessibilityIfNeeded`,
   called from `applicationDidFinishLaunching`); every self-generated event must be
   marked so the tap doesn't reprocess its own output (ties into #5).

4. **Mid-word script-run splitting, not whole-token transliteration.**
   `convertWrong` (Core/Engine.swift:214) special-cases a token with both Cyrillic
   and Latin: only the wrong-script runs go through `convertScriptRuns`.
   *Rationale:* a user who switches layout mid-word keeps the already-correct half
   from being dragged through an unrelated conversion table.
   *Consequence:* `convertScriptRuns`/`hasCyr`/`hasLatin` are the top hotspots after
   `convertWrong` — layout-mapping changes must be checked against both paths.

5. **Auto-correct gates keystrokes during a correction instead of racing them**
   (v1.2.22, `docs/HISTORY.md`). Tap switched `.listenOnly` → `.defaultTap`;
   `autoPending` (set synchronously in `beginCorrection`) makes the callback buffer
   text keys into `autoHeld` while `worker` corrects async; `finishCorrection`
   replays them.
   *Rationale:* async correction + async typing could interleave, splicing new
   keys into a synthetic retype.
   *Consequence:* only character keys are held (modifiers/arrows/delete pass
   through, so it can't freeze input) — new auto-correct code must respect
   `autoPending`/`autoHeld` or reintroduce the race.

6. **No enforced Windows/macOS parity beyond the shared engine.** `windows/`
   reimplements hotkeys (`WinHotkey`), input (`WinInput`), tray (`WinTray`),
   settings (`WinSettings`), prefs (`WinPrefs`) independently; only `ReLayoutCore`
   is shared.
   *Rationale:* the two OSes' input/tray APIs share nothing — a forced abstraction
   over CGEventTap and the Win32 message loop would be the wrong DRY.
   *Consequence:* platform bugs (e.g. #5's race) must be ported to `windows/` by
   hand; nothing enforces it.

7. **Release notes and signing live in versioned files, not the release UI.**
   `docs/release-notes/vX.Y.Z.md` is the single source for both the GitHub release
   body and the Sparkle appcast (`generate_appcast` + GitHub's `/markdown` API);
   signing/notarization scripted (`scripts/make-cert.sh`, `notarize.sh`,
   `make-dmg.sh`), documented in `RELEASING.md`.
   *Rationale:* Sparkle 2.6.4's `generate_appcast` only reads `.html`/`.txt`
   siblings — hand-written GitHub notes alone are invisible to the in-app updater.
   *Consequence:* skipping the notes file ships a blank "update available" panel.

## Module map

| File / cluster | Responsibility | Entry points |
|---|---|---|
| `Core/Engine.swift` | Conversion engine: tokenize, script detection, transliteration | `convertWrong`, `tokenize`, `convertScriptRuns`, `hasCyr`, `hasLatin` |
| `macos/main.swift` | Whole macOS app: menu-bar, event tap, hotkeys, settings, Sparkle | `applicationDidFinishLaunching`, `installHotKeyHandler`, `postKey`, `performRetype`, `autoCorrect` |
| `windows/WinHotkey.swift` | Global hotkey registration (Win32) | `applyHotkey`, `loadHotkey` |
| `windows/WinInput.swift` | Synthetic keystroke injection | `sendUnicode`, `keyEvent` |
| `windows/WinTray.swift` | System-tray icon/menu | — |
| `windows/WinSettings.swift` | Settings dialog | `settingsWndProc`, `buildControls` |
| `windows/WinPrefs.swift`, `WinLayout.swift` | Prefs persistence; layout enumeration | — |
| `windows/main.swift` | Windows entry point / message loop | `main` |
| `Tests/`, `macos/tests.swift` | Cross-platform engine tests; macOS app tests | — |
| `scripts/`, `.github/workflows/` | Build/sign/notarize/release scripts; CI | `build.sh`, `make-dmg.sh` |

## Hotspots & risks

- `Core.Engine.convertWrong` (15 callers) is the single highest fan-in symbol — a
  regression here is global. `hasCyr`/`hasLatin` (7 each), `convertScriptRuns` next.
- `macos.main.L`/`dbg` (11/8 fan-in) are broad logging helpers — high fan-in partly
  reflects the flat-file structure (#2), not a smell alone.
- Accessibility permission is a hard dependency for the macOS event tap (#3); a
  revoked grant silently breaks retype/auto-correct with no engine-level signal.
- `main → Engine` and `tests → Engine` dominate cross-package calls, confirming the
  engine as the real shared core (per-platform clusters cohere at 0.87–0.98).
- No enforced parity check (#6): a macOS-only fix (v1.2.22 race) can leave
  `windows/` with the same latent bug.

## Conventions

- Tests: `swift test` runs `ReLayoutCoreTests` on both OSes via `core.yml`; macOS-only
  behavior via `macos/tests.swift` (`scripts/run-tests.sh`).
- History: `docs/HISTORY.md` is append-only, one block per coherent unit of work,
  newest on top; day-to-day state lives in `docs/SNAPSHOT.md` instead.
- Releases: tag-triggered (`build.yml`), process in `RELEASING.md`; notes go under
  `docs/release-notes/` before tagging.

## Open questions

- Is there any check (manual or CI) catching a macOS-only fix needing a Windows
  port, or is parity purely best-effort (#6)?
- Does `scripts/identity.env` vs `identity.env.example` imply signing secrets
  expected locally/in CI, documented for a new release contributor?
- `macos/main.swift` (~98K) is the largest maintenance surface — is a split ever
  planned, or is the single-file shape (#2) considered permanent?
