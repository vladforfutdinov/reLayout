# reLayout — Backlog

Committed, repo-travelling backlog of planned-but-not-started work. Operational day-to-day state lives in the gitignored `docs/SNAPSHOT.md`; durable history in `docs/HISTORY.md`. Move an item out of here once it's in progress.

## Remember the key layouts per app and per session (3+ layouts)

With three or more layouts enabled (ABC + Russian + Ukrainian) every switch is a cycle, and both the hotkey's press-again cycle and auto-correct's target choice guess from the text alone. Think through remembering which two layouts the user actually works with in a given app (and lately), so the first guess is right and the user is not walked through every layout.

**Why:** typing in Telegram is ru ↔ en, in a Ukrainian document uk ↔ en; the trigram models cannot separate ru from uk on common words, but the app and the recent history can. A remembered pair also means the hotkey converts straight into the usual layout and the cycle rarely goes past one press.

**Open questions:** what to key on (bundle id / exe, plus the layout the user left the app in, plus the last N manual switches); how a session decays (idle time? focus change? app restart?); whether a remembered pair is a strong prior (ranks the candidates) or a hard filter (hides the third layout); how it meets the learned-words store (both are "the user's own verdicts"); how it shows in Settings, if at all. Not a dictionary of languages, consistent with the no- dictionary rule. Measure before shipping: count how often the cycle goes past the first alternative today (a debug counter in the trace would do).

**Steps:** instrument first (per-app layout switches and cycle depth in the trace), look at a week of data, then design the prior; engine side stays in `Core/Auto.swift` as an input to `bestConversion`/`decideAutoTarget`, storage per platform like the learned words.

## Auto-correct waits for a typing pause (decide after the timing data)

Today auto-correct fixes a word at its boundary and holds the keys typed meanwhile, replaying them afterwards (in the layout the fix switched to, `d61b78a`). Consider the alternative: when the user types faster than a fix lands, wait for a pause and fix the whole typed run at once.

**Why:** no keys held mid-typing, so no felt stall; the run is fixed in one erase-and-type. With the whole run in hand, each word can be decided on its own — and with the layout recorded per key, a run where the user switched layout by hand mid-word (`j,` + switch + `новлен`) is still read correctly instead of being broken by a fix that landed in the middle of it. Against: the wrong text stays on screen longer, the user keeps typing in the wrong layout, and the erase grows with the run.

**Gate:** only if the trace timings (`d058e50`: `timing:` and `timing fix:` lines, macOS) show fixes regularly losing the race to typing. If the long stalls are rare and come from the spell checker's guesses, cap those first (Windows already has a 50 ms suggestion budget) and drop this item.

**Steps:** collect a week of timings; count boundaries where keys were held (`hold` lines) and how long; decide; if it goes ahead, the pause detection and per-word re-decision belong in the engine (`AutoRun` in `Core/Auto.swift`) so both platforms share them.

## Windows keyboard in the landing demo

The hero demo on the landing page (`index.html` on `gh-pages`) draws a Mac keyboard row — fn, control, option, command — with the ⌥ key lighting up as the hotkey. Add a Windows variant: Ctrl, Win, Alt, with the Windows default hotkey lit.

**Steps:** a second key row in the `.kb` block, shown for Windows visitors by the same OS detection that already makes "Download for Windows" the primary button (`navigator.userAgentData.platform` / `navigator.platform`); the animation script highlights the hotkey key per variant. Do it after the default hotkey above is settled, so the demo shows the real one.

## Wide trigram model set

Generate trigram models for ~40–60 langs (all Cyrillic + common Latin from the Hermit Dave *FrequencyWords* corpus) and commit them to `Resources/trigram/`, so auto-mode works for far more language pairs than the current 8 (`de en es fr pl pt ru uk`).

**Why low-cost:** the lazy bundle loader (`macos/main.swift`) and the build copy step (`scripts/build.sh`, trigram `cp -R`) already handle any `Resources/trigram/<lang>.txt` — no Swift and no build-script change. The whole task is a generation script + committed model files + a docs note.

**Steps:**
1. Write `scripts/trigram/build-all.sh`: a curated lang list + alias map (e.g. macOS `nb` → FrequencyWords corpus `no`), download corpora to the gitignored `scripts/trigram/corpora/` (prefer `<code>_50k.txt`, fall back to `_full.txt`), run the existing `gen.py` per lang → `Resources/trigram/<lang>.txt`, skip-and-warn on a missing corpus, print a summary. Reuse `gen.py` as-is.
2. Run it; sanity-check output format vs `ru.txt` (`# …` comment, `floor <n>`, sorted `trigram <logprob>` lines).
3. `swift test` (engine unchanged — guards against accidental edits) + `./scripts/build.sh`; confirm the `.app` bundles the full `Contents/Resources/trigram/` set.
4. Update README's Auto-correct section: wide set, regenerated via `build-all.sh`.

**Caveats:**
- Auto-mode is **cross-script only** by default (same-script ru↔uk is an experimental opt-in, `autoSameScript`) — Latin↔Latin pairs never auto-fire. Wide Latin set serves as cross-script targets + source-language junk models, not Latin↔Latin correction.
- Thresholds `autoGarbage`/`autoMargin` (`Core/Auto.swift`) and `calibrate.py` are tuned for ru/uk↔en only; new pairs reuse them un-recalibrated. Acceptable (cross-script detection is robust); a future task could extend `calibrate.py`.
- Repo + `.app` grow ~9 MB.

## Windows: a triple-clicked line counts as no selection

Windows `readSelection` treats any copy that ends in a line break as "no selection", so a line selected by triple click is ignored and the hotkey falls back to the typed word.

**Why:** the rule guards against VS Code copying the whole line when nothing is selected; macOS tells the two apart by VS Code's `"isFromEmptySelection":true` clipboard metadata (`org.chromium.web-custom-data`) instead of the trailing newline.

**Steps:** read the same Chromium custom-data format on Windows (clipboard format registered as "Chromium Web Custom MIME Data Format") and drop the trailing-newline rule; verify in VS Code and a plain editor in the VM.
