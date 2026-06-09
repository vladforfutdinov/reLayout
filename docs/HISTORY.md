# reLayout — History

Append-only chronology. Newest milestone on top. One block per coherent unit of
work (not per commit). Operational "where are we right now" lives in
[`SNAPSHOT.md`](SNAPSHOT.md), not here.

---

## Website + identity rename (post-v1.2.13)

- Added a presentation landing page on the `gh-pages` branch (`index.html` + `logo.png` +
  `CNAME`, alongside the Sparkle `appcast.xml`), served at the custom domain
  [relayout.forfutdinov.com](https://relayout.forfutdinov.com/).
  Self-contained single file (dark theme, animated wrong→right demo over a Mac keyboard,
  bento features, a "How it compares" table, Homebrew + DMG install). Iterated through
  the `design-taste-frontend` skill for an anti-slop pass.
- Renamed the bundle id `com.vlad.relayout` → **`com.vladforfutdinov.relayout`** (dev:
  `.dev`) across `build.sh`, `Info.plist`, the Homebrew cask zap path, and docs. Note:
  this resets the Accessibility grant + saved UserDefaults on first launch of the renamed
  build (macOS treats it as a new app).
- Aligned the author name to **Volodymyr Forfutdinov** (appcast commit identity, Windows
  installer publisher) to match the app copyright and the site. Added the MIT `LICENSE`.

## v1.2.13 — per-app auto-correct exceptions

- Auto-correct's hardcoded terminal/IDE exclusion set became a user-editable deny-list
  (`autoExcludedApps` in `UserDefaults`, seeded with the old defaults) (`e88999d`).
- "Exceptions…" button (next to the Auto-correct checkbox) opens an editor presented as a
  **sheet** on Settings — modal to it (`fed34de`). Add apps via "Exclude current app" (the
  last non-self frontmost app, tracked via `didActivateApplication`; stored as a bundle-id
  string after a weak-ref bug nilled it) or "Choose…" (`NSOpenPanel`). Remove via a per-row
  button that appears on hover (`ExcRowView` + `NSTrackingArea`, `68e6faa`).
- The hotkey/auto focus-gate now covers both config windows (Settings + Exceptions),
  recomputed from the actual key window (`37fe683`, `fed34de`).
- `settings.exc.*` localization across all 12 languages. Tagged **v1.2.13**.

## v1.2.12 — Settings rework (single window, three sections)

- Merged the standalone About panel into the Settings window: one auto-sizing window
  (logo / name / sections / footer); removed `showAbout`, `aboutResignObserver`,
  `menuGlyphImage` (`112ba26`, later cleanup `7168935`).
- Fixed the window opening invisible (content view had no width constraint →
  `fittingSize` collapsed) — pin the stack on both sides + auto-fit width
  (`879f303`, `e384b3a`).
- Regrouped into three separator-divided sections: login + auto-update + language /
  auto-correct + hotkey / version + link + copyright (`52c27e3`). Checkbox rows and
  grid captions left-aligned, logo/name/footer kept centered, Hotkey caption
  vertically centered with the field (`82b467f`, `0eccd12`). Hotkey field width ==
  language popup (`034bbed`).
- `Cmd+W` (close) and `Cmd+Q` (quit) handled in `SettingsWindow` by physical keyCode
  so they work on any layout (no main menu in an agent app) (`8e693b1`, `0d85bf3`,
  `554ff9b`). First checkbox no longer grabs focus on open (`c979861`).
- Tagged **v1.2.12**.

## v1.2.11 — auto-correct mode + tap-sequence hotkey

- **Auto-correct (trigram detector).** Phase 0: char-trigram language model
  (`Core/Trigram.swift`) + offline calibration (`scripts/trigram/gen.py`,
  `calibrate.py`) sweeping θ_garbage/θ_margin for ≥99% precision; confirmed
  Latin↔Latin (de/fr/es) not viable, so the mode is **cross-script only** (ru/uk ↔ en)
  (`363808d`, `cf5f12c`). Phase 1: decision logic + bundled models in
  `Resources/trigram/`, then a live `keyDown` monitor that auto-fixes the last word;
  default **off** (`098f040`, `4542cc9`). Engine gained `dominantScript` /
  `textHasScript` (`Core/Engine.swift`).
- **Hotkey is now a recorded tap-sequence** — dropped the "Trigger on double-tap"
  checkbox; the recorder accumulates N taps within a window (`b08782a`). Reset works
  mid-recording; Esc closes Settings instead of cancelling (`71be83a`, `aaacfe4`).
  Press-again-undo simplified — the standalone double-tap-to-undo hint removed
  (`b234723`, `cf6e002`).
- **Focus-gate fix:** live hotkey + auto-correct suspended while the Settings window
  is key — committing a tap-sequence no longer re-arms the hotkey under the still-
  focused recorder (which fired a retype and fed the synthetic Cmd+X back into the
  field) (`5d97a22`, `5355bc3`).
- Removed the "Keyboard settings" menu item (`d8040b7`). CI appcast commits now
  authored by the repo owner — no stray bot/user contributor (`343c1d2`, `f11d85d`).
- **Refactor, no behavior change:** extracted `installEventTap`/`removeEventTap`,
  `makeCheckbox`/`makeSecondaryLabel`, `markSynth`, and Core `wordTokens`; removed 9
  unused localization keys (`6d0f5b6`, `7168935`).
- Tagged **v1.2.11**. (Windows excluded from tag releases — macOS-only.)

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
