# reLayout — History

Append-only chronology. Newest milestone on top. One block per coherent unit of
work (not per commit). Operational "where are we right now" lives in
[`SNAPSHOT.md`](SNAPSHOT.md), not here.

---

## Repo reorg + handoff docs

- Added cross-session context machinery: `CLAUDE.md` (lean onboarding) +
  `docs/SNAPSHOT.md` (operational state, overwrite) + `docs/HISTORY.md` (this file,
  append-only). Deep reference split into `docs/ARCHITECTURE.md`.
- Reorganized the tree: scripts → `scripts/`, macOS sources (`main.swift`,
  `tests.swift`, `Info.plist`) → `macos/` (mirrors `windows/`), docs → `docs/`,
  source art (`rL-logo.svg`) → `assets/`. Build output (`.app`/`.dmg`/`.zip`) now
  lands under `dist/` (gitignored) instead of the repo root. `Core/`, `Tests/`,
  `Resources/`, `windows/`, `packaging/` unchanged.
- Updated all path references: `scripts/*.sh` internals (`cd` to repo root, source
  paths), `build.yml` CI invocations, README / RELEASING / ARCHITECTURE / CLAUDE.
  Build + tests re-verified green post-move.

## Windows port — Phase 2b MVP (current arc)

- Extracted the platform-free conversion engine into `Core/Engine.swift`; macOS app
  + Windows port + tests all consume it (`215bc45`, `f4f7ba7`).
- SwiftPM `Package.swift` exposes `ReLayoutCore`; cross-platform engine tests run on
  macOS and Windows CI (`core.yml`).
- `WinLayout` builds `LayoutMaps` via `ToUnicodeEx`; lists/switches HKLs (`ee4a7d7`,
  `cb140aa`).
- Windows MVP: hotkey (Ctrl+Alt+R), clipboard read, `SendInput` write, layout switch
  (`d338c68`), system tray with right-click Quit (`f96905c`, `8925c37`).
- CI: bumped Windows Swift toolchain to 6.1 (ucrt module-cycle fix, `d98432b`).
- **Open:** UI Automation selection read (clipboard-only now), Settings UI, Windows
  release packaging + signing in CI, storage adapter (Registry/AppData).

## v1.2.6 — mod-tap correctness

- Mod-tap ignores cycles where an out-of-set modifier appeared, so Option+Control no
  longer spuriously fires a retype (was triggering DeepL) (`eecff27`).

## Distribution pipeline (v1.2.x)

- Developer ID signing + notarization (App Store Connect API key) + staple in CI
  (`4160320`, `4941d87`).
- Sparkle auto-update for release builds; real `SUPublicEDKey`; Settings checkbox +
  "Check for Updates" menu item (`cb61f8f`, `7375244`, `c0cea4b`).
- Homebrew cask + CI tap auto-bump via SSH deploy key (`db046be`, `54630f1`).
- Dev vs release split: distinct bundle id + suffixed `.app` name so macOS keeps
  separate TCC grants / prefs (`a506346`, `17f7f04`); About shows full git version
  (`ffab7e6`).
- Build fixes: brace-delimit `$SPARKLE_VERSION` (C-locale unbound var, `e94f962`),
  retry `hdiutil` on transient busy (`f72fb05`), drop Node-20 JS actions (`902a5e6`).

## Icons

- App icon (keycap) → rL wordmark; opaque tile so it's visible in Sparkle/Finder
  (`5504905`, `776d1ed`, `766ee12`).
- Menu-bar icon: live layout-state mode or static template icon, appearance-aware
  (`3fa3e3e`, `f459ced`, `4276476`).

## Localization + UI (RuSwitcher gap-closing)

- 12-language localization; language list derived from shipped `.lproj` bundles
  (`deeee10`, `40c2e09`).
- Language picker in Settings, undo hint, spacing/focus polish (`527b2d3`, `f6610b3`,
  `9a82453`, `2d655db`).
- Double-tap undo to reverse the last conversion (`5ddbbd6`).

## Apple HIG + quality pass

- HIG + accessibility polish for menu and Settings; standard About panel
  (`5aaf867`, `a49b0e8`).
- Unit-test harness for the conversion engine + hotkey helpers (`c6fd5b6`).
- Fixes: stop clipboard wipe on AX path, guard AX downcasts (`8fe11da`); never write
  selected text to `/tmp` in release builds (`436c6b1`); cache enabled-layout list
  (`6de830c`).

## Initial build (v1.0.0)

- macOS menu-bar layout-retype tool: hotkey → read selection → convert via active OS
  layouts → type back → switch input source (`b3cf89b`).
- Caramba-style write + AX-strict read (`80d3b80`); HIG settings + inline shortcut
  recorder, default = tap left Option (`65498ee`).
- Versioning from git tag; GitHub Actions build + release on tag (`ecb7c9f`,
  `26d4d51`, `c62e247`).
