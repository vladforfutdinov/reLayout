# reLayout — History

Append-only chronology. Newest milestone on top. One block per coherent unit of
work (not per commit). Operational "where are we right now" lives in
[`SNAPSHOT.md`](SNAPSHOT.md), not here.

---

## v1.2.25 — trailing layout-mapped char converts; auto-correct off for one-script layouts

Fix `39c23f0`, settings `41b5fd1`, tests `1d43a8d`. User reports:
`rfhf,f[` (карабах), `vj]` (мої), `vj'` (моє), `vj«` (моё), `gj[j;` (похож) never
converted.

- Cause: `autoWordCore` refused any word whose last char is not a letter — the
  "`pyf.` is `знаю` or `зна.`" ambiguity rule. Scores were never the blocker
  (`карабах` -2.64 ru against the -3.0 punct gate). Comparing the two readings
  does not work either: `зна` outscores `знаю`, `мо` outscores `мої`.
- The user's argument settled it: a wrong-layout typist errs on punctuation too
  ("привет," arrives as `ghbdtn?`), so a trailing mapped char is the key pressed.
  A first attempt allowing only Unicode Ps/Pi (`[`, `«`) was dropped for that
  reason.
- English guard: the core check strips trailing punctuation too. Probed via a
  temporary `--selftest` block on the live ABC + Ukrainian-PC pair: 80 English
  negatives ending in mapped punctuation, 5 false fires, all a 2-letter core plus
  `.` (`vs.` -> `мію`, `cf.`, `Ph.`, `Vs.`, `Lt.`). `autoEvaluate` now judges length
  without the trailing mapped run, so those (and `vj]`) take the short-word path:
  converted only with a neighbouring correction. The user accepted that standalone
  `vj] ` stays as typed.
- Known: `yj;` (нож) scores -3.5 and stays below the -3.0 punct gate.
- **Settings:** with every enabled layout in one script (ABC + German) auto-correct
  can never fire — the v1.2.11 calibration found Latin↔Latin not viable, so
  `autoDecide` only takes other-script targets. The checkbox is now shown off and
  disabled (stored preference kept) with an ⓘ tooltip naming the enabled layouts.
  Iterated with the user: a click popover and a hover popover were tried and
  dropped for the system tooltip with `NSInitialToolTipDelay` = 0 (app-wide).
- **`LayoutPairTests`**: engine over real `UCKeyTranslate` dumps (QWERTZ, AZERTY,
  Dvorak, Czech/Kazakh digit-row letters, Polish, Turkish ı, Mac vs PC Russian
  comma, Russian→Ukrainian, Belarusian ў, Serbian, Latin→Georgian/Greek/Hebrew/
  Arabic). Probed but not fixed: Georgian/Greek/Hebrew/Arabic → Latin returns nil
  (`convertWrong` knows only Cyrillic vs not), `dominantScript` is nil for Greek
  text, Belarusian `'` is not auto-mode word material, Greek tonos is a dead key.

## v1.2.24 — auto-correct: punctuation trail, Return submits, stale run on click/shortcut

Shipped as `v1.2.24` from `main` (`54cd393`): the fix is `8a6e25d` (README and
ARCHITECTURE synced in it), notes `docs/release-notes/v1.2.24.md`; CI `build` and
`core` green, notes verified in the release body and the appcast. Started from the
user report "`ltkfq?` does not become `делай,`"; the follow-ups were diagnosed with
a `RELAYOUT_DEBUG` trace before any fix.

- **Trailing punctuation.** `?` is not word material on ЙЦУКЕН (it maps to `,`),
  so `autoFeed` cleared the buffer and the word was never judged. A first fix used
  a hard-coded `?!,.;:)` set and fired on the punctuation key; rejected by the user
  as a character table that breaks the layout-driven design. Now any
  punctuation/symbol after a word collects in `autoTrail`, the word is judged only
  at whitespace, and the trail is transliterated with it. `@`/`/` inside an
  address or path are never followed by whitespace, so they break nothing.
