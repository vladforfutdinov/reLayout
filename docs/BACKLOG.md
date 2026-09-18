# reLayout — Backlog

Committed, repo-travelling backlog of planned-but-not-started work. Operational
day-to-day state lives in the gitignored `docs/SNAPSHOT.md`; durable history in
`docs/HISTORY.md`. Move an item out of here once it's in progress.

## Windows default hotkey

Replace the Windows default `Ctrl+Alt+R` (`defaultHotkey`, `windows/WinPrefs.swift`)
with something closer to the macOS default, a tap of left ⌥.

**Why:** Ctrl+Alt is AltGr on many European layouts, so the combo can collide with a
character, and a three-key chord is heavier than the one-tap macOS default.
Candidates: a tap of a modifier (left Alt is safe — the port already replays a lone
Alt/Win release behind mask key 0xE8 so the menu bar doesn't open), right Ctrl, or a
double tap of Shift (not five: five Shift presses open Windows' Sticky Keys prompt).

**Steps:** pick the key; change `defaultHotkey`; existing users keep their saved
hotkey (registry `HotkeyMods`/`HotkeyVK`), only fresh installs change; update the
default named in `README.md` and in the landing page's Windows install steps
(`index.html` on `gh-pages`).

## Windows keyboard in the landing demo

The hero demo on the landing page (`index.html` on `gh-pages`) draws a Mac keyboard
row — fn, control, option, command — with the ⌥ key lighting up as the hotkey. Add a
Windows variant: Ctrl, Win, Alt, with the Windows default hotkey lit.

**Steps:** a second key row in the `.kb` block, shown for Windows visitors by the
same OS detection that already makes "Download for Windows" the primary button
(`navigator.userAgentData.platform` / `navigator.platform`); the animation script
highlights the hotkey key per variant. Do it after the default hotkey above is
settled, so the demo shows the real one.

## Wide trigram model set

Generate trigram models for ~40–60 langs (all Cyrillic + common Latin from the
Hermit Dave *FrequencyWords* corpus) and commit them to `Resources/trigram/`, so
auto-mode works for far more language pairs than the current 6 (`de en es fr ru uk`).

**Why low-cost:** the lazy bundle loader (`macos/main.swift:1433`) and the build
copy step (`scripts/build.sh:46`) already handle any `Resources/trigram/<lang>.txt`
— no Swift and no build-script change. The whole task is a generation script +
committed model files + a docs note.

**Steps:**
1. Write `scripts/trigram/build-all.sh`: a curated lang list + alias map (e.g. macOS
   `nb` → FrequencyWords corpus `no`), download corpora to the gitignored
   `scripts/trigram/corpora/` (prefer `<code>_50k.txt`, fall back to `_full.txt`),
   run the existing `gen.py` per lang → `Resources/trigram/<lang>.txt`, skip-and-warn
   on a missing corpus, print a summary. Reuse `gen.py` as-is.
2. Run it; sanity-check output format vs `ru.txt` (`# …` comment, `floor <n>`, sorted
   `trigram <logprob>` lines).
3. `swift test` (engine unchanged — guards against accidental edits) + `./scripts/build.sh`;
   confirm the `.app` bundles the full `Contents/Resources/trigram/` set.
4. Update the `docs/ARCHITECTURE.md` trigram paragraph (~line 53): wide set,
   regenerated via `build-all.sh`.

**Caveats:**
- Auto-mode stays **cross-script only** (`macos/main.swift:1449`) — same-script
  Latin↔Latin pairs never auto-fire. Wide Latin set serves as cross-script targets +
  source-language junk models, not Latin↔Latin correction.
- Thresholds `autoGarbage`/`autoMargin` (`macos/main.swift:1429`) and `calibrate.py`
  are tuned for ru/uk↔en only; new pairs reuse them un-recalibrated. Acceptable
  (cross-script detection is robust); a future task could extend `calibrate.py`.
- Repo + `.app` grow ~9 MB.