- **Return in Raycast** (trace: `sym` + Enter -> `інь`, wrong app launched). Two
  causes: the swallowed Return was retyped as a Unicode `"\r"` on key 0, which apps
  ignore, and the correction ran before the submit. Returning the real key alone
  still launched a search on the converted text. By the user's choice Return never
  corrects now; it only ends the run. Tab and replayed Return go out as real keys
  with Shift/Option (`typeKey`).
- **Held-key replay** typed all held text before feeding it, so a boundary inside
  the replay made the correction delete from the end of the screen, past its word.
  Each key is now fed before it is typed; keys after a firing boundary go back on
  hold. `boundaryTyped` removed.
- **"An earlier word appears at the start"**: the tap saw only keyDown, so the
  buffer and a pending preposition survived clicks, Cmd/Ctrl shortcuts and a chat
  Enter, and the next correction deleted text before the moved caret. Mouse-downs
  and Cmd/Ctrl combos now end the run.
- Open: `gateSince` is not refreshed across a chain of corrections (after 3 s the
  gate passes keys through); a click during a correction still replays held keys at
  the new caret; launchers still convert on space (no default exclusion).

## v1.2.23 — retype races closed, line grab converts one word, hyphen/apostrophe words

Shipped as `v1.2.23` from `main` (`6b2db27`): the fix is `9c9e92d`, README sync
`46ce4d0`, notes `docs/release-notes/v1.2.23.md`. Reported by the user as "half a
word converts, a space becomes the last character typed"; four independent causes,
each reproduced or measured before the fix.

- **Hyphenated words never fired in auto-correct** (user report: `rfrjuj-nj`
  stayed as typed). Three separate gates rejected them: `autoFeed` treated `-` as
  punctuation and cleared the word buffer mid-word, `autoWordCore` demanded every
  non-letter map to a Cyrillic letter (`-` maps to `-`), and the trigram score was
  floor-dominated — the models come from a plain word list, so all three trigrams
  spanning a hyphen are unseen (floor -16.4 each). Now: `isWordConnector` (`-`,
  `–`, `—`, and NOT the apostrophe — that is э on ЙЦУКЕН) keeps the run alive when
  the buffer is non-empty, `autoWordCore` skips connectors, `autoDecide` treats
  such a word as pure-letter, and `TrigramModel.score` scores hyphen parts
  separately, length-weighted. Measured on the shipped models: `rfrjuj-nj` ->
  `какого-то` margin 8.3, `rjt-xnj` -> `кое-что` 10.5, while `e-mail` stays at
  0.32 (below the 0.5 gate) and is left alone.
- **Same for the Ukrainian apostrophe** (`v\zrj` -> `мʼяко`), with one twist: it has
  no key of its own on a Latin layout, so the typed character is `\` and only the
  layout maps it to `ʼ` (U+02BC) — verified against the live Ukrainian-PC layout
  via `--selftest`. `mapsToConnector` reads that mapping, so `\` counts as word
  material in `feedsAsCyr`/`autoWordCore`, and `autoDecide` gates such a word as
  pure-letter (`pureFor`) instead of applying the mapped-punctuation floor — with
  the parts-scoring, `мʼяко` lands at -2.80 and would have failed the -3.0 gate.
  U+02BC/U+2019 are connectors; the ASCII `'` is not (it is э on ЙЦУКЕН).
- **Backspace desynced the word buffer from the screen** — the pattern the user
  isolated: type `g\'`, delete the `'`, type `æcf`, and only `æcf` converted. A
  keystroke that produces no letter ended the run (`autoBuffer = ""`), so a typo
  fixed mid-word split it in two; and had the buffer been kept instead, the retype
  would have deleted one character too many, splicing the fix into the text. Both
  failure modes are the same missing edit: `autoBackspace` now drops the last
  buffered character, and Option/Cmd+Delete (a word / the whole line) ends the run.
  Handled before the Cmd/Ctrl filter — Cmd+Delete used to slip past it untracked —
  and while the gate holds keystrokes, backspace un-types the last held character
  instead of reaching the app out of order.

- **The line-grab heuristic is gone** (user request). With nothing selected the
  hotkey grabbed the whole caret line and `lastWrongWindow` guessed which tail was
  "wrong" — anchor on the last letter, walk back over neutrals, stop at another
  script, trim a mid-word remainder. It guessed wrong on some lines and retyped
  text the user was not thinking about. Replaced by `caretWord(_:)`: the trailing
  run of non-whitespace, so mid-word punctuation (`кое-что`, `e-mail`, `d'jhl`)
  stays in the word. `convert` now also returns `replaced` (the run it actually
  converted) and `performRetype` narrows the grabbed selection to it — Right to
  collapse, then Shift+Left per character — so the head of the line is never
  retyped at all. Exception: the Cmd+X fallback has already cut the line, so there
  the head is typed back together with the conversion. Undo records whichever run
  was written.
- **The `a457c84` keystroke gate closed only one of four holes.**
- **Mixed injection points.** `postKey` posted at `.cghidEventTap` while
  `typeUnicode` posts at `.cgSessionEventTap` — two entry points into the same
  chain, the HID one upstream of the session one, so a delete posted first could be
  delivered after a character posted later. `autoCorrect` (deletes, then text) and
  `performUndo` (Shift+Left, then text) both depend on that order, with only a
  10–20 ms sleep between them. `postKey` now posts at `.cgSessionEventTap`: one
  queue, FIFO. This is the likeliest cause of the half-converted words.
- **The boundary keystroke raced its own correction.** The space that triggers
  `autoEvaluate` was returned from the tap unmodified and travelled to the app
  while `beginCorrection` was already posting deletes for it. The tap now swallows
  a boundary key that starts a correction (`autoFeed` returns "consumed"), and
  `autoCorrect` deletes the boundary only on the replay path, where it really is on
  screen (`boundaryTyped`). Explains the "space became the last typed character".
- **The hotkey retype had no gate at all.** `autoPending`/`autoHeld` existed only
  in the auto-correct tap, and that tap was installed only in auto mode, so
  `performRetype` — a much longer sequence (AX read, Cmd+C/Cmd+X with 120 ms
  sleeps, per-character typing) — ran with the user's keystrokes flowing straight
  into the field being rewritten. The keyDown tap is now installed whenever the app
  is live (auto mode only decides whether keys also feed the word buffer), and
  `triggerHotkey` dispatches `performRetype` through `beginCorrection`.
- **Gate timeout.** With the hotkey path behind the gate, a retype that hangs on an
  unresponsive app would swallow keys indefinitely; the gate now passes keys
  through after `gateMaxHold` (3 s).

---

## v1.2.21 / v1.2.22 — release notes in the update window, typing race in auto-correct

- **The Sparkle "a new version is available" panel was blank.** `generate_appcast`
  was run on the archive alone, so the appcast item carried no `<description>` and
  the hand-written notes lived only on the GitHub release page, which the updater
  never shows. Fixed in `3e35f74`: `docs/release-notes/vX.Y.Z.md`, committed before
  the tag, is now the single source. The tag build prepends it to the release body
  (`gh release create --notes-file` alongside `--generate-notes`, so the auto
  `Full Changelog` link survives) and renders it through the GitHub `/markdown` API
  into `reLayout.html` next to `reLayout.zip` — `generate_appcast` embeds a
  `DOCTYPE`/`body`-less HTML sibling of the archive as the item description, so no
  markdown converter and no hosting for the notes are needed. Sparkle 2.6.4's
  `generate_appcast` reads only `.html`/`.txt` siblings (`.md` support is later
  than the pinned version), hence the render step. `/release` grew a step for the
  file; `RELEASING.md` documents the flow.
- **Fast typing raced the retype** (user report): keys pressed while a finished
  word was being corrected landed between the synthetic deletes and the retype, so
  the fix was spliced into the new text and the wrong characters got converted. The
  auto-mode tap was `.listenOnly` and `autoCorrect` runs async on `worker`, so
  nothing held the keystrokes back. Fixed in `a457c84`: the auto tap is now a
  `.defaultTap`; while a correction is in flight (`autoPending`, bumped in
  `beginCorrection` on the tap's thread before the dispatch) the callback swallows
  text-producing keys into `autoHeld` and returns nil, and `finishCorrection` types
  them back and re-feeds them through the word buffer once the queue drains. A
  replay that itself hits a word boundary just starts another gated correction.
  Only character keys are held — modifiers, Globe, arrows and delete always pass
  through, so a stuck correction can never freeze the keyboard.
- **Shipped as two tags on purpose** (to verify the appcast change against a real
  updater before the behavior change rode along): `v1.2.21` from branch
  `release/v1.2.21` (`5e9cb43`, notes machinery only, no engine/app change) and
  `v1.2.22` from `main` (`86171be`). Both CI `build` runs green; the notes were
  confirmed in the release body, in `appcast.xml` on `gh-pages` (`f3691e9`), and in
  the live Sparkle panel updating 1.2.20 → 1.2.21.
- **Note for future notes:** GitHub renders in GFM mode, so hard line breaks inside
  a bullet become `<br>` in the update window. Write each bullet as one long line.

---

## v1.2.20 — mid-word layout switch (auto-correct + hotkey)

- **`"ghj" + [layout switch] + "сто"` stayed `"ghjсто"`** (user report). Switching
  the layout in the middle of a word leaves ONE word carrying both scripts, and
  every auto-correct path assumed a single-script word: `convertWrong` (called from
  `autoDecide`) converts whole tokens through the active layout, so the Latin run
  `ghj` — typed on a layout that is no longer current — passed through unmapped,
  the score stayed junk, and nothing fired.
- **The Globe key itself broke the run.** Before any of the scoring mattered:
  `autoFeed` treated a keystroke that produces no character as "punctuation /
  navigation" and cleared the word buffer, and the Globe/fn layout switch is
  exactly such a key. So "ghj" was dropped at the switch and only "сто" — a plain
  Russian word — reached `autoEvaluate`. Empty input now returns without touching
  the run (⌘Space switching was already safe: Cmd-flagged events never reach the
  feed).
- **Fix — sub-word conversion.** New engine `convertScriptRuns(_:src:dst:)`
  converts every maximal run of `src`-script letters and leaves the rest verbatim.
  `autoDecide` gets a mixed-word branch that tries both readings of such a word:
  fix the pre-switch run into the current script (`"ghjсто"` → `"просто"`, target
  stays the current layout — no input-source switch) or fix the current-layout run
  into the cross-script candidate; each is scored under the model of the script it
  ends up in and must clear the usual margin. Mixed words carrying punctuation are
  left alone — the existing shape gates (`autoWordCore`) reason about a
  single-script word.
- **Hotkey path too.** `lastWrongWindow` anchors on the line's last letter and
  trims a mid-word remainder, so a mixed token windowed to nothing — the hotkey did
  nothing at all on "ghjсто". Two changes: engine `convertWrong` now routes a
  mixed-script token through `convertScriptRuns` (converting it whole dragged the
  already-correct half through an unrelated layout), and `convert()` intercepts the
  caret word (line grab) or a single-word selection with `mixedWordFix`. Which half
  is wrong is *not* decidable from the layouts: "ghjсто" wants its head fixed
  ("просто"), "мирqwerty" its tail ("мирйцукен"), and the two are structurally
  identical — head in the non-current script, tail in the current one. So both
  readings are scored with the trigram models and the better one wins (measured on
  the shipped models: просто −1.3 vs ghjcto −9.5; мирйцукен −5.8 vs vbhqwerty
  −10.6). No confidence gates there — unlike auto-mode the hotkey is an explicit
  user request. Windows keeps the `convertWrong` half of the fix; it has no trigram
  path of its own.
- Landed as `3534db4` (engine + macOS + tests), docs `c599b9d` / `31e38e9`.
  Released **v1.2.20**: ff-merge to `main`, tag pushed, hand-written notes +
  auto Full Changelog applied; tag `build` and `core` CI green, dmg/zip
  published, appcast + cask bumped. Confirmed live by the user on the dev build
  ("просто").

---

## v1.2.19 — auto-correct: short prepositions via adjacency

- **`"d ljhjut" → "d дороге"` fixed** (user report: "пропускает первый символ
  слова… как правило, предлоги"). Nothing was truncated — `дороге` was complete;
  the preposition `d`→в was simply left in the wrong layout. Three gates blocked
  1-2 char words: `autoDecide` and `autoEvaluate` both required `count >= 3`, and
  engine `autoWordCore` separately requires `letters >= 2`. So every short
  preposition (в к с у на по за из от до …) never converted.
- **Fix — adjacency, not a blanket gate drop.** Measured trigram scores first
  (throwaway harness loading `Resources/trigram/{en,ru}.txt`): every wrong-layout
  preposition clears the garbage/margin gates by ~2.7+ (model pads `^^w$`, so
  short words score), while real English function words (`in on to is of`) score
  too high to fire — but a few short junk tokens (`vs`→мы) would false-fire if the
  gate simply dropped. So: `autoDecide` loses its `>= 3` guard and bypasses
  `autoWordCore` for pure-letter words (no punctuation ambiguity there); precision
  for short words moves to a new adjacency rule in `autoEvaluate`. A short
  candidate never fires alone — it's remembered (`autoPrev` run-state) and only
  converted when it borders a real same-script conversion. A following long word
  **swallows** a pending preposition into one delete/retype edit (folded into the
  undo record via `autoCorrect`'s new `swallow:` arg); a lone short junk token
  with no anchor is left untouched. One-neighbour lookback (a stacked pair fixes
  only the last preposition) — noted in-code with the widen-to-a-list path.
- Engine untouched (`Core/` unchanged); all logic in `macos/main.swift`. Tests
  46/46 + engine 19/19 green. Commits `43e4b53` (fix), `13a8c60` (ARCHITECTURE
  note). Shipped as tag `v1.2.19`.

## v1.2.18 — auto-correct: layout-mapped punctuation joins the word

- **`",ßkj" → ",ыло"` fixed** (user report). Auto-mode's key monitor treated every
  non-letter as a word-boundary reset, but on ЙЦУКЕН `,`=б `'`=э `;`=ж `[`=х —
  so "было" typed on US arrived as `,skj`, only `skj` was evaluated, and the fix
  left the comma behind. The same half-mangle hit every б/э/ж/х-initial word
  ("это", "жизнь", "хорошо"). Now `autoFeed` buffers a punctuation char when an
  enabled Cyrillic layout reads its key as a letter (decided by the live maps, no
  char table), and a new engine-level `autoWordCore` vets the shape before
  conversion. Guards, all placed on measured model scores (not vibes): trailing
  mapped chars never convert (`pyf.` is both "знаю" and "зна." — the trigram
  score gaps overlap in both directions on common words, so the ambiguous case
  keeps the old no-fire behavior); ≥2 real letters (per-language floor deltas
  otherwise fire on `"..."` → `"ююю"`); plausible-core suppression (`'hello`
  keeps its quote); and an absolute converted-side gate `autoPunctPlausible -3.0`
  for punctuation-bearing words (real fixes score ≥ −2.6, junk that beat the
  relative margin like `e.g` → `уюп` scored ≤ −3.8). Letters-only words run the
  exact pre-change pipeline. Engine tests + macos tests + `ARCHITECTURE.md`
  updated (`db176d2`).
- Tagged **v1.2.18** via `/release` (ff-merge of `claude/autoreplace-bkj-ylo-ced3e8`
  into main at `b6696bf`): hand-written notes + auto Full Changelog; tag `build`
  and `core` CI green, dmg+zip published, Sparkle appcast deployed. Live-plumbing
  smoke (type `,skj ` with auto-correct on) still manual-only.

## v1.2.17 — copy (not cut) explicit selections: smart cut ate a space

- **Leading-space swallow fixed.** User report: in some apps, converting a selected
  word glued it to the previous one (`просто ckjdj` → select `ckjdj` → `простослово`).
  Only the clipboard-fallback path could do this: it read the selection via `Cmd+X`,
  and smart cut-and-paste (Word's default, `smartInsertDelete` text views) deletes an
  adjacent space together with a cut word — outside the selection, so the app eats it
  invisibly and the retyped conversion lands flush. The AX path was immune (type-over
  replaces exactly the selection), hence "sometimes". Fix: an explicit selection is
  now read via `Cmd+C` — copy keeps the selection and typing replaces exactly it, so
  smart cut never fires; `Cmd+X` stays only for the no-selection line-grab, whose
  selection starts at the line start (nothing before it to eat). The sequence is
  C-then-X at most — still no `Cmd+C+C` pair for DeepL's watcher, preserving the
  reason `60042a8` chose cut. Synced `ARCHITECTURE.md` + `README.md` in the same
  commit (`d7779a3`); the dou-ua article's fallback paragraph rewritten in the
  `articles` repo (`5c69f72`).
- Tagged **v1.2.17** with hand-written release notes + auto Full Changelog; tag
  `build` and `core` CI both green. Manual smoke in a smart-cut app (Word) still
  pending — the keystroke plumbing has no unit coverage.

## v1.2.16 — no-selection line-grab + recorder-scoped hotkey gate

- **Implicit line-grab narrowing.** Pressing the hotkey with nothing selected grabs the
  caret line, which mixes already-correct text with the wrong-layout tail. New
  `lastWrongWindow(_:)` (`Core/Engine.swift`) anchors the wrong script on the line's last
  letter, walks back over same-script + neutral chars, stops at the first letter of another
  script, and trims a mid-word remainder. `convert(_:lineGrab:)` converts only that window
  and types the correct prefix back verbatim — fixing `привіт ghbdsn` (active uk) from
  mangling into `ghbdsn ghbdsn` to `привіт привіт`. Target selection factored into
  `pickTarget()`. Pure string function → hermetic tests, shared with the Windows port
  (`a405580`).
- **Hotkey focus-gate rescoped to the recorder field.** The hotkey was muted whenever the
  Settings (or Exceptions) window was key, so merely opening Settings disabled it. Replaced
  the window-level gate (`settingsIsKey`/`gateOnWindow`/`refreshConfigGate`/`setConfigKey`)
  with a flag tied to the shortcut recorder's capture state (`recordingHotkey`, set by
  `ShortcutField.onRecordingChanged`). `finalizeSequence` re-applies the hotkey mid-recording
  while the field is still focused, so the gate holds that re-apply off until the recorder
  stops. The hotkey is now live everywhere except while it's actually being recorded
  (`a405580`).
- **Engine tests switched to Ukrainian fixtures.** `EngineTests.swift` + `macos/tests.swift`:
  fixture key S maps to `і` (so `ghbdsn` ⇄ `привіт`), sample words Ukrainianized, the Option
  layer maps `ß/æ → є/ї` (the real `ß/æ ↔ ы/э` overlap stays documented in the README). Added
  9 `lastWrongWindow` cases. Gate green: 17 SwiftPM + 33 macOS (`3dfcfbf`).
- **README Privacy & Security + Credits.** Spelled out the data-handling guarantees behind the
  Accessibility grant (no network except the Sparkle update check, nothing written to disk in
  release, no telemetry, clipboard untouched, password fields skipped) and attributed the
  Hermit Dave *FrequencyWords* corpus (MIT) the trigram models derive from (`57d8597`, `ec74cdb`).
- **`/release` slash command + docs-sync discipline.** Added `.claude/commands/release.md` to
  run the release flow (preflight → doc-sync → hand-written notes → tag/push → apply notes while
  preserving the auto `Full Changelog` link → CI report), codifying that every tag ships written
  notes and current docs (`974ecbf`). Synced `ARCHITECTURE.md` + `README.md` to the line-grab and
  focus-gate changes (`6ad284d`).
- Released **v1.2.16** (notarized, Sparkle, Homebrew) with hand-written release notes. The
  companion dou.ua article (separate `articles` repo) was updated in step: Ukrainian-first
  calibration chart/table, corrected focus-gate passage, new line-grab paragraph.

## Website + identity rename (post-v1.2.13)

- Added a presentation landing page on the `gh-pages` branch (`index.html` + `logo.png`,
  alongside the Sparkle `appcast.xml`), served at
  [relayout.forfutdinov.com](https://relayout.forfutdinov.com/) by a DigitalOcean static
  site that deploys from `gh-pages`.
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
