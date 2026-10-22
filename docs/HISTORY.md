# reLayout — History

Append-only chronology. Newest milestone on top. One block per coherent unit of work (not per commit). Operational "where are we right now" lives in [`SNAPSHOT.md`](SNAPSHOT.md), not here.

---

## After v1.3.16 — more of both apps' rules in Core

- `planRetype` lost its unused `replaced` field. New in Core: `retypeSource`
  (selection / typed word / clipboard probe / nothing), `mayEditText` (which
  keys arm learning by revert), `FieldCheck` (Windows' asynchronous password
  check: numbered questions, fail closed while pending), `enterFixPlan` (the
  word Return ended). Each with unit tests.
- Behavior changes, by unifying the two apps:
  - macOS probes with Cmd+C when accessibility says nothing is selected and
    nothing was typed (VS Code reports an empty selection for a real one).
  - macOS arms revert learning on Home/End/PgUp/PgDn; Windows no longer on
    Esc/Insert.
  - macOS merges new defaults into the hotkey exclusion list too (seen record
    `hotkeyExcludedDefaultsSeen`), as Windows did; a default the user removed
    stays removed.
- Verified: swift test 164, run-tests 39, Mac VM e2e 12/12, Windows VM build
  and e2e (plain and spell) clean twice. Right after the Windows VM rebooted,
  three runs each lost one different scenario (a word left unfixed); the base
  commit was not run cold, so a cold-UIA flake is the likely, unproven cause.

---

## After v1.3.16 — macOS e2e in a test VM over SSH

- Why: `e2e.sh` posts real key events and holds focus, so on the owner's Mac it
  takes the keyboard and screen. Ways that do not: the CI runner (only pushed
  code) and a local VM. Posting to a pid (`postToPid`) skips the session tap
  reLayout listens on; a second login session gets no input.
- `scripts/e2e-mac-vm.sh` → `scripts/e2e/vm-run.sh` in the VM; TCC grants moved
  to `scripts/e2e/grant-tcc.sh`, shared with the CI workflow; one-time setup in
  `scripts/e2e/vm-setup.sh`. VM: macOS 26.6.2 arm64, ssh alias `relayout-mac`,
  SIP off, passwordless sudo.
- Found on the way:
  - `softwareupdate` lists Command Line Tools 27.0 on macOS 26.6; installed,
    its compiler (6.3.3) refused its own SDK 27 (built with 6.4). The SDK of
    the VM's macOS major in the same tools works; vm-run picks it, vm-setup
    installs the tools for the VM's major. The 26.6 download crawled (~100 KB/s)
    and was stopped.
  - Started over SSH the harness counts as `sshd-keygen-wrapper`'s for TCC —
    the GitHub image grants that binary for the same reason. Grants carry each
    binary's real designated requirement now, not NULL.
  - `sudo` drops the environment: `SDKROOT` is passed to `e2e.sh` explicitly.
  - The VM has ABC + Ukrainian + Russian, so press-again cycles before it undoes;
    the macOS harness now checks that ("ghbdsn": привіт → привыт → back), as the
    Windows one does.
- Result: 12/12 in the VM, this Mac untouched. Not run: the CI workflow with
  `grant-tcc.sh` (needs a push), `vm-setup.sh` end to end (its steps ran by hand).

## After v1.3.16 — boundary step, press-again and Windows modifier taps in Core

- 1: Windows' `HotkeyDetector` uses `ModifierTap` for modifier-only hotkeys:
  600 ms like macOS (a single modifier had 400), and a click now cancels the
  tap (the mouse hook calls `interruptHotkeyTaps`), so Shift+click to extend
  a selection no longer fires a Shift-tap hotkey. A bare modifier keeps its
  side on Windows (Left Shift), as before; macOS matches either side.
  e2e: the auto-correct toggle bound to a Right Ctrl tap — a tap turns it off
  and on, a tap with a click inside does nothing.
- 2: `Core/Boundary.swift` `evaluateBoundary`: edit lessons, the decision, the
  short-word chain and bridge, switch-only, the fix plan — the ~45 lines both
  apps had. The decision now sees verdicts as updated by this boundary's
  lessons (it read the stored ones; same result, since both apps wrote them
  first). 6 tests, incl. the bridge rule, which had none.
- 3: `Core/PressAgain.swift`: `Conversion`, the record, retarget-vs-undo and
  the epoch guard (`mark`/`record`/`forget`; `drop` for the macOS key that may
  be starting a correction). 4 tests.
- The intermittent "first scenario fails" on Windows: the first UI Automation
  call of a fresh process is slow, so the first word's password answer came
  after its boundary and the word was left (nothing is corrected while it is
  pending). The app now makes that call at startup. Two consecutive VM runs
  green since (15+3 plain, 17+3 spell).
- macOS pauses around synthetic input are named (`landPause`,
  `autoLandPause`, `pollInterval`, `keyGap`) instead of repeated literals.
- Checked: `swift test` 151, macOS run-tests 39, Windows e2e plain and spell
  twice. Not run: macOS e2e after these changes.

## After v1.3.16 — tests split by layer; keystroke gate and hotkey taps in Core

- Test layers written down in ARCHITECTURE: unit (Core, corner cases), e2e
  (what a user can do, against the unmodified app; the one seam is Windows'
  injected-key marker), manual (release builds, installer, Sparkle update,
  UWP exclusion). Fault injection into the app for e2e was proposed and
  dropped: the watchdog is a unit-tested rule instead.
- `Core/KeyGate.swift`: the gate around a correction (hold, backspace un-types,
  replay one at a time with the clock restarting per key, release when stuck)
  with 6 tests. The platforms differed: Windows released held keys plus the
  current one in order and dropped the stuck fix; macOS just stopped holding,
  so new keys went out before the held ones (letters out of order). Both now
  release in order; macOS cannot cancel a fix already on its worker queue.
  Windows' backspace during a fix with nothing held is held too, and replayed
  as a key.
- `Core/HotkeyTaps.swift`: `TapSequence` (multi-press hotkeys; Windows' double
  tap now counts like macOS' N taps) and `ModifierTap` (modifier-only taps:
  exact chord, no key/click/extra modifier, released in time), 8 tests; macOS
  uses both, Windows uses `TapSequence`. Windows' own modifier-tap detection
  (`HotkeyDetector`) is unchanged: 400 ms for a single modifier vs 600 ms,
  exact side only, and a click does not cancel it — left for a separate
  change, it has no e2e coverage.
- `build.yml` dispatched (run 39648892347): macOS build + tests + package,
  Windows x64 and arm64 builds and installers — all green, so the pinned choco
  versions and the installer's new [Tasks]/[Registry]/[InstallDelete] compile.
  Sparkle is embedded only on tags, so its hash check ran only locally.
- Checked: `swift test` 141, macOS run-tests 39, macOS e2e 11/11, Windows e2e
  15/15 and spell 17/17 in the VM.

## After v1.3.16 — e2e workflow for GitHub-hosted runners

- `.github/workflows/e2e.yml`: manual, non-blocking, `contents: read`. Both
  jobs first print what the machine allows, so a failure tells the runner
  from the app.
- macOS: the image pre-grants Accessibility and PostEvent to bash and the
  runner agent (actions/runner-images `configure-tccdb-macos.sh`), so the
  harness can likely post events; the app itself gets a TCC row written with
  its own designated requirement — whether that takes depends on SIP being
  off during the job, which no doc states. Layouts are enabled through TIS
  (`enable-layouts.swift`), not `defaults`, so no re-login is needed.
- Windows: no official word on an interactive desktop; WinAppDriver ships in
  the image, which suggests one. `e2e-win.ps1` starts programs through
  interactive scheduled tasks (built for SSH into the VM); whether that works
  in the runner's session is part of what the first run shows. Spell mode is
  left out (no ru/uk dictionaries on the image).
- Pushed by the user's request and run (runs 39629346137, 39629695175,
  39630166651). What the runners turned out to be:
  - macOS 15 arm64 VM, user `runner`, **SIP disabled**, so a TCC row written
    in the job takes: the dev app got Accessibility and macOS e2e passed
    11/11 (US + Russian picked; the image already had US enabled).
  - Windows Server x64, `runneradmin` in an **active console session 2**,
    high integrity, interactive; `schtasks /it` works there unchanged.
    Windows e2e passed 15/15 — the first x64 run of the port at all.
- First-run fixes: an ad-hoc signature prints its requirement as
  `# designated => cdhash …` (the `sed` expected no `#`); `query session`
  exits 1 even when it prints, and GitHub's pwsh wrapper exits with the last
  native code; `e2e.sh`'s restore trap returned 1 when no reLayout had been
  running (`[ -n "" ] && open` under `set -e`), failing a green run.
- Run 39630166651: both jobs green.

## After v1.3.16 — macOS replays held keys in the layout the fix switched to

- Owner typed `rkjl` + space and, while the fix ran, `j,`: the result was
  `клод j,новлен`. macOS held the keys as the text they typed in ABC and replayed
  that text after the fix had switched to Ukrainian. Keys typed during a fix are
  typed blind in the layout the fix just called wrong, so they now replay
  transliterated into the new one (`об`), as Windows already did by replaying
  key codes in the active layout.

## After v1.3.16 — Windows spell check never ran while typing; e2e with it on

- `scripts/e2e-win.ps1 -Spell` runs the whole suite with the spell-check option
  on, plus two scenarios only the dictionary decides (a doubled letter and
  swapped letters in a wrong-layout word: "ghbddtn", "gbhdtn" -> "привет").
- They failed: the trigrams converted as typed ("приввет", "пирвет") and no
  repair came. A probe showed the factory and all three checkers created fine
  on the hook thread, but every `Check`/`Suggest` returned 0x8001010D,
  RPC_E_CANTCALLOUT_ININPUTSYNCCALL: the checker is an out-of-process COM
  server, and an outgoing COM call from inside a low-level hook callback (an
  input-synchronous call) is refused. That was true before the hook moved to
  its own thread too — the option never acted while typing on Windows; only
  the warm-up, outside a callback, ever succeeded (the "2-7 ms" measurement in
  WinAuto was presumably taken there).
- Fix: `relayout_spell.cpp` runs every call on a COM worker thread of its own
  (MTA) that owns all spell objects; callers hand a request over (inputs
  copied, refcounted, so a caller that stops waiting leaves nothing dangling)
  and wait 40 ms for a check or suggestions (then "unknown"), 5 s to open a
  dictionary. One request at a time: while the worker is busy, a call returns
  "unknown" at once. The hook thread makes no COM call at all now.
- Runs (each after a fresh VM build): spell mode 3/3 (17 scenarios); plain
  mode 2/3. The failed plain run stalled the UI thread ~2.5 s right after
  start: the first word went uncorrected (password answer pending — fail
  closed, by design) and the Enter fix had erased the word but not retyped it
  when the harness stopped waiting. Not reproduced since; cause not found.

## After v1.3.16 — audit 17/20 and the small items: shared Core rules, stragglers

- 17: `Core/Learned.swift` holds what both apps did twice — the auto decision
  chain (`autoDecision`: trigram, then spell check and typo repair, with an
  optional suggestion budget; Windows passes one, macOS none) and the
  learned-verdict rules (`LearnedWords`: count misses and promote after
  `autoLearnRepeats`, undo, promote/demote, forget, clean). The platforms only
  store the lists (UserDefaults, registry) and show them. Windows counted a
  miss once per occurrence in the text, macOS once per word; it is once per
  word now. A count reaching the limit with no output word no longer
  promotes an empty conversion.
- 20: macOS `stopAutoMonitor` zeroed `autoPending` mid-correction, so
  `finishCorrection` took it to -1 and the keystroke gate stopped engaging;
  `unlearn` ran on the worker and raced the main thread's UserDefaults
  writes; trigram files with `nan` are rejected value by value (a `nan`
  floor rejects the model); the script-language list is built once.
- Words over 64 letters were trimmed to their last 64, so a fix erased and
  retyped only the tail; such a run is now dropped whole until whitespace.
- macOS `typeUnicode` caps an event at 20 UTF-16 units (a long indent ran in
  one event; the per-event limit is not documented, 20 is the known one).
- Windows: "Exclude current app" and the exclusion check named every UWP app
  `applicationframehost.exe`; `appWindow` finds the child window of the app's
  own process. The Exceptions and Learned windows used Settings' font, which
  Settings frees on every rebuild; they use a per-dpi font kept for the
  process's life. Overlapping update checks shared one result slot (a manual
  check could report a failure); each answer now travels with its request
  via `postToUI`. The fix watchdog dropped held keys: it now re-sends them
  (and the key that tripped it) and drops the stuck fix so it cannot run late.
  The double-tap window is 500 ms, as on macOS (was 350).
- Doc comments that sat above the wrong declarations (Engine, Auto) moved.
- Left: the Windows UI-helper duplication across Settings/Exceptions/Learned
  (a refactor of three windows nobody can check visually here).
- Checked: `swift test` 127, macOS run-tests 39, Windows build + e2e 15/15 in
  the VM, macOS e2e 11/11 (after the screen was unlocked). Its new held-key
  scenario first failed on the test itself: it reused a word fixed one
  scenario earlier, and a click plus retyping that word reads as reverting
  the fix (learning by revert, by design), so the word was kept. It uses its
  own word now. Not run: the spell option on Windows, a UWP app exclusion,
  the watchdog path.

## After v1.3.16 — audit 18/19: mixed words on punctuation keys, dead code

- A mixed word whose Latin half was typed on punctuation keys ("[jh" is
  "хор" before the switch, "ошо" after) was rejected by both the hotkey
  (`fixMixedWord`) and auto mode (`mixed` required pure letters).
  `isMixedWordMaterial` accepts keys that type a letter on an enabled
  Cyrillic layout; `convertScriptRuns` lets such a key join a run it touches,
  so a comma after the Cyrillic half stays a comma.
- `planRetype` fixed a mixed word only when the selection was exactly that
  word: a double-click that also took the trailing space ("ghjшто ") went to
  whole-text conversion ("ghjinj "). It now looks at the one word and retypes
  the surrounding whitespace as it was.
- Deleted `caretWord` (no caller since the hotkey converts only a selection)
  and its tests, and the engine tests duplicated in `macos/tests.swift`
  (`Tests/ReLayoutCoreTests` has each); macOS run-tests keeps its own 39.
- macOS e2e gains the held-key replay scenario; not run yet — the Mac's
  screen was locked (the harness aborted on focus, as designed).

## After v1.3.16 — Windows hooks on their own thread

- The keyboard and mouse hooks ran on the UI thread, so any slow UI work (a
  UIA read, typing a fix, the clipboard) delayed keys, and UIA calls sat in
  the hook itself (the password check per word, the Enter snapshot) — past
  LowLevelHooksTimeout Windows silently drops the hook. They now run on a
  dedicated thread that owns all hotkey/auto-correct state and the spell
  checker; the UI thread reaches it through `onHook` (synchronous), the hook
  thread hands work back through `postToUI`. The hook thread never waits for
  the UI thread.
- UIA left the hook: the password check is asked on the UI thread at each
  word start (`passwordPending` blocks corrections until the answer; a stale
  "yes" from another field does not drop keys meanwhile — the first e2e run
  lost the "g" of "ghbdtn" that way); Return is held back when a follow-up
  is likely, the UI thread reads the field, re-sends Return, then fixes.
- Held-key replay keeps the gate shut until the queue is empty (new keys
  queue behind it), stops when another fix is queued (also after the
  watchdog), and re-checks the field for a password first; after a replayed
  Tab the field counts as unknown (no corrections) until a typed word asks.
- `conversionEpoch` guards the undo record like macOS's `undoEpoch`: a click
  during a retype is no longer overwritten by the retype's record.
- Re-sent keys take Shift as it was when typed, whatever is held now.
- Cross-thread closures go through an in-process `CallQueue`; the window
  message carries no pointer (an automated security review flagged the first
  version, which passed an object pointer in `lParam` that any process could
  forge). The hook thread is woken through a message-only window (a COM wait
  drops thread messages) and runs one queued item per wake.
- A second security-review pass: an in-flight password answer asked for one
  field could clear the block for the next; answers now count only for the
  latest question (`passwordAsk`), a stale one asks again, and keys held over
  a fix that ended on Tab leave the field unknown instead of trusting a read
  taken before focus settled.
- Settings' hotkey capture results are dropped if the capture was cancelled
  before they reached the UI thread.
- Startup: tray first (the hook thread posts to it), then the hook thread.
- e2e: a password-field scenario (two words, the second after the answer);
  the runner waits for the app's process — the "first scenario fails now and
  then" flake was the harness typing before the app had started. 15/15 twice.
- An Opus review of the diff found two must-fix defects (an escaping-closure
  trap in `onHook`; replayed words never corrected because the password
  answer could not come back mid-replay) and four should-fix ones; all fixed.
- Not verified: hook removal under a really hung app (no such app in the VM),
  the spell-check option on the new thread (off in e2e).

## After v1.3.16 — Windows batch: foreign keys, held-key replay, installer autostart

- Keys reLayout sends now carry `ownInputMarker` in `dwExtraInfo`. Any other
  injected key-down (a remapper, an on-screen keyboard, a password manager's
  autotype) resets the run and ends the undo window: before, it was skipped,
  so the run no longer matched the screen and a fix erased the wrong text.
- Held keys (typed while a fix runs) were captured as text in the old layout
  but fed to the run in the new one at replay, so the screen said "rfr" and
  the run "как". Held keys now keep scan code and Shift; at replay one string
  is worked out in the layout the fix left and both fed and typed.
- Installer: the Startup shortcut (invisible to the app's "Launch at login"
  switch, so unchecking it did nothing) is gone, also on upgrade
  (`[InstallDelete]`); a default-on task writes the same Run value the app
  manages.
- e2e: +2 scenarios (an unmarked key mid-word leaves the word alone; keys
  typed during a fix land in the new layout), 14/14. The second also passes
  when no key happens to be held, so it guards the fix only partly.
- Not exercised: the installer itself (no Inno Setup in the VM).

## After v1.3.16 — Sparkle 2.6.4 -> 2.10.0

- 2.6.4 was simply the version pinned when Sparkle was added (`cb61f8f`).
  2.10.0 hash = the release asset's GitHub digest (the user had it too).
- Release notes 2.7-2.10: appcast changes are additive; no change to EdDSA or
  `SUPublicEDKey`; framework minimum macOS 12.0 (app is 13.0); main-thread
  use enforced since 2.8 (the app creates and calls the updater on main);
  several security fixes (2.7.2, 2.9.2, 2.9.5, 2.9.6).
- Checked locally: a WITH_SPARKLE build signs and passes `codesign --verify
  --deep --strict`; 2.10's `generate_appcast` with a throwaway key signs the
  item, `appcast-informational.py` still patches it, and 2.6.4's `sign_update
  --verify` accepts the signature — so installed 2.6.4 clients can verify it.
  It now also emits `<sparkle:hardwareRequirements>arm64` (the CI build is
  arm64-only); 2.6.4 clients ignore it, as before.
- 2.9+ reads `.md` release notes; the `/markdown` render step still works and
  was left alone.
- `resign-appcast.yml` fetched Sparkle with `curl | tar` and ran `sign_update`
  with the private key; it now uses the same pinned version and hash, read
  from `scripts/sparkle.env` (sparse checkout) like `build.sh` — one place.
- Not verified: a real update from an installed 1.3.x to a 2.10.0 build.

## After v1.3.16 — audit security batch: Sparkle pin, update key, uninstall, CI token

- `build.sh`: the Sparkle tarball is cached as a file and checked against a
  pinned SHA-256 on every build, then extracted fresh — before, `curl | tar`
  ran unchecked and the extracted cache was trusted, then signed with
  Developer ID. Hash taken from the official 2.6.4 release asset (GitHub
  gives no digest for it); its framework binary matches the copy the local
  cache already held.
- `build.sh` fails on a feed with no EdDSA key (the updater would reject
  every update and users would stay on that version), a non-https feed, or
  a release with Sparkle and no feed (was a warning).
- Inno Setup: uninstall deletes `HKCU\Software\reLayout` (learned lists hold
  words the user typed) and the `reLayout` Run value.
- CI: checkouts no longer persist the write token in `.git/config` (no step
  relied on it: releases use `gh` with GH_TOKEN, gh-pages a token URL, the
  tap an SSH key); choco installs pinned (innosetup 6.7.1, 7zip 26.4.0).
- Not exercised: a real tagged release, the installer's uninstall, a CI run.

## After v1.3.16 — Windows end-to-end harness; Ctrl+Alt+R kept the typed word

- `scripts/e2e-win.ps1` + `scripts/e2e/win-harness.swift`: the macOS
  scenarios on Windows, plus the three-layout press-again cycle with ru + uk
  installed ("ghbdsn": привіт on uk -> привыт on ru -> ghbdsn on en); 12/12.
  Keys go in with SendInput scan codes marked in `dwExtraInfo`; only DEBUG
  builds' hook accepts the marker. Interception (driver-level keys, no
  injected flag) was the first choice and was dropped: x86/x64 drivers only,
  and the VM is Windows 11 on ARM64.
- Found by it: with nothing selected, the default hotkey Ctrl+Alt+R never
  converted the typed word. Alt's keydown arrives with Ctrl already down,
  reads as a shortcut, and `autoFeed` reset the run before R fired the
  hotkey. A modifier alone now returns early: it types nothing.
- A plain EDIT has no UI Automation text, so the selection read fell back to
  Ctrl+C and the Enter follow-up (UIA snapshot) never ran. The harness uses
  RichEdit, as Notepad does.
- The VM build script fetched the bundle into `audit-fixes` while that branch
  was checked out in its worktree; git refused and the build ran the old
  commit — so the earlier "builds in the VM" for audit batch 1 checked stale
  code. The script now removes the worktree first and checks HEAD.
- First run: scenario 1 failed once and passed on every rerun (warm-up).
- PowerShell variable names ignore case: `$trace` overwrote the `-Trace` switch.

## After v1.3.16 — audit batch 1: AX timeout, Tab, CRLF, clipboard, Dvorak

- macOS: a global AX messaging timeout (0.1 s, set on the system-wide element)
  so the key taps' inline AX calls cannot stall all input on a hung app.
- Engine: a Tab breaks the short-word chain. "d", Tab to the next field,
  "ljhjut " erased 8 characters there (2 never typed) and typed "в дорогу".
  The word before the Tab is still judged at it; only the chain past it ends.
- Engine: `enterOutcome` accepts "\r\n" (one Character, two UTF-16 units),
  so the Enter follow-up works in Windows CRLF controls.
- macOS Cmd+C fallback: waits up to 400 ms for the pasteboard to change
  instead of a fixed 120 ms (a late copy otherwise stayed on the clipboard
  after the restore), and posts the key that types "c" in the current layout
  (Dvorak sent Cmd+J). An empty probe now costs up to 400 ms.
- Windows Settings: `where colors.dark` covered only WM_CTLCOLOREDIT, so the
  language list was themed dark-path in light mode too.
- e2e gains a Tab scenario. Its first run failed on the word itself: the
  earlier undo scenario had learned it as kept, so it uses its own word.

## After v1.3.16 — macOS end-to-end harness

- `scripts/e2e.sh` + `scripts/e2e/harness.swift`: drives the real dev build
  with synthetic physical keys into a test window and checks the text and
  the layout. Nine scenarios: auto-fix, right word kept, hotkey on a
  selection, press-again undo, undo of an auto-fix, hotkey after typing on
  converts the new word (the stale-undo bug from the audit), Enter follow-up.
- Words depend on the Cyrillic layout found (ru "ghbdtn", uk "ghbdsn"); the
  first run assumed Russian and skipped on an ABC + Ukrainian-PC machine.
- The first real run lost its first two scenarios: the window was not yet
  key, so the keys went to whichever app had focus. The harness now waits
  for focus before each scenario and aborts instead of typing elsewhere.
- Prefs isolation: the dev domain is exported, the app's keys reset, and the
  export re-imported on exit; whichever reLayout was running is relaunched.
- Not covered: a click during a running retype (timing-dependent), Windows
  (its hook drops all injected keys, so SendInput cannot drive it).

## After v1.3.16 — audit fixes: parser crash, stale undo, cut selection, hook timeouts

- A repo audit (Core, macOS, Windows+CI) found four must-fix defects.
- `parseStrings` trapped on a key with no closing quote at end of file
  (`removeFirst` on an empty slice); the Windows app reads `lang/*.strings`
  at launch, so one truncated translation crashed it.
- macOS: `lastConversion` was cleared by the taps on main and written by the
  worker with no ordering. A click during a retype was overwritten by the
  worker's record, so the next hotkey "undid" at the new caret and erased
  text that was never converted; keys replayed after a correction skipped
  `autoFeed` when auto mode was off and never ended the window. Now main-only:
  user input bumps `undoEpoch`, the worker records only if the epoch is the
  one its correction began with. A key in the undo watch does not bump (it
  may be the boundary that began the correction; replay ends the window).
- Windows: a selection longer than 4095 UTF-16 units was cut to its tail and
  the retype overwrote the whole selection with the tail's conversion. The
  native read now returns the needed length and Swift retries.
- Windows: UI Automation calls inside the low-level hook had no timeout, so a
  hung app could hold the hook past LowLevelHooksTimeout and Windows silently
  removed it. UIA connection/transaction timeouts are 100 ms; trigram models
  load in `reloadAutoMode` instead of on the first word inside the hook.
  Open: the Enter snapshot still makes ~10 UIA calls in the hook.

## After v1.3.16 — press-again: erase instead of reselect, multi-tap hotkeys

- Trace from Terminal: the hotkey converted two letters, the second press
  (undo) left them and appended `;2D;2D` plus the original. Undo and the
  layout cycle selected the typed text with Shift+Left and typed over it; a
  terminal has no selection, so zsh got each arrow's `ESC[1;2D` and inserted
  its tail. Both now erase with Backspace (the caret is right after the typed
  text, as the undo window already guarantees), like the conversion itself —
  macOS `eraseBack`, Windows `sendBackspaces`; Windows `selectLeft` is gone.
- Press-again now works with multi-tap hotkeys too (owner: double Shift on
  Windows converted once and never undid). It was off there for fear of
  ambiguity with the trigger, but each completed sequence is one press, and
  the taps of a sequence never end the undo window.

## After v1.3.16 — Windows exceptions: check boxes centred

- Owner, comparing with macOS: the check images sat at the left of wide
  columns. A list view draws a sub-item image at the cell's left edge, so the
  check columns are now just the box wide, with pad columns around them, and
  the titles above are centred (SS_CENTER) over the same span.
- Exception rules moved into engine `AppExceptions` (rows = auto then
  hotkey-only, keys off = both, add turns auto-correct off, remove drops both),
  tested once; both platforms only store the two lists and draw the window.
- v1.3.16 re-released from this state (the first upload had 0 downloads).

---

## After v1.3.15 — exceptions follow Spotlight (macOS)

- Issue #2 (per-app layout, lsl87Serhii) noted that Spotlight takes focus
  without becoming the frontmost app. Measured: with Finder in front, opening
  Spotlight left `NSWorkspace.frontmostApplication` at Finder, while
  `kAXFocusedApplicationAttribute` on the system-wide element flipped to
  `com.apple.Spotlight` exactly with each open/close; the on-screen window list
  showed the panel ~2-5 s longer (fade). Over an Electron app (Claude, Figma)
  the attribute fails fast (-25204, 0-2 ms).
- So the exceptions used the app UNDER Spotlight: over a terminal (auto
  excluded) Spotlight had no auto-correct, over Figma no hotkey. Now
  `refreshKeyApp` picks the app with keyboard focus (AX, else Spotlight's window,
  else frontmost), refreshed on clicks, Cmd/Ctrl keys, Return/Esc/Tab (and 0.2 s
  later), word boundaries and the hotkey.
- The per-app layout itself is not taken: a forced layout fits Figma or a
  terminal, not Spotlight, where the owner searches in Russian too.

---

## After v1.3.15 — per-app exceptions for auto-correct and the hotkey (macOS)

- First outside contribution: PR #3 by lsl87Serhii (`d13a6db`, issue #1). In
  Figma a released Option fired the retype hotkey; the exceptions applied to
  auto-correct only, and our Unicode events carry key code 0 ("A", the Frame
  tool) while the erase backspaces delete layers. The PR added a "Fully off"
  checkbox per exception and Figma as a default. Merged as is, authorship kept.
- Fixed on top (`be3c552`): the PR's early return in the key tap also passed the
  tap-disabled notices through, so a tap disabled while such an app was
  frontmost would never be re-enabled.
- Owner's extension: two flags instead of "Fully off" — auto-correct and hotkey
  (`autoExcludedApps`, new `hotkeyExcludedApps`; both = no key read at all);
  table rows are the union, checkbox columns with header tooltips; a new app
  gets auto-correct off only. The Exceptions… button moved from the
  auto-correct row into its own Settings section, enabled regardless of
  auto-correct availability (it covers the hotkey too).
---

## After v1.3.15 — per-app exceptions: auto-correct and hotkey (Windows)

- Issue #1 (Figma: the hotkey's backspaces and typed letters act as canvas
  tool commands) on Windows, with the macOS semantics: two flags per program
  instead of the earlier "Fully off". `AutoCorrectExcluded` keeps its meaning
  (auto-correct off); new `HotkeyExcludedApps` turns the retype hotkey off.
  Both off → the hook feeds no key to auto mode (never while a fix is in
  flight); the auto-correct on/off hotkey still works everywhere.
- `figma.exe` joins both default lists, merged once into saved lists like
  earlier defaults.
- Exceptions window: two check columns titled like Learned words (labels
  over a header-less list). Sub-item check images are copied from a hidden
  list view with `LVS_EX_CHECKBOXES`, so they follow the dark theme.
  Settings: Exceptions… moves to its own section, always enabled.
- The foreground exe name is cached per foreground HWND: the "both off" check
  runs on every key inside the hook.

---

## After v1.3.14 — Windows spell-check timing, suggestion budget

- Measured in the VM (clang++ bench over the same COM API, ~2000 words per
  language, half misspelled): Check p50 0.07-0.09 ms, p99 0.2-0.5 ms, max
  24 ms (5-7x faster than macOS); Suggest p50 1.9-6.9 ms, p99 13-39 ms, max
  101-127 ms; first dictionary load 9-51 ms (already warmed up off the hook).
- Suggestions run inside the low-level keyboard hook (Windows skips and may
  drop a slow hook), and a Cyrillic target asks ru and uk: worst case ~250 ms.
  Budget: 50 ms from the first suggestion call; later languages are skipped,
  and a repair decided past it falls back to the plain decision.

---

## After v1.3.14 — Windows: modifier chords as a hotkey

- Owner: Ctrl+Shift could not be recorded on Windows (macOS has chord taps
  since the start). A hotkey there was a lone modifier tap or a combo with a
  real key; the recorder fired on the first modifier released. Now `vk`
  `chordVK` (0xFF, a reserved VK) with `mods` = the chord: the recorder waits
  until every modifier is up and reports the peak set; the detector tracks
  held/peak per press and fires when the last one is released (no other key,
  < 600 ms); Alt/Win in the chord get the masked release. Double tap works
  the same way.

---

## After v1.3.14 — no time windows for undo and learning

- Owner: the 1.5 s press-again undo and the 15 s revert window were limits a
  user cannot see. Now signals end them instead:
  - press-again undo lasts until any other key or click of the user's
    (macOS `startUndoWatch`, a listen-only tap running with auto-correct off
    too — the auto tap alone only covered auto mode; Windows already forgot
    on any key in its hotkey hook and on clicks in the always-on mouse hook);
  - a `RevertWatch` watches only the next word: retyped after an edit, it is a
    revert/unkeep/manual fix; typed with no edit, the user moved on.
- The three watches, their arming and the lessons moved from both platforms
  into engine `EditLearning` (+ `EditLesson`, tested once). The spell chain
  (`decideAutoTarget` -> `spellCheckedTarget` -> `spellRepairedTarget`) stays
  per platform: ~8 lines each, interleaved with platform trace lines.

---

## After v1.3.14 — a keep is dropped the same way it was learned

- Owner: a keep learned by revert could only be removed in the Learned words
  table (the hotkey does not clear it: `hotkeyMisses` counts only words auto
  mode would leave anyway, and a reverted word is one it converts). Caramba
  removes an exception by erasing and retyping the word, so: a second
  `RevertWatch` arms when a `keep` word is left alone; an edit plus the same
  word again within 15 s drops the keep and the word is judged afresh
  (converted). Both platforms.
- Teaching a conversion without the hotkey (owner: "учше" -> "exit"): a
  word left alone, erased and typed in its other-layout reading within 15 s
  is learned `convert` at once (owner chose once, not the hotkey's three).
  Third `RevertWatch` (`manualWatch`); retyping the same word is no signal.

---

## After v1.3.14 — abbreviations left alone (both platforms)

- From Caramba Switcher: a word typed in capitals (2+ letters, all upper:
  IBM, МФЦ, КПСС) is never auto-corrected; a learned `convert` still wins,
  the hotkey still converts. Cost, accepted: a word typed with Caps Lock in
  the wrong layout ("GHBDTN") is left too. Not measured — the frequency lists
  carry no case.
- Dot rule, owner's version: a trailing "."/"," is a letter only if it is
  one in the other layout; then both readings are scored — "ghbdtn." ->
  "привет." (dot kept) beats "приветю"; "стр." on the Russian layout reads
  "cnh/" the other way, junk, left. A learned convert with junk both ways
  now gives "привет," (was "приветб").
  First version wanted the rest of the word to be plain letters, so "re,f,"
  ("куба,": a "," inside is "б") got nothing; now the converted rest must
  be letters.
- Reverted (owner): read keys literally. The Russian comma/period are other
  keys (Shift+/ and /), so "re,f," is "кубаб" and "[kr," is "хлкб" ("хлеб"
  with a typo); the dual reading also let a fragment beat the real word
  ("хле" -3.1 vs "хлеб" -4.1). Back to mapped punctuation = letter.
  Typo repair now also takes words with letters on punctuation keys ("[kr,"
  = "хлкб"); here it still stays: ru guesses "хлеб", uk "хліб" — two
  candidates, no repair.

---

## After v1.3.14 — learning by revert (both platforms)

- Idea from Caramba Switcher ("erase a wrong switch with Backspace and retype
  it — remembered"), widened on the owner's question: erasing may be letter by
  letter, a selection deleted at once, or typing over a selection. reLayout
  sees keys and clicks, not what is selected, so the signal is "an edit that
  may delete text, then the same word typed again": engine `RevertWatch`
  (15 s window; edits = Backspace, Delete, arrows/navigation, a click, a
  Cmd/Ctrl shortcut; synthetic keys ignored). The retyped word is left and
  stored as `keep`. Typing the same word twice with no edit between is not a
  revert. Typo repairs never arm it (they are never learned).
- First live test failed twice: the owner's word was a typo repair (never
  armed, by rule — owner confirmed: never learned), and the retype began in
  the layout the fix had switched to ("я"+"aaa"). The retype is now mapped
  back through the fix's layouts (`typedBack`, `convertScriptRuns`) before
  comparing; typing the correction itself again is no revert.
- Then "kpss" (an abbreviation): converted with a typo repair every time and
  never learnable. Owner's split: the repair is never learned as a
  conversion, but undoing/reverting it stores the TYPED word as `keep`. The
  `learn:` flag is gone on both platforms; every auto-correction arms the
  revert watch.
- macOS: a keep learned by revert did not show in an open Learned words
  list until reopened (`64e0000`); Windows already refreshed on save.

---

## After v1.3.14 — spell-check option on Windows (`autoSpell`, Windows)

- The macOS `autoSpell` option ported: Windows Spell Checking API in a new C++
  shim (`windows/native/relayout_spell.cpp`), `WinSpell.swift` wraps it as the
  engine's `SpellCheck` / `SpellGuesses`; `WinAuto.autoDecide` runs the same
  chain as macOS for the boundary fix and the Enter follow-up; a repaired typo is
  never learned. Settings row + ⓘ under "Between similar layouts", registry
  `AutoCorrectSpell`, default off.
- Language mapping: the 2-letter layout code if the API supports it, else the
  first supported `<code>-…` tag. One checker cached per code.
- COM on the UI thread (STA), as the UIA reader. Dictionaries are opened when
  preferences load, not on the first word: a slow first load inside the
  low-level keyboard hook would hit its timeout.
- Debug trace logs only the outcome ("spell: left/converted",
  "typo: repaired len=N"), no words — the Windows log records no typed text.
- Not verified on Windows at commit time (no Windows build on the macOS host).

## After v1.3.14 — typo repair inside wrong-layout words (`autoSpell`, `98c2b56`)

- Owner's goal: "ghbddtn" / "gbhdtn" / "ghjdtn" -> "привет" in auto mode; a typo
  in a right-layout word is the app's business, the hotkey never repairs.
  Measured offline (FrequencyWords 20k, 1,000 typo'd words per class per
  direction, en<->ru/uk both ways, synthetic uniform typos; F = fixed / W =
  wrong word; FP = layout switch on correct words N0 / typo'd right-layout
  words N1):
  - A2g alone: F 0 everywhere (51-79% converted with the typo);
    FP 0.015% / 0.776%.
  - doubled + swap only: F 87% / 87% on those classes, W <= 0.3%;
    FP 0.075% / 1.11%.
  - + adjacent-key substitution: subK F 69%; FP 0.22% / 1.8%; ~45 checks/word.
  - + system guesses one edit away (shipped, owner's pick): F dbl 87%, swp 87%,
    random letter 47%, adjacent key 47%, insertion 68%, deletion 26%;
    W 1-7%; FP 0.52% / 4.2%; guesses() 6.8 ms mean, p99 21 ms, called for
    ~75% of eligible (junk, misspelled) words, up to 2 languages.
  - first guess regardless of ambiguity: more F but W up to 33%, FP 0.75% /
    5.2% — rejected. Every-letter substitution: ~200 checks/word — rejected.
  - Several candidates -> no repair, the trigram/spell decision stands.
- The similar-layouts ⓘ got the same treatment: non-Cyrillic UIs explain it
  with en <-> de (“yeit” -> “zeit”; de UI: „zes“ -> „yes“), ru/uk/be keep
  «ъжа» -> «їжа».
- Repairs never enter the learned words. Hint examples per UI language:
  “рудддщ” -> “hello” (Latin UIs), «ghbddtn» -> «привет» (ru, be),
  «ghbdssn» -> «привіт» (uk).

---

## After v1.3.14 — auto-correct on/off hotkey + menu-bar dot (macOS)

- A second recordable hotkey toggles `autoMode` (Settings row "Auto-correct
  on/off:", restore button clears it; unset by default, nothing registered).
  Same kinds as the main hotkey: Carbon combo, modifier tap, tap sequence.
  The scattered `hotKey*` properties became a `Hotkey` value and two
  `HotkeySlot`s; the main hotkey keeps its `hk*` keys, the toggle uses `autoHk*`.
- Recording one hotkey with the other's activation is refused and shown on the
  conflict line; same chord with a different tap count counts as the same
  (the single tap would fire on the double's first tap).
- While auto-correct is unavailable (one script) the toggle does nothing, as
  the disabled checkbox can't change the preference either.
- The auto tap now passes our combo hotkeys' keyDown untouched (no run reset,
  no feed), which settles the open question from "After v1.3.2 — hotkey
  converts the word being typed": a combo retype hotkey no longer risks
  emptying the typed-word target.
- Menu-bar icon: a dot in the top-right corner while auto-correct is on and
  available. The icon is a template (only alpha survives), so the owner's
  "green, light for monochrome" resolves to the light variant: the glyph's
  tone at 60 % alpha. Not checked visually yet.
- Recording no longer outlives a commit (`24b7eed`): the field used to stay
  in recording mode until focus left it, and recording pauses both hotkeys
  and auto-correct — owner saw both stop right after setting the toggle.

---

## After v1.3.14 — auto-correct on/off hotkey + tray dot (Windows)

- A second recordable hotkey toggles auto-correct, with the Settings
  checkbox's effect (prefs, `reloadAutoMode`, Settings synced). Default unset;
  same kinds as the convert hotkey (combo, modifier tap, double tap). Prefs:
  `AutoHotkeyMods` / `AutoHotkeyVK` / `AutoHotkeyDoubleTap`; the convert keys
  are unchanged. Hotkey state became `Hotkey` + `HotkeySlot` + one
  `HotkeyDetector` per slot in the hook.
- Recording refuses the other hotkey's keys even if only the double tap
  differs: a single tap would fire alongside the double one.
- Unavailable auto-correct (one script): the toggle does nothing, like the
  disabled checkbox; the debug log notes it.
- Tray: a green dot in the glyph's corner while auto-correct is on, drawn at
  runtime. Windows has no monochrome tray variant (the ICOs are pre-tinted
  per taskbar), so the dot is always green: deeper on light, lighter on dark.
- Built in the VM on first try (`4c9c998`). Owner's review (`5c6536a`): a
  text-less checkbox drew its focus cue as a dotted sliver beside the box —
  hidden (WM_UPDATEUISTATE UISF_HIDEFOCUS); the ⓘ glyphs sat 2 px low.
  Captions (Language, both hotkeys) left-aligned like macOS.
  ⓘ glyphs: nudging the top (y+2 low, y high, y+1 still high) never fit — the
  icon font's glyph sits high in its cell; now SS_CENTERIMAGE over the label's
  one-line rect (`053f6e7`); Learned words column titles moved
  over the row text — missed; then (`ed26dd8`) the list became three
  columns: the check box alone in column 0, Typed and Becomes as sub-items,
  titles at list border + the cells' 4 px text inset. Label editing of
  column 0 gave way to the edit-box-over-cell used for Becomes, for both.

---

## After v1.3.14 — same-language doubled-letter fix removed

- Owner: a typo in a word typed in the right layout is visible and the app's
  own spelling handles it; reLayout targets typos inside wrong-layout words
  ("ghbddtn", "gbhdtn", "ghjdtn" -> "привет"; measurement pending). `undoubled`,
  `AutoRun.respell`, their tests and the hint sentence are gone (`ef61880`,
  `3caac67` superseded). Rule kept from `8a82e73`: typo fixes never enter
  the learned words.
- Settings: a disabled sub-option (Enter, similar layouts, system dictionary)
  shows unchecked; the stored preference is kept.
  Refined by the owner: only a system reason (no such layouts, no dictionary)
  shows it off; disabled because auto-correct is off, it keeps its state.

---

## After v1.3.14 — system spelling dictionary as an option (`autoSpell`)

- Owner's call: the OS spell checker is allowed (no dictionary of our own).
  Measured offline on FrequencyWords 2018 50k (first 20k words of 3+ letters
  per language, row-aligned maps, real `decideAutoTarget`, NSSpellChecker
  ru/uk/en; uk list filtered by the same checker, so uk-active FP is optimistic):
  - Layout rule (A2g, shipped): recall / FP, baseline -> spell
    en<->ru ABC 98.88/0.150 -> 99.27/0.100; ru 98.14/0.139 -> 98.54/0.059;
    en<->uk ABC 99.17/0.195 -> 99.61/0.130; uk 98.04/0.099 -> 98.55/0.015.
    Fixed e.g. "учше" -> "exit", "herf" -> "рука"; broken: names/acronyms the
    en dictionary lacks (manolo, cath), "мммм".
  - Rejected variants: never convert a dictionary word (loses "иге" -> "but",
    ru words that are junk typing); override for 3-letter words (breaks tim,
    ceo, gen into "ешь", "сущ", "пут"); spell only in an "uncertain" score band
    (40-60% of words fall in it, worse on both axes).
  - Doubled letter (B3, shipped): synthetic doubles fixed ru 87.7%, uk 97.0%,
    en 80.2%, wrong fixes <= 0.013%; real words altered ru 0.010%, en 0.055%
    (British spellings: travelling). Without the capital skip and 4-letter
    floor it altered 0.36-0.44% (Scott -> scot, хмм -> хм). Skipping words
    the app's own autocorrect would fix kept only 2-3% recall: dropped.
- Spell-check latency: median 0.5 ms, 1 in 100 calls 50-100 ms; the call is
  synchronous (`shortcut:`), only for words the trigrams convert or score as junk.
- Default off, experimental; macOS only (Windows passes no checker).
- The ⓘ hint's doubled-letter example is in the UI language (`3caac67`): "helllo" -> "hello", „gehhen“ -> „gehen“ …, each checked to be misspelled with a single dictionary fix (pl „dziękkuję“ passed the pl checker as a word, so pl uses „dobrrze“).

---

## After v1.3.14 — a late switcher re-post drops the word

- Vivaldi, "anthropic " + Globe + a Cyrillic word came out "anthropicооум":
  TextInputSwitcher re-posted the key it held while its HUD was up 100 ms
  after the NEXT key, so the `lastFedKey` filter (re-post == last fed key)
  missed it. The buffer kept the first sighting (Latin) plus the re-post, one
  char more than the screen; the fix erased 4 and took the space.
- Any TextInputSwitcher-sourced key that is not that immediate double now
  resets the word buffer and goes through unfed: no fix for that word rather
  than a wrong-span erase. The trace logs which recent fed key it matched.

---

## After v1.3.14 — the dev trace holds no typed text

- The secure-input skip left terminal passwords (sudo, ssh) in
  `/tmp/relayout.log`. `dbgRedact` now masks every quoted string in a trace
  line: letters -> `a`/`я` (script stays visible), digits -> `0`, symbols ->
  `·`; spaces and escapes stay. The tap line names only non-text key codes
  and carries `same=` (key equals the previous one) for spotting doubles.
- Cost: the log no longer shows which word was typed — repro reports carry
  the word.

---

## Docs pass for the SignPath application (`1a4a20e`, `74b3984`)

- README rewritten (139 → ~85 lines): tagline shared with the SignPath form, Windows install next to macOS, auto-correct as a short list; its fine print and the `--enabled`/`--selftest` diagnostics live in ARCHITECTURE. GitHub topics added for discoverability.
- Docs audited against code: CLAUDE.md (Windows is released on tags, AX is read-only), RELEASING (CI signs with `SPARKLE_ED_PRIVATE_KEY_NEXT`; forks pair that secret with their public key; the tap step has no repo-slug fallback), ARCHITECTURE (`RELAYOUT_DEBUG`, missing Windows files), ADR and BACKLOG (stale line refs, module map).
- `docs/fork-parameterization-plan.md` removed: fully implemented — `RELAYOUT_*` identity vars, PlistBuddy-filled Info.plist, `RLRepoSlug`/`windows/Identity.swift`, parameterised cask, bot-authored appcast commits, RELEASING "Forking" section — and went further with neutral `com.example.relayout` fallbacks instead of upstream defaults.
- `74b3984`: README Build from source covers Windows with winget install commands for VS Build Tools + Swift; `build-windows.ps1` no longer needs git (About slug falls back to the committed `example/reLayout`). Secure Input moved from Limitations to Privacy; the Windows update check is named next to Sparkle.
- Paragraph hard wraps removed across README and `docs/*.md`.

---

## v1.3.13 / v1.3.14 — released; Windows build fixed

- v1.3.13 (`0f2fef4`): macOS shipped (DMG/zip, appcast item signed, notes in the release body and the Sparkle window). Both Windows jobs and `core` failed: `WinSettings.swift` called `hasSimilarLayouts` but does not import `ReLayoutCore`. Fixed in `5a16b20` (helper moved to `WinAuto.swift`), `core` green; v1.3.14 re-ships the same code with the Windows installer/exe, macOS notes say "no changes".

---

## After v1.3.12 — ambiguous 3-letter words wait for a neighbour

- "рук" typed on Ukrainian-PC kept becoming "her" ("сколько нам понадобится рук для этой работы?"): typed −2.64, converted −1.52 — the same keys spell two real words, no threshold separates them.
- `decideAutoTarget` now returns `ambiguous` for a pure 3-letter cross-script candidate whose both readings score ≥ `autoAmbiguous` (−3.0); `AutoRun.plan` gives it the short-word treatment (fixed only next to a same-script conversion), the Enter follow-up skips it, a lone hotkey fix of one counts as a miss (learned after 3), a learned `.convert` fixes it alone.
- Measured on Leipzig news 2024 (5k sentences each of ru, uk, en, de, pl; 6 pairs, re-implemented rule): leaks in correct text 0.56 -> 0.51 per 1000 words; whole wrong-layout sentences −0.04 points; a lone foreign 3-letter word inserted into a sentence 96.5% -> 92.3% fixed (lost: "but" as "иге", "aby", "der", "tym"). That insertion scenario is synthetic (random words by frequency) and likely overstates the cost: lone foreign words in real text are mostly longer terms. T = −3.5 and N = {3, 4} cost more (85.6%).

---

## After v1.3.12 — absolute plausibility gate for pure-letter words (−4.0)

- Junk converted into lesser junk ("всы" -> "dcs", "якщо" -> "zroj" before the ru+uk gate): pure-letter words had only the relative margin. New `autoPlausible` = −4.0 on the converted reading (`autoPunctPlausible` −3.6 stays for punctuated words); a learned `.convert` bypasses it.
- Sweep, 12 pairs (one Latin + one Cyrillic), same lists/tables as the gate work above. Frequency-weighted: recall −0.06 points at most, uk/ru leaks 0.54% -> 0.14%, English on de/fr/es/pl/pt 3.05% -> 0.13%; unweighted recall −0.3 (worst en-uk L>C 99.13 -> 98.07). −4.5 / −5.0 cut leaks less; −2.5 / −3.0 / −3.6 cost 1.5–37% recall (36–48% of real words score below −2.5: the garbage line is the median, not a word/junk border). Lost: rare words just under −4 (aye, zero, tokyo, oak, sofa) — left to the hotkey.
- Lowering the typed-side garbage line was measured and rejected: −3.0 costs 0.8 weighted points of L>C recall (the → еру, when → црут read −2.6…−3.8), −4.0 costs 5. Short ambiguous pairs (рук/her, цру/whe, yen/нут) cannot be separated by any threshold — same keystrokes, two real words.

---

## After v1.3.12 — Cyrillic gate over ru + uk; similar-layouts tests; label example

- Testing "between similar layouts" with the favoured layout absent: no same- script switch ever targets a missing layout (by construction), but a uk word on the ru layout with uk absent could leave for Latin ("лише" -> "kbit"). The typed-side gate now always adds ru and uk on a Cyrillic layout (en on a Latin one, as before). Measured, one Latin + ru: uk words on ru converted to Latin 1.12% -> 0.91% (en-ru; 0.60–1.15% -> 0.42–0.91% over the six), recall of Latin words on ru −0.1…−0.25 points, FP flat. Most of the remainder are uk words with і/ї/є typed as ы/ъ/э, which no model reads.
- Also measured and rejected: max over ALL models of a script on both sides (typed gate and target reading). Recall of Cyrillic typed on Latin −0.15…−0.6 points (fr-uk 99.02 -> 98.40), FP on Cyrillic words ~0.15% -> ~0.25%, and the leaks grew (uk on ru 1.12% -> 1.46%, ru on uk 0.14% -> 0.26%): the best of six Latin models reads most Latin junk.
- `testAutoDecideSameScriptNeverTargetsAMissingLayout`: favoured similar layout absent / present, same-language twin, missing model, kept word, checkbox.
- Option label shows a Latin pair too: "(uk ↔ ru, en ↔ de)" in all 12 lproj; later moved out of the label into the ⓘ hint, which also says when the checkbox is available (two layouts of one script, different languages).
- The row is one checkbox title, "Between similar layouts (experimental)", and the ⓘ after it (`4543a3c`): the whole title grays out when the option is unavailable, the ⓘ stays live to say why. The "—"-split tag is gone.

---

## After v1.3.12 — "Between similar layouts" back, offered only when it can fire

- Revert of `b797c71`: the opt-in `autoSameScript` (`decideAutoTarget(sameScript:)`, margins `autoSameScriptMargins`, the switch-only path for `out == w`, Settings checkbox + ⓘ on macOS and Windows, strings in every lproj) is back unchanged.
- New: the checkbox is enabled only when `hasSimilarLayouts` (Core) finds two enabled layouts of one script and different languages, both with a model (uk + ru; also e.g. en + de, which the engine always allowed under the same option). The stored preference is kept while the checkbox is disabled; the engine needs no extra gate, a same-script target exists only in that setup.
- Same-script decisions still gate on the current layout's own model; the always-ru / always-en cross-script gate does not apply to them.

---

## After v1.3.12 — punctuated word read in the script's common language (`aeec8da`)

- "c,jhrf" (Russian "сборка", ABC + Ukrainian-PC) was not fixed: a word with mapped punctuation needs its conversion above `autoPunctPlausible` (-3.6), and it was scored by the target layout's language only (uk -3.91; ru -3.14).
- The target reading now takes the better of the target language and the script's common one (ru for Cyrillic, en for Latin) — the same rule the cross-script gate already uses for the typed word. Only words with б/ю/ж/э/х/ъ on punctuation keys are affected; pure-letter words skip the gate.
- Found with the dev trace (`RELAYOUT_DEBUG`, now default in `run.sh`). Not re-measured on the FrequencyWords sweep.

---

## After v1.3.12 — en always gates the Latin side too (`bead4d4`)

- Follow-up to the uk/ru gate: the same rule on the Latin side, en always consulted on a de/fr/es/pl/pt layout (`langs.append(cur.isCyrillic ? "ru" : "en")`). Measured on the shipped models, FrequencyWords 50k (first 20k words of 3+ letters), one Latin layout + ru or uk, pure-letter rule, row-aligned layout maps (pl = US, accented/AltGr letters skipped):
  - English words typed on L converted to Cyrillic: es/pl/pt 0.45–0.79% ->
    0.11–0.15% ("but" -> "иге", "when" -> "црут", "next" -> "туче"); de/fr (literal word) 0.35–0.48% -> 0.09–0.16%.
  - False positives on real L words roughly halved (de-ru 19 -> 10, pt-ru 19 -> 8).
  - Recall (Cyrillic typed on L) down 0.2–0.5 points, worst pl-uk 0.9937 -> 0.9890; those words are still fixed by the hotkey.
- The earlier "all six Latin models" gate (recall 0.989) stays rejected; only en is added.

---

## After v1.3.12 — uk always gated by the ru model too (`0be61af`)

- The owner still got "еще" -> "tot" with only ABC + Ukrainian-PC enabled: the cross-script gate (`d5ca6d2`) consulted enabled layouts only. Shipping the unfiltered uk model again was tried and reverted: it would also blur the hotkey's ru/uk choice (`bestConversion`) for users with both layouts.
- `decideAutoTarget` now adds the ru model to the gate whenever the current layout is uk, enabled or not. Same rule as measured with ru enabled (recall en<->uk 0.994 -> 0.992, Russian-on-uk junk 1.17% -> 0.15%); not re-measured. ru is not gated by uk in return: not reported, not measured.

---

## After v1.3.12 — "Between similar layouts" (auto ru <-> uk) removed (`b797c71`)

- The experimental opt-in never worked well enough in daily use and got in the way, so it is gone on both platforms: the Settings checkbox and its ⓘ, `autoSameScript` / `AutoCorrectSameScript`, engine `sameScript:` with `autoSameScriptMargins`, the switch-only path for an unchanged word, and the `settings.autoCorrectSimilar*` strings. Auto-correct is cross-script only again. Kept: the hotkey's model-based choice among same-script targets (`bestConversion`), the twin-layout fallback, the dict_uk-filtered uk model and the any-layout-of-the-script junk gate.

## After v1.3.10 — no second Cmd+C probe within a second

- With nothing selected and an empty word buffer in an app without an Accessibility selection, every hotkey press probed with a synthetic Cmd+C; two presses in a row were DeepL's Cmd+C-Cmd+C trigger and opened it. The probe is skipped for a second after one that found nothing. Same guard on Windows (`retypeViaClipboard`, Ctrl+C).

---

## v1.3.12 — Cyrillic junk gate, chain bridge, learned-words editor (2026-10-12)

- Tagged `dfa4a49`; notes `docs/release-notes/v1.3.12.md` + `-windows.md`. First release signed by CI with the rotated key (no manual re-sign); the appcast item carries the informational marker for installs below 1.3.8.
- Contents: the "After v1.3.11" blocks below — junk gate over every enabled model of the script (`d5ca6d2`), punctuation gate −3.6 (`5b4c634`), chain bridge (`f9fc48e`), learned words vetted / three corrections / phrase rule (`d3322fb`, `fa9a9c3`, `2036347`), the editor on both platforms (`91fbd75` … `7f4dbfa`), closable windows and hint placement (`ec1c21f`, `84eca95`).

---

## After v1.3.11 — the Learned-words window as an editor

- Shows all three kinds: confirmed `convert` verdicts, `keep` words and the candidates still being counted (their conversion is stored now: `autoLearnCandidates` / `AutoCorrectLearnCandidates`). A checkbox column (green on macOS) is on for convert and keep, off for a candidate; clicking it promotes a candidate, demotes a convert to a candidate (count 1), or drops a keep. Both lists (Learned words, Exceptions) draw like Login Items: table and a ⊕/⊖ footer in one bordered box, ⊖ only with a selection, multi-select with Cmd/Shift. ⊕ in Learned words opens an empty editable row (Typed → Becomes, lower-cased through `learnedKey`, an empty Typed drops it); in Exceptions it is the old Choose…. Buttons on the left: Clean candidates and Reset, both confirmed; Done on the right; Remove, Choose… and the exceptions rows' hover ⊖ are gone (the footer ⊖ does it). The two text columns are sized to the clip by hand (`fitLearnedColumns`): autoresizing left the table wider than the box and scrolled sideways. Later the same day: rows full-width (`style = .plain`), ⊕/⊖ as plain "+"/"−" text glyphs of one size with a divider, columns refitted on every clip resize, the scroll position kept on a checkbox toggle, Esc drops the new row, an empty "Becomes" committed with Enter means keep (its placeholder says so), unchecking a keep demotes it to a candidate (stored with an empty conversion), Reset gone from the Settings window, the window description explains candidates vs confirmed verdicts.
- Windows: `WinLearned.swift` rewritten by the agent with `LVS_EX_CHECKBOXES` (the list view draws the box only in the first column, before Typed), "+"/"−" square buttons, label editing for Typed and an EDIT overlay for Becomes. Compiled in the VM; not hand-tested.

---

## After v1.3.11 — learned words vetted by the target model

- Every word of a hotkey conversion landed in the learned list, single letters included. Two causes in `hotkeyMisses`: a 1–2 letter word counted as a miss unconditionally (added for "jr?" → "ок"), and a deliberate transliteration of correct text (select "та ще халепа", hotkey) made every word a `convert` verdict — then typing that word normally would auto-convert it to junk.
- Fix: a miss is learned only when its conversion reads in the target language (`autoLearnPlausible` −4.5 under the destination model): real misses do ("exit" −2.41, "ок" −2.78, "сброс" −3.41), transliterated correct text does not (−10…−18), a single letter has no trigram and sits at the floor. `hotkeyMisses` takes `dst`; both apps pass the plan's destination.
- Repeat threshold (owner's call): one hotkey press may be a one-off, the same correction three times is the model being wrong. A miss is counted (`autoLearnCounts` in UserDefaults, `AutoCorrectLearnCounts` in the registry) and promoted to `convert` on the third press (`autoLearnRepeats`); undo takes back the count or the verdict of that press. `keep` from an undone auto-correction stays immediate. Hint strings and README updated.
- Phrase rule (owner's call): when a whole phrase is still in the wrong layout with auto mode on, every word of 3+ letters evidently escaped it and is counted, whatever `decideAutoTarget` says now; short words are held on purpose and are not. A single word keeps the old rule.

---

## After v1.3.11 — hints live on ⓘ only

- Settings: the similar-layouts hint moved from the checkbox to an ⓘ, placed before the dash: "Between similar layouts (uk ↔ ru) ⓘ — experimental" (the string is split at the dash at runtime, no new keys). Both platforms.
- macOS: the Exceptions and Learned-words windows were sheets, which have no close button; they are titled windows now (`.closable`, centered over Settings, the name in the title bar instead of a bold label), like Windows.
- Tried and reverted the same day (`088d784`, `1fb2fee`): moving the Exceptions ⓘ out of the sheet to the Exceptions… button and dropping the sheet's sub-heading. The owner preferred the sheet as it was.

---

## After v1.3.11 — a short no-candidate word bridges the chain

- "nf ot [fktgf" (та ще халепа) converted only "халепа": "nf" waited as a short candidate, "ot" reads as English (−2.45, above the garbage line, and under the margin even at −2.2), and a word without a candidate broke the chain. Rule added: a 1–2 letter word with no candidate right after a chain word is bridged (`AutoRun.bridge`, its reading in the chain's layout via `transliterate`), and is retyped with the chain when a long candidate or a second short candidate commits it; alone it never converts, a long no-candidate word still breaks the chain. Both apps remember the last candidate's layout for the bridge. Tests in `AutoRunTests`.

---

## After v1.3.11 — punctuation gate relaxed to −3.6

- "та же халепа" typed on ABC: "[fktgf" stayed. Not the trigrams: "халепа" reads −3.15 under uk and the junk is at the floor, but "[" is х, so the word takes the absolute `autoPunctPlausible` gate, −3.0, and failed it. The gate's comment said real words score ≥ −2.6; measured on 20k-word lists, a third of real uk/ru words carry a punctuation-key letter (х ж э є ї б ю), and the gate at −3.0 rejected 14% of them (uk 0.864 / ru 0.862 pass), −3.2 → 0.92, −3.4 → 0.955, −3.6 → 0.978. On 39 English abbreviations only "vs"/"vs." fire at any setting (and they are held by the short-core rule). Set to −3.6, still above the ≤ −3.8 the original junk scored.
- "ot" (uk "ще") is a different, known case: "ot" reads −2.45 in English, above the garbage line, and even at −2.2 its margin is 0.45 < 0.5.

---

## After v1.3.11 — cross-script gate over every enabled model of the script

- Regression from the dict_uk cleaning, caught by the owner: "погоняем ещё недельку" typed on the Ukrainian layout came out "погоняем tot недельку". "еще"/"ещё" are not Ukrainian, so the clean uk model scores them −5.75 / −11.56 (the dirty one: −1.9), and their Latin reading "tot" is a real English word (−2.34): auto-correct converted. Measured on 3 933 Russian words typed on the uk layout: 1.17% converted to Latin junk with the current-layout gate (dirty model: 0.25%).
- Fix in `decideAutoTarget`: for a cross-script target the typed word is junk only if no enabled layout of its script reads it (max score over the ru and uk models when both layouts are enabled). Result 0.15%; en ↔ uk recall 0.994 → 0.992, pl ↔ uk 0.995 → 0.993. Gating the Latin side on all six Latin models was measured too (recall 0.989) and rejected; the gate uses enabled layouts only, so a uk-only install typing Russian is not shielded — the hotkey teaches those words. Same-script (ru ↔ uk) decisions keep the current layout's score: there the other model is the alternative.
- Also looked at the garbage threshold for "tot"-class words (real English words that read as Russian): −2.2 instead of −2.5 costs +0.02–0.04% false positives on en/de ↔ ru and gains nothing measurable on the lists; left at −2.5, the learned words cover "tot" after one hotkey.

---

## After v1.3.11 — Leipzig corpora tried for all eight models, not shipped

- Hypothesis: the subtitle-only lists (50k words) starve the models of normal prose, which is why the ru model underrates "ы" words ("тысяча" −3.00). Built every model from a 1 : 1 : 1 mass-normalized mix of the subtitle list, Leipzig News 2024 (1M sentences) and the most recent Leipzig Web crawl for the language (`scripts/trigram/merge.py`; uk re-filtered through dict_uk), then measured against the shipped models with the same scripts.
- Result: nothing to ship. Cross-script pairs with ru/uk: recall equal or 0.001– 0.002 lower, false positives equal or slightly higher, for all six Latin languages. ru ↔ uk same-script recall down (0.345 → 0.305 into ru, 0.253 → 0.200 into uk). "тысяча" −3.00 → −2.83, still garbage; "рыба" unchanged; "ё" words down ("всё" −1.53 → −1.75, "ещё" −1.75 → −1.97) because the press writes "е"; weighting subtitles 2 : 1 : 1 softens but does not reverse it. de ↔ en within Latin 0.971 → 0.960, fr/es unchanged.
- Weights on the shared trigrams (100 % of the old ones survive): mean |Δ| 0.6, a fifth of them move by more than 1 (the size of a margin), no systematic shift. The first build also taught the Cyrillic models Latin trigrams from the web crawl (88 third-letters in ru instead of 69); `merge.py --script` now drops words outside the language's script. The "ы" weakness is structural (the pronoun "ты" owns the "ты" context under frequency weighting), not a corpus-size problem.
- Kept: `merge.py` (with `--script`, `--weight`) for the next attempt; the shipped models are unchanged. Data: Leipzig 1M archives are CC BY, ~200 MB each, public downloads cap at 1M sentences.

---

## v1.3.11 — hotkey cycle, target after undo, pl/pt models (2026-10-11)

- Tagged `d3e331e`; notes `docs/release-notes/v1.3.11.md` + `-windows.md`. Contents: the "After v1.3.10" blocks below.
- Key-rotation mistake, found by the owner on 1.3.8 → 1.3.11: "The update is improperly signed". 1.3.8 (the transition release) already embeds the new SUPublicEDKey, so every later item must be signed with the NEW private key; 1.3.9, 1.3.10 and 1.3.11 had been re-signed with the OLD one (the transition recipe applied once too often). Fixed: `resign-appcast` takes `key=next` and replaces an existing signature; `build.yml` now signs with `SPARKLE_ED_PRIVATE_KEY_NEXT`; 1.3.11's item re-signed with the new key. Users still on ≤1.3.7 would see the same error on 1.3.11 (one signature per item): every item is now marked informational for installs below 1.3.8 (`scripts/appcast-informational.py` in `build.yml`, applied by hand to the live 1.3.11 item), so they get "a new version is available" with the release page as the link instead.

---

## After v1.3.10 — the Cmd+C fallback restores every clipboard flavor

- The hotkey's Cmd+C fallback (apps without an Accessibility selection, e.g. Electron) saved only the pasteboard's string flavor and put that back: a copied image or file was wiped, rich text came back plain, and an old text copy (Universal Clipboard from a phone included) resurfaced as the only content. Now every pasteboard item with every flavor is snapshotted and restored.

---

## After v1.3.10 — the Globe double is counted once

- The doubled first letter after a Globe switch (TextInputSwitcher re-posting the key its HUD held; see "After v1.3.8") turned out to reach the app once but the auto tap twice: "после гтвщ" buffered as "ггтвщ", the fix erased five characters for four on screen and typed "uundo" — space gone, letter doubled. Caught with three layouts enabled (Globe cycles ABC → Birman ru → uk, so the first letter of the next word lands on a Cyrillic layout).
- Fix in the auto tap: a keyDown with the same key code as the last fed one, within 300 ms, whose `eventSourceUnixProcessID` belongs to `com.apple.TextInputSwitcher`, passes through to the app untouched and is not fed to the word buffer. Dropping it was rejected earlier for the case where the physical press never reaches the app; counting it once is right either way. Not unit-testable (CGEvent); verified by the trace pattern only.

---

## After v1.3.10 — hotkey press-again cycles the layouts

- With three or more layouts the hotkey's first pick can be the wrong one, and the only recourse was undo + switch + hotkey. Now a repeat press within the undo window retypes the original into the next layout, and the press after the last reading is the undo. Engine `retypeAlternatives` (distinct conversions of the typed text into every other enabled layout, ranked by the destination model, modelless layouts last); macOS `performRetarget` reuses the undo's reselect and carries `learned`/`autoWords` so the final undo still unlearns. Two layouts: unchanged. Double-tap hotkeys: unchanged (no cycle, no undo). Auto-corrections: no alternatives, second press = undo.
- After an undo (or a retarget) the hotkey did nothing without a selection: the undo reset the word buffer, so `hotkeyTarget` was empty. Both apps now hand the restored text to `AutoRun.remember`, which keeps it whole (spaces and punctuation included) as the hotkey target until the next key, nothing visibly selected. Replaying it through the word buffer was tried first and split "б§kj" at the "§", shrinking the target to "kj".

---

## After v1.3.10 — hotkey past a same-script twin layout

- With three layouts where two share the script and the keys (US + Polish Programmers + a Cyrillic one), the hotkey from the Polish layout picked the positional target (US), converted nothing (same keys) and gave up; from US it picked Polish, same result. `planRetype` now falls back to the other-script target when the positional pick changes nothing. Test `testPlanFallsBackToTheOtherScriptPastASameScriptTwin`.
- Polish and Portuguese trigram models added (`pl.txt`, `pt.txt` from the FrequencyWords 50k lists, same `gen.py`): a Polish or Portuguese layout paired with a Cyrillic one had no auto-correct at all (the engine needs the current layout's model). Cross-script eval at the shipped thresholds, EN key rows as the Latin map: pl ↔ ru recall 0.995 / fp 0.03%, pl ↔ uk 0.995 / 0.05%, pt ↔ ru 0.996 / 0.07%, pt ↔ uk 0.996 / 0.05% — on par with en (0.994 / 0.1%). Belarusian still missing: its subtitle list needs a dictionary filter like uk.

---

## v1.3.10 — learned words, trigram layout choice, uk ↔ ru opt-in (2026-10-10)

- Tagged `b738f35`; notes `docs/release-notes/v1.3.10.md` + `-windows.md`. Still signed with the old Sparkle key (rotation due ~2026-10-22), appcast item re-signed by `resign-appcast` and verified on `gh-pages`.
- Contents: the "After v1.3.9" blocks below — learned words (`b420bf1`, `adca40f`), Windows port (`d74e8ef`, `50ec676`, `da58159`, `e41b174`), trigram layout choice and the experimental uk ↔ ru option (`39018b2`, `f166c86`, `75c5c78`), the dict_uk-cleaned uk model (`8960ec5`).

---

## After v1.3.9 — the Ukrainian model cleaned of Russian

- The uk FrequencyWords 50k list (OpenSubtitles) is 18 753 of 50 000 words and 25.5% of the mass Russian ("что", "ты", "это", "как" are in its top 10). That is why the uk model read Russian as plausible. `scripts/trigram/filter.py` keeps only words dict_uk (brown-uk, 3.9 M word forms) knows; `gen.py` then gives 31 095 words, 7 704 trigrams, 34 third-chars (was 49 420 / 15 379 / 74: ы, э, ъ, ё and Latin letters are gone). File 221 KB → 115 KB.
- Measured. Cross-script uk ↔ en at the shipped thresholds, 7 110 positives / 7 110 negatives from the list and en_50k: recall 0.993 → 0.994, false positives 10 → 9 (a holdout-trained variant: 0.992 / 23). Same-script set (70 wrong-layout, 85 right-language words): 33 → 36 converted, 0 → 0 false. Russian words typed on the uk layout: "что-то" uk −1.42 → −5.56 (fires), "как-то" −1.72 → −2.54 and "пожалуйста" −2.12 → −2.98 now count as garbage but miss the 1.5 margin against the ru model; "двигатель" stays (ru −2.46).
- The raw list reproduces the previously shipped model byte for byte, so the generator is unchanged; only the input is.
- Margin per target language (`autoSameScriptMargins`): the cleaned uk model is strict, the ru model loose, so the directions differ. Sweep on 6 000 Russian + 6 000 Ukrainian words from the lists: typing Russian on the uk layout — margin 1.0 gives recall 0.345 at 3/6000 false (1.5: 0.293, 1/6000); typing Ukrainian on the ru layout — 1.0 gives 11/6000 false ("пыль" among them), 1.5 gives 4/6000. Shipped: into ru 1.0, into uk 1.5. Hand-picked set: 46/78 converted ("кто-то", "как-то", "пожалуйста", "хорошо" now switch), 1/117 false ("сіно"). Still plausible Ukrainian to the uk model: "привет", "почему", "нужно".
- Tried and rejected: damping the word-frequency weight in `gen.py` (sqrt, log instead of raw count) to stop "ты" (the pronoun) swamping the "ты" context, which sinks "тыс" to −4.6 and "тысяча" to −3.0 in the ru model, so "тісяча" typed on the uk layout misses the margin (0.50 of 1.0). Regenerated all six models each way: ru/uk ↔ en unchanged, de/fr/es ↔ en recall down (0.61 → 0.46 → 0.40 for de), same-script recall down, and "тысяча" itself worse (−3.25 sqrt, −3.54 log). The generator stays as it is; a larger Russian corpus is the remaining lever for "ы" words.

---

## After v1.3.9 — auto mode converts between Cyrillic languages

- `decideAutoTarget` took only layouts of the other script. Now same-script layouts of another language are candidates too (ru ↔ uk: "ъжа" → "їжа", "єкран" → "экран"), under the usual gates plus `autoSameScriptMargin` 1.5 instead of 0.5: with 0.5 the Russian model's low scores for "ы" words sent "рыба", "дым", "пыль" to Ukrainian.
- Eval (scratch, real models, the four-letter ru/uk key difference): 30/54 wrong-layout words converted, 0/68 right-language words touched. Misses are words plausible in both languages ("місто"/"мысто", "дім"/"дым") and the uk → ru direction, where the Ukrainian model accepts most "і" words.
- Same-language pairs (ru / ru-PC) are never candidates: the text would not change.
- A word without the layouts' distinctive letters ("мабуть", "дякую" on the Russian layout) converts to itself: the engine returns it unchanged and both apps switch the layout only, no retype, no undo record. Needs the same 1.5 margin, so "якась халепа" (uk −2.58 vs ru −3.26, and a tie) stays.
- Known ceiling, uk → ru: the Ukrainian model reads common Russian words as plausible ("что-то" −1.42, "двигатель" −2.59, "пожалуйста" −2.12), gaps of 0.1–0.3, so typing Russian on the Ukrainian layout never switches back. A threshold cannot fix it; the uk model needs a cleaner corpus or a discriminative weight against ru trigrams in `scripts/trigram/gen.py`.
- Windows Settings: the learned-words buttons sit flush right like Exceptions….
- Windows: "Ybrmt" buffered as "ybrmt" and converted to "никте". The low-level hook translated keys with `GetKeyboardState`, which reflects the hook thread's own input queue, where Shift is never down. The live Shift/Ctrl/Alt state from `GetAsyncKeyState` (and the CapsLock toggle) is now overlaid before `ToUnicodeEx`.
- Shipped as an opt-in marked experimental (Settings → "Between similar layouts (uk ↔ ru)", `autoSameScript`, engine `sameScript:` default off): the miss rate above is too high to call it a feature. Custom layouts count by their declared languages (Ilya Birman's Russian Typography reports "ru").

---

## After v1.3.9 — the hotkey picks the layout by trigram score

- With several layouts of the other script enabled (ru + uk, en + de) the hotkey chose by position (`pickTarget`: the first, or the second). Now `planRetype` converts into every candidate and keeps the one whose language model reads the result best (`bestConversion`, length-weighted mean word score); the "switched after typing" path chooses its source layout the same way under the current layout's model. Only installed layouts' models are consulted; `pickTarget` stays as the fallback without models. Auto mode already chose its target this way.

---

## After v1.3.9 — learned words: the hotkey teaches auto mode

- Trigram-only detection has a known ceiling: a short word of rare letters loses to a substring of a frequent word in the other language ("учше" scores −1.94 in Russian, "exit" −2.41 in English), and a Russian word typed against a Ukrainian-only setup ("c,hjc" → "сброс", uk −3.41) fails the punctuation gate. A language dictionary is off the table by design, so the fix is the user's own verdicts: the hotkey already marks every auto-mode miss.
- Engine: `LearnedVerdict`, `learnedKey` (lowercased, trailing non-letters dropped), `hotkeyMisses` (words of a hotkey conversion that `decideAutoTarget` would leave), and a `learned` closure on `decideAutoTarget` — `keep` wins before any gate, `convert` bypasses garbage/margin/punctuation gates. The short-word neighbour rule still applies.
- macOS: `convert()` learns misses with auto mode on; the undo of a hotkey conversion forgets them, the undo of an auto-correction records `keep`. Settings: "Learned words: N" with View… (sheet, Remove) and Reset (confirmed: irreversible user data). Nine new `settings.learned.*` keys in all 12 languages.
- A short hotkey conversion ("jr?" → "ок,") is a miss too, and a learned word is fixed alone: `AutoRun.plan(trusted:)` skips the neighbour rule for it.
- Side fixes found on the way: a language change kept the cached sheets in the old language (now dropped); the version footer was hardcoded English; "Also fix on Enter" lost its "also" in all languages; the Settings window opens without the zoom animation.
- Security review after the push: learned words are persisted plaintext, and the hotkey path had no secure-field check, so a password converted in a password field would have been stored. Learning now runs under the same `isAutoExcluded` gate as auto mode (password fields, deny-listed apps).
- Windows port (same day): learned words and the uk ↔ ru option wired — registry `AutoCorrectLearned` / `AutoCorrectKept` (REG_SZ) / `AutoCorrectSameScript` (REG_DWORD), hooks on both hotkey paths and both undo paths, Settings checkbox plus "Learned words: N" with a confirmed Reset. A "View…" list window (`WinLearned.swift`, a copy of the exceptions editor with a two-column list view) followed. Built in the UTM VM, hand-testing pending. The port also exposed a macOS bug: the view list paired a miss with the wrong output word when an earlier selected word was not a miss (fixed).
- Rejected on the way: a typing-series history of judged words (the hotkey itself is the signal) and a pause-based series boundary (a pause is thinking, not proofreading).

---

## After v1.3.8 — two short words in a row are fixed together

- Auto mode trusted a 1–2 letter candidate only next to a long one, so a chain of short words ("пщ ещ еру" for "go to the") was never fixed: each short word replaced the previous pending one and a correct word after them dropped it.
- `AutoRun.planFix`: a short candidate right after a pending one of the same script commits both in one edit; the chain then continues under the existing "short after committed" rule. Test `testTwoShortWordsInARowAreFixedTogether`.
- By design: one pending short word followed by a correctly typed word after a manual layout switch ("пщ to the") is left alone — the hotkey covers it.

---

## After v1.3.8 — the doubled first letter is macOS, not reLayout

- Closes "the doubled first letter" (below, after v1.3.5). Rebuilt the per-key trace (uncommitted, removed after) with each keyDown's source pid, keyboard type, autorepeat flag and delta time. Seven duplicates caught in daily typing (`ґґ`, `сс`, `уу` …): each was a real keyDown from pid 0, then, right after a Globe press, a second keyDown of the same key code from `TextInputSwitcher` (keyboard type 91, pid of `/System/Library/CoreServices/TextInputSwitcher.app`), 30–200 ms later and typed in the new layout (`kл`). reLayout held nothing at the time (`pending=0`).
- Reproduced with reLayout quit, via a listen-only tap logging key codes and source pids only: one injection in ~25 Globe switches, none in ~50 more on purpose (double/triple Globe + letter) — intermittent, trigger not found.
- Not filtered: the switcher probably re-posts keys it swallowed while its HUD had the keyboard, and a tap cannot tell whether the physical key also reached the app, so dropping the injected copy could lose a letter. Workaround for a user who hits it: switch input sources with Ctrl+Space instead of Globe.
- Seen on macOS 26.7.1 (25G241). The listen-only tap is kept as `scripts/keyspy.swift` to re-check after a macOS update (27+): if no `<<< INJECTED` line shows up over a day of Globe switching, Apple fixed it.

## v1.3.6 — terminals: hotkey on the typed word, no Enter follow-up (`44ef948`, notes `a68e73d`)

- The typed-word buffer is fed everywhere, so the hotkey with nothing selected already worked in macOS terminals. Windows blocked the hotkey in consoles outright (selection read sends Ctrl+C); now a console converts only the typed word, never a selection or the clipboard. Verified by hand in the UTM VM.
- The Enter follow-up could misfire in a terminal: a silent command (`ssh host`) leaves just the line break for >75 ms, which reads as `.newline`, and the backspaces would go to the running program. Skipped where the focused text view's `AXValue` is not settable (Terminal, Ghostty) — a field property, no app list; kitty reports a settable value like a normal field and stays covered only by the default exclusions. Windows skips it via `foregroundIsConsole()`.
- Probed later: Warp (non-settable `AXTextArea`, no `AXStringForRange`) and WezTerm (focus reports the `AXWindow`, no text element) are skipped too. iTerm and Alacritty not probed.

## After v1.3.5 — the doubled first letter (`ччасть`), investigated, not fixed (macOS)

- Report: auto mode sometimes turned a word into one with its first letter doubled (`xfcnm` → `ччасть`). Caught once in a trace (Claude desktop): the buffer held `rкакю`, the mixed-word reading converted the Latin head, and `ккакю` was typed over 5 erased characters. The field there is unreadable over AX, so whether the stray head was on screen or only in the buffer stayed unknown.
- Measured over two days of traced typing: after a Globe press the current input source reported by TIS lags ~0.5 s — the next two keys still read in the old layout (`зуpr` buffered for `pepr`), while the event's own string lags further. Harmless when the lengths match: the mixed-word reading converts the stale head and erases exactly the typed length. No duplicate or phantom key events were seen (2085 keys, 2085 events).
- Likeliest reading of the catch: a typo right after Globe, three backspaces for four letters, the word retyped — so the doubled letter was already on screen and the fix retyped it unchanged. Unconfirmed; the trace instrumentation (buffered `dbg`, per-key keycode/event/layout lines, backspaces, held/replayed keys, the field tail after a fix) was reverted. If it recurs: rebuild it and catch the case in an app whose field AX can read.

## After v1.3.4 — VS Code selection on Windows

- The hotkey in VS Code converted a line the user never selected. VS Code reports no selection over UI Automation unless its accessibility support is on, and `Ctrl+C` with nothing selected copies the whole line, which the old guess (does the text end in a line break?) could not reliably tell from a real selection.
- `copiedFromEmptySelection` reads the mark Chromium puts on its own copy (`isFromEmptySelection` in its clipboard metadata, the same signal the macOS app uses); the trailing-newline guess stays as the fallback when the mark is absent. `performRetype` now prefers the word it saw typed when UIA reports nothing selected, and asks the clipboard only when there is no such word.
- Verified in the UTM VM on a worktree build off `dd997c6`: a real selection, a just-typed word with nothing selected, and a caret parked in existing text (which must do nothing). `cb9ce50`

## After v1.3.3 — the typed character comes from the layout, not from the event (macOS)

*(`b2eec3e`)*

- Auto mode read each typed character from the key event itself (`keyboardGetUnicodeString`). The tap sits at the head of the session tap, upstream of the window server applying the keyboard layout, so after reLayout switched the layout the event kept carrying the previous layout's letters while the app already inserted the new ones. Both reported symptoms are that one gap: a word typed as `ghjcnj` buffered as `просто` — a plausible Russian word, so the conversion never fired — and the mirror case buffered Latin for a word actually typed in Cyrillic and "converted" it into the text already on screen, retyping it unchanged.
- `layoutChar(_:)` now derives the character from the physical key and modifiers through the current layout's `strokeToChar` (Shift/Option via the event flags, Caps Lock as upper case). The event's string stays as the fallback for keys no layout maps: Return, Tab, dead keys, IME input. This matches what the Windows port always did (`ToUnicodeEx` with the focus window's HKL).
- Measured, not guessed: a debug trace comparing the event's character, the current layout's character and the text the app inserted, across TextEdit and a Chromium app, in both directions. The layout's character matched the screen every time; the event's did not. TIS was never the liar — two earlier fixes built on that assumption (layout inferred from the buffered characters, and the word re-read from the field over Accessibility) were dropped once the trace showed where the divergence came from; the Accessibility route is dead in Chromium windows anyway.
- The debug trace it took to find this is kept: the switch's TIS status (`selectLayout`), the applied fix, and the focused app on every `feed` line. `dbg` takes its message as an `@autoclosure`, so none of it costs anything in a release build.

## After v1.3.2 — hotkey converts the word being typed (both platforms)

- With nothing selected, the hotkey converts the word typed before the caret: the auto-mode `AutoRun` buffer (word + trail). The key monitor now feeds the buffer whether or not auto-correct is on; only the boundary/Enter corrections stay behind `autoMode` (macOS `autoFeed`, Windows `autoFeed`). Every reset condition is unchanged, so an empty buffer (after a space, a click, an arrow, a shortcut, a focus change) still means nothing to convert. macOS snapshots the buffer in `triggerHotkey` and `retypeTyped` erases it with `eraseBack`; Windows `retypeTyped` backspaces it and types the conversion with `typeText`. Undo works as for a selection. Verified in VS Code on macOS ("ghbdtn" → "привет" → undo; "a ghbdtn" → "a привет").
- Spaces after the word keep it the target (a word is usually finished with a space by reflex): engine `AutoRun.hotkeyTarget` = the word being typed, else the last word + the count of spaces after it; the hotkey erases word + spaces and types the conversion + the same spaces. Any other key after the spaces, Tab/Return, and any conversion (`plan` drops it on a fix; platforms reset after hotkey and undo) end it; backspacing all the spaces rejoins the word and drops `previous` so the short-word rule cannot pair the word with itself.
- macOS: two typed spaces fired the system's "period with double-space", which VS Code applied at the wrong place ("ghbdtn  " → "прив.  т"). `typeUnicode` now sends a run of spaces as one event. Verified in VS Code with auto-correct off: one and two spaces, each with the undo.
- Unknown on macOS: whether a Carbon combo hotkey's keyDown reaches the session tap first — if so its Cmd/Ctrl reset empties the buffer before the hotkey fires. The default modifier-tap hotkey is unaffected; on Windows the hook swallows the combo before `autoFeed`.

## After v1.3.1 — macOS: line breaks and empty selection in VS Code

- A line break retyped by the hotkey vanished in VS Code: a lone Unicode `\n` key event inserts nothing there (tested: per-character `\n` joined the lines, `\n` inside a multi-character event did not). A triple-clicked line lost its break, two selected lines were joined, and the press-again undo then selected one character too many and ate the break before the line. `typeUnicode` now sends a line break in one event with its neighbour.
- With nothing selected, VS Code's Cmd+C copies the whole caret line, which the hotkey converted. The text is identical to a triple-clicked line; only VS Code's clipboard metadata (`"isFromEmptySelection":true` inside `org.chromium.web-custom-data`) tells them apart, so `copySelection` treats that copy as no selection. Verified end to end in VS Code: one line, two lines, no selection, each with the undo.
- Cmd+Z after a hotkey retype still undoes in pieces in VS Code: each synthetic key event is its own undo step there (20-character events only cut the count). One step would need a paste, which the no-clipboard write rules out.

## After v1.3.0 — macOS: auto-correct in VS Code

- Auto-correct in VS Code (Electron) could leave the wrong word half-erased: "ЬфсЩІ " became "ЬфсЩMa", and Cmd+Z showed "ЬфсЩMacOS". VS Code applied one delete, then the retyped text, then the remaining deletes. The deletes went out as one unpaced burst, 10 ms ahead of the text. `eraseBack` now paces them (1.5 ms each) and waits 30 ms before typing; it is shared by `autoCorrect` and the Enter follow-up. A synthetic replay did not reproduce the bug; the user confirmed the fix on a dev build.

## After v1.3.0 — Windows fixes

- Disabled check-box titles in Settings read clean in dark mode (`1c4ebe0`): a disabled static ignores WM_CTLCOLORSTATIC and draws etched text, smeared on the dark background ("Also fix on Enter" while auto-correct is off). Only the box is disabled; its title stays enabled and is painted gray. Checked in the UTM VM in both themes.
- The VK_PACKET batching limit is recorded as an observation, not a documented rule (`148416d`).

## v1.3.0 — Windows port (preview), shared engine, selection-only hotkey

Released 2026-09-19 (tag `v1.3.0` on `ce2e535`, 50 commits from `5b51064`). The frozen Windows MVP was audited, rebuilt to feature parity with macOS and shipped as a preview; the platform-free logic moved into the engine; the hotkey became selection-only on both platforms. Entries below run oldest-last within the block.

- Release: macOS dmg/zip + Sparkle appcast + Homebrew cask, and — first time — the Windows installer and portable exe for x64/ARM64 (CI build `35401084438`). Notes split per platform: `docs/release-notes/v1.3.0.md` (macOS, Sparkle window) and `v1.3.0-windows.md`, one line per bullet (hard wraps rendered as `<br>`); the published release body and the appcast item were corrected by hand (`a7e3669`, gh-pages `c9b6cc1`). `.claude/commands/release.md` updated for both.
- Landing page (`index.html` on `gh-pages`, `95907cd`): macOS and Windows downloads (the visitor's OS picks the primary button), per-platform install sections, the stale "Nothing selected? grabs the line" item replaced. Backlog (`a7b13d5`): a Windows default hotkey closer to macOS', and a Windows keyboard in the demo.
- Dev loop: Windows builds and runs in the user's UTM VM over SSH (`scripts/build-windows.ps1`, ~30 s vs ~6 min on CI), launched into the desktop session with a scheduled task; `-DebugLog` adds the keystroke diagnostics.

### Windows port — audit fixes, batch 1

An audit of the frozen Windows port (written by an older model) found 15 bugs and 31 risks. The first batch fixes input and layout handling:

- Layout maps skip numpad VKs and probe modifiers before keys, so `.`/`,`/`/` convert and plain strokes win. Layouts compare by the full HKL, not the LANGID.
- Waits pump messages (`pumpWait`) instead of `Sleep`: the low-level hook runs on the same thread, and Windows drops a hook that keeps timing out.
- Ctrl+C read polls the clipboard sequence up to 500 ms and retries `OpenClipboard`. A copy ending in a line break counts as "no selection" (VS Code/JetBrains copy the whole line). Non-text copies no longer fall back to Shift+Home over the user's selection.
- Home/Right go out with scan codes and the extended bit (NumLock broke Shift+Home).
- The combo key is swallowed; Alt/Win combos inject mask key 0xE8.
- Modifier wait covers Win and aborts on timeout. A blocked `SendInput` skips the layout switch. A named mutex keeps one instance.
- Batch 2: layout maps cached per HKL (built once, not on every press). A failed `SetWindowsHookExW` shows an error and exits instead of running without a hotkey. The hook stays on the main thread: with `pumpWait` and the cache there is no long stall left, and a hook thread would share hotkey state across threads.
- Batch 3: tray icon re-added on `TaskbarCreated` (Explorer restart, early autostart); `WM_NULL` after the tray menu; launch-at-login counts only when the Run value points at this exe, and is disabled in the portable build (CI puts a `portable` marker in the SFX). Settings frees its `HFONT` on `WM_NCDESTROY` and re-reads the checkbox after each toggle. CI: SFX stub from the hash-pinned LZMA SDK 26.03 (plain `7z.sfx` ignores `RunProgram`; 7-Zip Extra has no SFX stubs), app-local MSVC CRT, `gha-setup-swift` pinned to a SHA, `ref_name` passed via env, `core.yml` gets `workflow_dispatch`.
- Batch 4: no conversion in terminal windows (Ctrl+C would interrupt the program). Line breaks type as a real Enter, not a VK_PACKET U+000D — so a break inside a one-line field submits it. A bare Alt/Win tap hotkey replays its swallowed release behind mask key 0xE8. Layout read and switch go through the focused window (`GetGUIThreadInfo`, for UWP). `keyName` sets the extended bit right.
- Batch 5: the user's clipboard is saved before the Ctrl+C read and restored after it (memory-backed formats only, up to 64 MB; the tray window owns the restore; tagged `ExcludeClipboardContentFromMonitorProcessing` to stay out of Win+V history).
- The rule is now both platforms': macOS lost both Shift+Cmd+Left line grabs, the `lineGrab` branch of `convert()` and the Cmd+X read that existed only for them (`6317f9d`). A shipped behavior is gone with it: after typing a word, the hotkey no longer fixes it unless it is selected — that case returns with the auto mode and its typed-word buffer, whose agreed rules are: on by option only, fires on space/Enter/Tab, resets after firing and on arrows, a mouse click or a focus change. Modifier combos still to decide.
- UIA needed `objbase.h` before `uiautomation.h`: `WIN32_LEAN_AND_MEAN` keeps it out of `windows.h`, and the `interface` keyword was undefined (`0af53e4`). Green on x64 and arm64 (run 35277002142).
- Nothing here is hand-tested yet; only the macOS engine tests (54) run, and they cover neither `convert()` nor the read paths.
- Hand test on Windows (UTM, arm64): Enter follow-up, hotkey recording incl. double tap, tray and autostart OK. Undo "didn't work" because the hotkey was a double tap, where undo is off by design (as on macOS). Password fields were corrected on Google's login page: the check ran only on a focus-window change, and a browser page is one window — it now runs as each word starts (one UIA call per word; a password never enters the run), matching macOS' per-evaluation AX check.
- Windows Settings polish: the hotkey field is a button (no selectable text or caret; click/Space records, losing focus cancels); the window width follows the widest row, like the macOS window; the update check and its menu item exist only in release builds (a numeric version) — local "dev" and CI's "0.0.0-dev" skip it. The tray glyph follows the taskbar theme like the macOS menu-bar icon: two new icon resources (2, 3) built from `Resources/for-{light,dark}-text-1024.png`, picked by `SystemUsesLightTheme` and swapped on WM_SETTINGCHANGE "ImmersiveColorSet". Tap sequences stay at ×2: five Shift presses open Windows' Sticky Keys prompt. Settings, Exceptions and the tray menu follow the theme too (`WinTheme.swift`, `native/relayout_theme.cpp`): a DWM dark title bar, the system's DarkMode_Explorer / DarkMode_CFD control styles, background, text and 1 px separators painted in the theme's colors, and the tray menu via uxtheme's undocumented SetPreferredAppMode (ordinal 135; a no-op if missing). A themed check box draws its title black in dark mode, so each title is a separate label that clicks its box. Settings' logo stays the app-icon tile in both themes, as on macOS (a themed bare glyph was tried and rejected); both windows rebuild on a theme switch — once, 300 ms after the burst of setting broadcasts and only if light/dark really changed, with painting held off (WM_SETREDRAW) and one redraw after; tearing the controls down in view flickered. Settings' logo was then settled as the app-icon tile in contrast to the window: a dark tile with white letters in light mode, the app icon's light tile in dark mode (resources 4/5, drawn like the macOS icon in build.sh). The keystroke diagnostics log is compiled into DEBUG builds only (`scripts/build-windows.ps1 -DebugLog`); a release exe no longer contains it, matching the macOS rule for dbg(). The local build script stamps the About link's repo from the origin remote, like scripts/build.sh, and restores Identity.swift afterwards.
- Windows unfrozen: `build-windows` now also runs on `v*` tags and attaches the installer and portable exe (x64, arm64) to the Release, versioned from the tag. Still unsigned. A light update check replaces auto-update for now (`WinUpdate.swift`): GitHub's latest release a minute after start and daily, over WinHTTP (not in Swift's WinSDK module, so `relayout_http.cpp` joins the UIA code in the C++ target, renamed `RelayoutNative`, `windows/native/`); a newer one (engine `isNewerVersion`, tested) is announced once per version in the tray and listed at the top of the menu, which opens the release page; "Check for Updates…" checks on demand. Dev builds skip it. The tray menu now matches macOS: Check for Updates…, Settings…, Quit — launch at login moved to Settings only.
- Typing is real keys now (`typeText`): the focused window is switched to the target layout first (polled until `GetKeyboardLayout` agrees, ≤300 ms), then the text goes out as that layout's key presses (+Shift/AltGr) in one SendInput batch. VK_PACKET could not be batched: a busy Windows 11 Notepad read the same character for several presses ("цштвщц оооооо …", "xnjnj" -> "ооото", and a character sent right after a packet space became a space). Undocumented; the explanation we worked with — one pending packet character per thread, overwritten before the app reads it — is an inference, and the tests ran in UTM (QEMU, Windows on ARM), so virtualization may carry part of it. Pacing only made it rarer and typed slower than a hand. Characters the layout lacks fall back to Unicode events paced at 1 ms (`timeBeginPeriod(1)`, winmm). Line breaks, spaces and tabs are real keys everywhere. Undo types the original the same way in the source layout.
- The UTM "aaaa" floods came from the reLayout on the Mac host: its auto mode corrected what it saw typed into the UTM window, and UTM forwarded the Unicode events' key code 0 — kVK_ANSI_A — to the guest. Quitting it on the Mac stopped them (confirmed twice). VM and remote-desktop apps are now default auto-correct exceptions on both platforms (macOS: UTM, Parallels, VMware Fusion, VirtualBox, Microsoft Remote Desktop; Windows: Hyper-V's vmconnect, VMware, VirtualBox, mstsc, msrdc) — removable and extensible like the terminals. A first cut hard-coded them outside the list and off for the hotkey too; the user rejected it (a new VM would be missing, and one may want reLayout on in a VM). New defaults reach a saved list once each via the engine's `mergeExclusions` and a "seen defaults" record, so a removed entry stays removed. The hotkey ignores exceptions, as before. An ⓘ in the Exceptions window (both platforms, key `settings.exc.info` in all 12 languages) says why a fresh install already lists apps. Auto mode in Windows consoles now follows the list alone (the hard-coded console check went), as on macOS: remove a terminal and auto-correct works there from the typed-word run. The hotkey stays off in consoles: typing goes to the shell's cursor, not over a mouse selection, so it can't replace a word in the middle of a line. The Windows Exceptions window became a real list like the macOS sheet (it was a text area of executable names): program icon and description (from the running copy or PATH, else a generic icon and the file name), "Exclude current app" (the last foreground program, tracked with a WinEvent hook), "Choose…" (the Open dialog), "Remove"/Delete, "Done"/Esc; every change saves at once. The inner title duplicating the caption became a one-line hint (`settings.exc.hint`, shown under the title on macOS too); the text-area keys were dropped from all 12 languages.
- Testing in UTM (QEMU, Windows on ARM): an endless "aaaa" after a Ctrl+Alt+R and once after typing with auto-correct off. Suspects: the 0xE8 mask key (now sent only for a lone Alt or Win — with Ctrl held, Alt's release opens no menu), or QEMU dropping a key-up. An opt-in log (`WinDebug.swift`, registry `DebugLog`=1) records every hook event with its injected flag and every SendInput batch to `%TEMP%\relayout-debug.log` to tell which.
- Windows Settings re-laid out after the macOS window: logo + bold name, launch at login, right-aligned gray captions for Language/Hotkey, a hotkey field that records on click (a bare-modifier tap waits 350 ms for a second tap: the double tap that macOS records as a tap sequence, so the separate checkbox is gone) with an ↺ restore button, auto-correct with an ⓘ tooltip when unavailable and Exceptions… on the same row, "Also fix on Enter" indented, and a centered gray footer. The Set/Reset/Close/Keyboard-settings buttons and the tagline went away; Esc closes. Six `win.*` keys became unused and were dropped from all 12 tables. Switching the language crashed on real Windows: the controls (the combo box among them) were rebuilt inside the combo's own CBN_SELCHANGE, so it returned into freed memory; the rebuild is now posted (`WM_REBUILD`) and runs after it. The ⓘ tooltip did not show on real Windows; it is now a rectangle tool on the window (the static lets the mouse through) instead of a tool on the static. A layout added while Settings was open went unnoticed (macOS reacts to the enabled-input-sources notification; Windows sends a background app none): the window now re-reads the layout list every 2 s and on activation, and rebuilds on a change.
- First run on real Windows (arm64): every string after the first `//` comment showed as its key. GitHub's Windows runners check files out with CRLF, and in Swift "\r\n" is ONE Character, never equal to "\n": the `.strings` comment skip ran to the end of the file, and `TrigramModel(text:)`'s `split(separator: "\n")` left each model one line — auto mode would never have fired. Both now split on `isNewline`; `.gitattributes` pins LF for `*.strings` and the models; two CRLF tests. The hotkey field got a themed sunken edge instead of a flat border, and Settings now says why auto-correct is unavailable (`settings.autoCorrectUnavailable` with the installed layouts) in place of its dead sub-options — macOS shows the same text in an ⓘ tooltip, which Windows can't do on a disabled control.
- Windows UI is localized from the macOS `Localizable.strings` (CI ships them as `lang/<code>.lproj` next to the exe; `parseStrings` in `Core/Strings.swift` reads them; a test checks every language carries every English key). 13 Windows-only keys (`win.*`) were added to all 12 tables. Settings got a language picker (system default + shipped languages by their own name) that rebuilds the window live. Also: Settings rebuilds itself on `WM_DPICHANGED`, Tab/arrows work in Settings and Exceptions (`IsDialogMessageW` in the loop), the tray icon loads at the small-icon size for the DPI, and the Settings class flag is set only when `RegisterClassW` succeeds.
- The hotkey's layout choice moved into the engine as `planRetype` (mixed word -> `fixMixedWord`; no current-script text -> convert back into the active layout; else `pickTarget`: the other of two, the first of many unless current is first, then the script of the rest of the text or the second). macOS lost its copies of `pickTarget`/`restTextLayout`/`mixedWordFix`; Windows swapped its simpler "other script, else the other one" rule for it. 6 new tests.
- Press-again undo is back on Windows (it was removed with the old MVP): a second hotkey within 1.5 s reselects what the last conversion typed and types the original back, for hotkey, auto and Enter fixes alike; off in double-tap mode. Any real key, a click or keys replayed after a fix end the window. A click now ends it on macOS too: undo reselects from the caret, and after a click that is no longer right after the typed text.
- `mixedWordFix` moved into the engine as `fixMixedWord` (both readings of a mid-word layout switch, trigram-scored; 3 tests) and now also serves the Windows hotkey for a single-word selection like "ghjсто".
- The typed-word run moved into the engine too (`AutoRun` in `Core/Auto.swift`): word material, the word/trail/new-run state machine, Backspace, the short-word rule with the erase/undo text of a swallowed preposition, and the Enter settle loop (`awaitSettledField`). macOS and Windows both drive it; 16 new tests. Drift it removed on Windows: digits now end the run, a mapped char or connector counts only before any trail, Backspace forgets the previous word once the word is empty, erase counts characters not UTF-16 units. Also fixed on Windows: AltGr (Ctrl+Alt) types instead of ending the run, Backspace during a fix un-types a held key, a replayed Return skips the Enter follow-up, and Shift survives on a re-sent boundary.
- Auto mode on Windows (`windows/WinAuto.swift`, opt-in): the keyboard hook feeds typed characters into a word buffer; space/Tab evaluates it through the shared `decideAutoTarget`; the fix is backspaced in, retyped, the boundary key re-sent and the layout switched. The buffer resets on Return, a click (a second WH_MOUSE_LL hook), a foreground change, any Ctrl/Alt/Win shortcut and after each fix; keys typed during a fix are swallowed and replayed. Trigram models ship next to the exe as `trigram/<lang>.txt`. Short words follow the macOS rule: a 1-2 letter word is only fixed next to a real conversion of the same script, either folded into the following long word's correction or right after a committed one. The Enter follow-up is ported too (sub-option "Also fix on Enter", on by default): Return is never swallowed; the field is snapshotted through a new UIA call (length, caret, selection, 64 units before the caret), the UI thread polls until three reads agree, and only the engine's `.newline` outcome deletes the break and the word and retypes the fix with a real Return. Auto mode also honours a deny-list of executables (defaults: terminals and editors; edited in a new Exceptions window, `windows/WinExceptions.swift`) and stays out of password fields, which UIA reports once per focused control, not per keystroke.
- The decision itself moved into the engine as `decideAutoTarget` (`Core/Auto.swift`, `57e57d4`) with five tests — macOS behavior unchanged, Windows reuses it.
- Batch 6 — the hotkey acts only on what the user pointed at. Selection is read through UI Automation (`windows/uia/relayout_uia.cpp`, one C++ target because Swift has no COM), the clipboard only when a control exposes no UIA text. The Shift+Home line grab and every guess at the word before the caret are gone: unselected text belongs to the (opt-in) auto mode and its typed-word buffer.
- Batches 1–3 built green on x64 and arm64 (runs 35251878493, 35253746849, 35254652193); not tested by hand yet.
- Open: `WM_DPICHANGED`, keyboard navigation in Settings, tray icon DPI, Authenticode signing; UI Automation read, caret-word narrowing, auto-correct, localization.

## v1.2.27 — Settings row order

Settings now read language → hotkey → auto-correct + "Also fix on Enter", as the user laid out from a screenshot of v1.2.26 (`ee73f91`).

## v1.2.26 — Enter fixes the word when it made a new line

Feature `5c411f7`. The user asked whether an app's handling of Enter (line break vs submit) can be told apart, after v1.2.24 stopped correcting on Enter.

- Not before the key: `AXTextField` never breaks lines, but chat inputs are `AXTextArea` too. After the key it can: a probe (`axprobe`, scratch) polling the focused element showed, for TextEdit, Notes and Telegram, count +1 / caret +1 / `"\n"` before the caret on a line break and an emptied field on a Telegram send. Vivaldi and VS Code answer `AXFocusedUIElement` with -25212 (Chromium/Electron expose no tree unless `AXManualAccessibility` is set — not done). The system capitalizes the word ~50 ms after the break appears (`test\n` -> `Test\n`), so the read must settle and the word compare is case-insensitive.
- Probe mishaps, both mine: stdout buffering lost the user's first run; `NSWorkspace.frontmostApplication` does not update without a run loop, which lost the second.
- Engine `enterOutcome(before:after:word:)` + `FieldSnapshot`, 15 table tests; any mismatch is `.unknown` = leave the text. macOS: `autoEnterFollowUp` reads the field before Return, `finishEnter` polls under the gate (25 ms, 3 equal reads, 0.5 s cap), then deletes break + word and retypes fix + real Return. Held Returns are not followed up (their "before" read would race the replayed key). Settings sub-option "Also fix on Enter" (`autoEnterNewline`, default on). Verified live by the user: TextEdit, Telegram (Shift+Enter fixed, two sends untouched), a Notes list item, Raycast unchanged.

## v1.2.25 — trailing layout-mapped char converts; auto-correct off for one-script layouts

Fix `39c23f0`, settings `41b5fd1`, tests `1d43a8d`. User reports: `rfhf,f[` (карабах), `vj]` (мої), `vj'` (моє), `vj«` (моё), `gj[j;` (похож) never converted.

- Cause: `autoWordCore` refused any word whose last char is not a letter — the "`pyf.` is `знаю` or `зна.`" ambiguity rule. Scores were never the blocker (`карабах` -2.64 ru against the -3.0 punct gate). Comparing the two readings does not work either: `зна` outscores `знаю`, `мо` outscores `мої`.
- The user's argument settled it: a wrong-layout typist errs on punctuation too ("привет," arrives as `ghbdtn?`), so a trailing mapped char is the key pressed. A first attempt allowing only Unicode Ps/Pi (`[`, `«`) was dropped for that reason.
- English guard: the core check strips trailing punctuation too. Probed via a temporary `--selftest` block on the live ABC + Ukrainian-PC pair: 80 English negatives ending in mapped punctuation, 5 false fires, all a 2-letter core plus `.` (`vs.` -> `мію`, `cf.`, `Ph.`, `Vs.`, `Lt.`). `autoEvaluate` now judges length without the trailing mapped run, so those (and `vj]`) take the short-word path: converted only with a neighbouring correction. The user accepted that standalone `vj] ` stays as typed.
- Known: `yj;` (нож) scores -3.5 and stays below the -3.0 punct gate.
- **Settings:** with every enabled layout in one script (ABC + German) auto-correct can never fire — the v1.2.11 calibration found Latin↔Latin not viable, so `autoDecide` only takes other-script targets. The checkbox is now shown off and disabled (stored preference kept) with an ⓘ tooltip naming the enabled layouts. Iterated with the user: a click popover and a hover popover were tried and dropped for the system tooltip with `NSInitialToolTipDelay` = 0 (app-wide).
- **`LayoutPairTests`**: engine over real `UCKeyTranslate` dumps (QWERTZ, AZERTY, Dvorak, Czech/Kazakh digit-row letters, Polish, Turkish ı, Mac vs PC Russian comma, Russian→Ukrainian, Belarusian ў, Serbian, Latin→Georgian/Greek/Hebrew/ Arabic). Probed but not fixed: Georgian/Greek/Hebrew/Arabic → Latin returns nil (`convertWrong` knows only Cyrillic vs not), `dominantScript` is nil for Greek text, Belarusian `'` is not auto-mode word material, Greek tonos is a dead key.

## v1.2.24 — auto-correct: punctuation trail, Return submits, stale run on click/shortcut

Shipped as `v1.2.24` from `main` (`54cd393`): the fix is `8a6e25d` (README and ARCHITECTURE synced in it), notes `docs/release-notes/v1.2.24.md`; CI `build` and `core` green, notes verified in the release body and the appcast. Started from the user report "`ltkfq?` does not become `делай,`"; the follow-ups were diagnosed with a `RELAYOUT_DEBUG` trace before any fix.

- **Trailing punctuation.** `?` is not word material on ЙЦУКЕН (it maps to `,`), so `autoFeed` cleared the buffer and the word was never judged. A first fix used a hard-coded `?!,.;:)` set and fired on the punctuation key; rejected by the user as a character table that breaks the layout-driven design. Now any punctuation/symbol after a word collects in `autoTrail`, the word is judged only at whitespace, and the trail is transliterated with it. `@`/`/` inside an address or path are never followed by whitespace, so they break nothing.
- **Return in Raycast** (trace: `sym` + Enter -> `інь`, wrong app launched). Two causes: the swallowed Return was retyped as a Unicode `"\r"` on key 0, which apps ignore, and the correction ran before the submit. Returning the real key alone still launched a search on the converted text. By the user's choice Return never corrects now; it only ends the run. Tab and replayed Return go out as real keys with Shift/Option (`typeKey`).
- **Held-key replay** typed all held text before feeding it, so a boundary inside the replay made the correction delete from the end of the screen, past its word. Each key is now fed before it is typed; keys after a firing boundary go back on hold. `boundaryTyped` removed.
- **"An earlier word appears at the start"**: the tap saw only keyDown, so the buffer and a pending preposition survived clicks, Cmd/Ctrl shortcuts and a chat Enter, and the next correction deleted text before the moved caret. Mouse-downs and Cmd/Ctrl combos now end the run.
- Open: `gateSince` is not refreshed across a chain of corrections (after 3 s the gate passes keys through); a click during a correction still replays held keys at the new caret; launchers still convert on space (no default exclusion).

## v1.2.23 — retype races closed, line grab converts one word, hyphen/apostrophe words

Shipped as `v1.2.23` from `main` (`6b2db27`): the fix is `9c9e92d`, README sync `46ce4d0`, notes `docs/release-notes/v1.2.23.md`. Reported by the user as "half a word converts, a space becomes the last character typed"; four independent causes, each reproduced or measured before the fix.

- **Hyphenated words never fired in auto-correct** (user report: `rfrjuj-nj` stayed as typed). Three separate gates rejected them: `autoFeed` treated `-` as punctuation and cleared the word buffer mid-word, `autoWordCore` demanded every non-letter map to a Cyrillic letter (`-` maps to `-`), and the trigram score was floor-dominated — the models come from a plain word list, so all three trigrams spanning a hyphen are unseen (floor -16.4 each). Now: `isWordConnector` (`-`, `–`, `—`, and NOT the apostrophe — that is э on ЙЦУКЕН) keeps the run alive when the buffer is non-empty, `autoWordCore` skips connectors, `autoDecide` treats such a word as pure-letter, and `TrigramModel.score` scores hyphen parts separately, length-weighted. Measured on the shipped models: `rfrjuj-nj` -> `какого-то` margin 8.3, `rjt-xnj` -> `кое-что` 10.5, while `e-mail` stays at 0.32 (below the 0.5 gate) and is left alone.
- **Same for the Ukrainian apostrophe** (`v\zrj` -> `мʼяко`), with one twist: it has no key of its own on a Latin layout, so the typed character is `\` and only the layout maps it to `ʼ` (U+02BC) — verified against the live Ukrainian-PC layout via `--selftest`. `mapsToConnector` reads that mapping, so `\` counts as word material in `feedsAsCyr`/`autoWordCore`, and `autoDecide` gates such a word as pure-letter (`pureFor`) instead of applying the mapped-punctuation floor — with the parts-scoring, `мʼяко` lands at -2.80 and would have failed the -3.0 gate. U+02BC/U+2019 are connectors; the ASCII `'` is not (it is э on ЙЦУКЕН).
- **Backspace desynced the word buffer from the screen** — the pattern the user isolated: type `g\'`, delete the `'`, type `æcf`, and only `æcf` converted. A keystroke that produces no letter ended the run (`autoBuffer = ""`), so a typo fixed mid-word split it in two; and had the buffer been kept instead, the retype would have deleted one character too many, splicing the fix into the text. Both failure modes are the same missing edit: `autoBackspace` now drops the last buffered character, and Option/Cmd+Delete (a word / the whole line) ends the run. Handled before the Cmd/Ctrl filter — Cmd+Delete used to slip past it untracked — and while the gate holds keystrokes, backspace un-types the last held character instead of reaching the app out of order.

- **The line-grab heuristic is gone** (user request). With nothing selected the hotkey grabbed the whole caret line and `lastWrongWindow` guessed which tail was "wrong" — anchor on the last letter, walk back over neutrals, stop at another script, trim a mid-word remainder. It guessed wrong on some lines and retyped text the user was not thinking about. Replaced by `caretWord(_:)`: the trailing run of non-whitespace, so mid-word punctuation (`кое-что`, `e-mail`, `d'jhl`) stays in the word. `convert` now also returns `replaced` (the run it actually converted) and `performRetype` narrows the grabbed selection to it — Right to collapse, then Shift+Left per character — so the head of the line is never retyped at all. Exception: the Cmd+X fallback has already cut the line, so there the head is typed back together with the conversion. Undo records whichever run was written.
- **The `a457c84` keystroke gate closed only one of four holes.**
- **Mixed injection points.** `postKey` posted at `.cghidEventTap` while `typeUnicode` posts at `.cgSessionEventTap` — two entry points into the same chain, the HID one upstream of the session one, so a delete posted first could be delivered after a character posted later. `autoCorrect` (deletes, then text) and `performUndo` (Shift+Left, then text) both depend on that order, with only a 10–20 ms sleep between them. `postKey` now posts at `.cgSessionEventTap`: one queue, FIFO. This is the likeliest cause of the half-converted words.
- **The boundary keystroke raced its own correction.** The space that triggers `autoEvaluate` was returned from the tap unmodified and travelled to the app while `beginCorrection` was already posting deletes for it. The tap now swallows a boundary key that starts a correction (`autoFeed` returns "consumed"), and `autoCorrect` deletes the boundary only on the replay path, where it really is on screen (`boundaryTyped`). Explains the "space became the last typed character".
- **The hotkey retype had no gate at all.** `autoPending`/`autoHeld` existed only in the auto-correct tap, and that tap was installed only in auto mode, so `performRetype` — a much longer sequence (AX read, Cmd+C/Cmd+X with 120 ms sleeps, per-character typing) — ran with the user's keystrokes flowing straight into the field being rewritten. The keyDown tap is now installed whenever the app is live (auto mode only decides whether keys also feed the word buffer), and `triggerHotkey` dispatches `performRetype` through `beginCorrection`.
- **Gate timeout.** With the hotkey path behind the gate, a retype that hangs on an unresponsive app would swallow keys indefinitely; the gate now passes keys through after `gateMaxHold` (3 s).

---

## v1.2.21 / v1.2.22 — release notes in the update window, typing race in auto-correct

- **The Sparkle "a new version is available" panel was blank.** `generate_appcast` was run on the archive alone, so the appcast item carried no `<description>` and the hand-written notes lived only on the GitHub release page, which the updater never shows. Fixed in `3e35f74`: `docs/release-notes/vX.Y.Z.md`, committed before the tag, is now the single source. The tag build prepends it to the release body (`gh release create --notes-file` alongside `--generate-notes`, so the auto `Full Changelog` link survives) and renders it through the GitHub `/markdown` API into `reLayout.html` next to `reLayout.zip` — `generate_appcast` embeds a `DOCTYPE`/`body`-less HTML sibling of the archive as the item description, so no markdown converter and no hosting for the notes are needed. Sparkle 2.6.4's `generate_appcast` reads only `.html`/`.txt` siblings (`.md` support is later than the pinned version), hence the render step. `/release` grew a step for the file; `RELEASING.md` documents the flow.
- **Fast typing raced the retype** (user report): keys pressed while a finished word was being corrected landed between the synthetic deletes and the retype, so the fix was spliced into the new text and the wrong characters got converted. The auto-mode tap was `.listenOnly` and `autoCorrect` runs async on `worker`, so nothing held the keystrokes back. Fixed in `a457c84`: the auto tap is now a `.defaultTap`; while a correction is in flight (`autoPending`, bumped in `beginCorrection` on the tap's thread before the dispatch) the callback swallows text-producing keys into `autoHeld` and returns nil, and `finishCorrection` types them back and re-feeds them through the word buffer once the queue drains. A replay that itself hits a word boundary just starts another gated correction. Only character keys are held — modifiers, Globe, arrows and delete always pass through, so a stuck correction can never freeze the keyboard.
- **Shipped as two tags on purpose** (to verify the appcast change against a real updater before the behavior change rode along): `v1.2.21` from branch `release/v1.2.21` (`5e9cb43`, notes machinery only, no engine/app change) and `v1.2.22` from `main` (`86171be`). Both CI `build` runs green; the notes were confirmed in the release body, in `appcast.xml` on `gh-pages` (`f3691e9`), and in the live Sparkle panel updating 1.2.20 → 1.2.21.
- **Note for future notes:** GitHub renders in GFM mode, so hard line breaks inside a bullet become `<br>` in the update window. Write each bullet as one long line.

---

## v1.2.20 — mid-word layout switch (auto-correct + hotkey)

- **`"ghj" + [layout switch] + "сто"` stayed `"ghjсто"`** (user report). Switching the layout in the middle of a word leaves ONE word carrying both scripts, and every auto-correct path assumed a single-script word: `convertWrong` (called from `autoDecide`) converts whole tokens through the active layout, so the Latin run `ghj` — typed on a layout that is no longer current — passed through unmapped, the score stayed junk, and nothing fired.
- **The Globe key itself broke the run.** Before any of the scoring mattered: `autoFeed` treated a keystroke that produces no character as "punctuation / navigation" and cleared the word buffer, and the Globe/fn layout switch is exactly such a key. So "ghj" was dropped at the switch and only "сто" — a plain Russian word — reached `autoEvaluate`. Empty input now returns without touching the run (⌘Space switching was already safe: Cmd-flagged events never reach the feed).
- **Fix — sub-word conversion.** New engine `convertScriptRuns(_:src:dst:)` converts every maximal run of `src`-script letters and leaves the rest verbatim. `autoDecide` gets a mixed-word branch that tries both readings of such a word: fix the pre-switch run into the current script (`"ghjсто"` → `"просто"`, target stays the current layout — no input-source switch) or fix the current-layout run into the cross-script candidate; each is scored under the model of the script it ends up in and must clear the usual margin. Mixed words carrying punctuation are left alone — the existing shape gates (`autoWordCore`) reason about a single-script word.
- **Hotkey path too.** `lastWrongWindow` anchors on the line's last letter and trims a mid-word remainder, so a mixed token windowed to nothing — the hotkey did nothing at all on "ghjсто". Two changes: engine `convertWrong` now routes a mixed-script token through `convertScriptRuns` (converting it whole dragged the already-correct half through an unrelated layout), and `convert()` intercepts the caret word (line grab) or a single-word selection with `mixedWordFix`. Which half is wrong is *not* decidable from the layouts: "ghjсто" wants its head fixed ("просто"), "мирqwerty" its tail ("мирйцукен"), and the two are structurally identical — head in the non-current script, tail in the current one. So both readings are scored with the trigram models and the better one wins (measured on the shipped models: просто −1.3 vs ghjcto −9.5; мирйцукен −5.8 vs vbhqwerty −10.6). No confidence gates there — unlike auto-mode the hotkey is an explicit user request. Windows keeps the `convertWrong` half of the fix; it has no trigram path of its own.
- Landed as `3534db4` (engine + macOS + tests), docs `c599b9d` / `31e38e9`. Released **v1.2.20**: ff-merge to `main`, tag pushed, hand-written notes + auto Full Changelog applied; tag `build` and `core` CI green, dmg/zip published, appcast + cask bumped. Confirmed live by the user on the dev build ("просто").

---

## v1.2.19 — auto-correct: short prepositions via adjacency

- **`"d ljhjut" → "d дороге"` fixed** (user report: "пропускает первый символ слова… как правило, предлоги"). Nothing was truncated — `дороге` was complete; the preposition `d`→в was simply left in the wrong layout. Three gates blocked 1-2 char words: `autoDecide` and `autoEvaluate` both required `count >= 3`, and engine `autoWordCore` separately requires `letters >= 2`. So every short preposition (в к с у на по за из от до …) never converted.
- **Fix — adjacency, not a blanket gate drop.** Measured trigram scores first (throwaway harness loading `Resources/trigram/{en,ru}.txt`): every wrong-layout preposition clears the garbage/margin gates by ~2.7+ (model pads `^^w$`, so short words score), while real English function words (`in on to is of`) score too high to fire — but a few short junk tokens (`vs`→мы) would false-fire if the gate simply dropped. So: `autoDecide` loses its `>= 3` guard and bypasses `autoWordCore` for pure-letter words (no punctuation ambiguity there); precision for short words moves to a new adjacency rule in `autoEvaluate`. A short candidate never fires alone — it's remembered (`autoPrev` run-state) and only converted when it borders a real same-script conversion. A following long word **swallows** a pending preposition into one delete/retype edit (folded into the undo record via `autoCorrect`'s new `swallow:` arg); a lone short junk token with no anchor is left untouched. One-neighbour lookback (a stacked pair fixes only the last preposition) — noted in-code with the widen-to-a-list path.
- Engine untouched (`Core/` unchanged); all logic in `macos/main.swift`. Tests 46/46 + engine 19/19 green. Commits `43e4b53` (fix), `13a8c60` (ARCHITECTURE note). Shipped as tag `v1.2.19`.

## v1.2.18 — auto-correct: layout-mapped punctuation joins the word

- **`",ßkj" → ",ыло"` fixed** (user report). Auto-mode's key monitor treated every non-letter as a word-boundary reset, but on ЙЦУКЕН `,`=б `'`=э `;`=ж `[`=х — so "было" typed on US arrived as `,skj`, only `skj` was evaluated, and the fix left the comma behind. The same half-mangle hit every б/э/ж/х-initial word ("это", "жизнь", "хорошо"). Now `autoFeed` buffers a punctuation char when an enabled Cyrillic layout reads its key as a letter (decided by the live maps, no char table), and a new engine-level `autoWordCore` vets the shape before conversion. Guards, all placed on measured model scores (not vibes): trailing mapped chars never convert (`pyf.` is both "знаю" and "зна." — the trigram score gaps overlap in both directions on common words, so the ambiguous case keeps the old no-fire behavior); ≥2 real letters (per-language floor deltas otherwise fire on `"..."` → `"ююю"`); plausible-core suppression (`'hello` keeps its quote); and an absolute converted-side gate `autoPunctPlausible -3.0` for punctuation-bearing words (real fixes score ≥ −2.6, junk that beat the relative margin like `e.g` → `уюп` scored ≤ −3.8). Letters-only words run the exact pre-change pipeline. Engine tests + macos tests + `ARCHITECTURE.md` updated (`db176d2`).
- Tagged **v1.2.18** via `/release` (ff-merge of `claude/autoreplace-bkj-ylo-ced3e8` into main at `b6696bf`): hand-written notes + auto Full Changelog; tag `build` and `core` CI green, dmg+zip published, Sparkle appcast deployed. Live-plumbing smoke (type `,skj ` with auto-correct on) still manual-only.

## v1.2.17 — copy (not cut) explicit selections: smart cut ate a space

- **Leading-space swallow fixed.** User report: in some apps, converting a selected word glued it to the previous one (`просто ckjdj` → select `ckjdj` → `простослово`). Only the clipboard-fallback path could do this: it read the selection via `Cmd+X`, and smart cut-and-paste (Word's default, `smartInsertDelete` text views) deletes an adjacent space together with a cut word — outside the selection, so the app eats it invisibly and the retyped conversion lands flush. The AX path was immune (type-over replaces exactly the selection), hence "sometimes". Fix: an explicit selection is now read via `Cmd+C` — copy keeps the selection and typing replaces exactly it, so smart cut never fires; `Cmd+X` stays only for the no-selection line-grab, whose selection starts at the line start (nothing before it to eat). The sequence is C-then-X at most — still no `Cmd+C+C` pair for DeepL's watcher, preserving the reason `60042a8` chose cut. Synced `ARCHITECTURE.md` + `README.md` in the same commit (`d7779a3`); the dou-ua article's fallback paragraph rewritten in the `articles` repo (`5c69f72`).
- Tagged **v1.2.17** with hand-written release notes + auto Full Changelog; tag `build` and `core` CI both green. Manual smoke in a smart-cut app (Word) still pending — the keystroke plumbing has no unit coverage.

## v1.2.16 — no-selection line-grab + recorder-scoped hotkey gate

- **Implicit line-grab narrowing.** Pressing the hotkey with nothing selected grabs the caret line, which mixes already-correct text with the wrong-layout tail. New `lastWrongWindow(_:)` (`Core/Engine.swift`) anchors the wrong script on the line's last letter, walks back over same-script + neutral chars, stops at the first letter of another script, and trims a mid-word remainder. `convert(_:lineGrab:)` converts only that window and types the correct prefix back verbatim — fixing `привіт ghbdsn` (active uk) from mangling into `ghbdsn ghbdsn` to `привіт привіт`. Target selection factored into `pickTarget()`. Pure string function → hermetic tests, shared with the Windows port (`a405580`).
- **Hotkey focus-gate rescoped to the recorder field.** The hotkey was muted whenever the Settings (or Exceptions) window was key, so merely opening Settings disabled it. Replaced the window-level gate (`settingsIsKey`/`gateOnWindow`/`refreshConfigGate`/`setConfigKey`) with a flag tied to the shortcut recorder's capture state (`recordingHotkey`, set by `ShortcutField.onRecordingChanged`). `finalizeSequence` re-applies the hotkey mid-recording while the field is still focused, so the gate holds that re-apply off until the recorder stops. The hotkey is now live everywhere except while it's actually being recorded (`a405580`).
- **Engine tests switched to Ukrainian fixtures.** `EngineTests.swift` + `macos/tests.swift`: fixture key S maps to `і` (so `ghbdsn` ⇄ `привіт`), sample words Ukrainianized, the Option layer maps `ß/æ → є/ї` (the real `ß/æ ↔ ы/э` overlap stays documented in the README). Added 9 `lastWrongWindow` cases. Gate green: 17 SwiftPM + 33 macOS (`3dfcfbf`).
- **README Privacy & Security + Credits.** Spelled out the data-handling guarantees behind the Accessibility grant (no network except the Sparkle update check, nothing written to disk in release, no telemetry, clipboard untouched, password fields skipped) and attributed the Hermit Dave *FrequencyWords* corpus (MIT) the trigram models derive from (`57d8597`, `ec74cdb`).
- **`/release` slash command + docs-sync discipline.** Added `.claude/commands/release.md` to run the release flow (preflight → doc-sync → hand-written notes → tag/push → apply notes while preserving the auto `Full Changelog` link → CI report), codifying that every tag ships written notes and current docs (`974ecbf`). Synced `ARCHITECTURE.md` + `README.md` to the line-grab and focus-gate changes (`6ad284d`).
- Released **v1.2.16** (notarized, Sparkle, Homebrew) with hand-written release notes. The companion dou.ua article (separate `articles` repo) was updated in step: Ukrainian-first calibration chart/table, corrected focus-gate passage, new line-grab paragraph.

## Website + identity rename (post-v1.2.13)

- Added a presentation landing page on the `gh-pages` branch (`index.html` + `logo.png`, alongside the Sparkle `appcast.xml`), served at [relayout.forfutdinov.com](https://relayout.forfutdinov.com/) by a DigitalOcean static site that deploys from `gh-pages`. Self-contained single file (dark theme, animated wrong→right demo over a Mac keyboard, bento features, a "How it compares" table, Homebrew + DMG install). Iterated through the `design-taste-frontend` skill for an anti-slop pass.
- Renamed the bundle id `com.vlad.relayout` → **`com.vladforfutdinov.relayout`** (dev: `.dev`) across `build.sh`, `Info.plist`, the Homebrew cask zap path, and docs. Note: this resets the Accessibility grant + saved UserDefaults on first launch of the renamed build (macOS treats it as a new app).
- Aligned the author name to **Volodymyr Forfutdinov** (appcast commit identity, Windows installer publisher) to match the app copyright and the site. Added the MIT `LICENSE`.

## v1.2.13 — per-app auto-correct exceptions

- Auto-correct's hardcoded terminal/IDE exclusion set became a user-editable deny-list (`autoExcludedApps` in `UserDefaults`, seeded with the old defaults) (`e88999d`).
- "Exceptions…" button (next to the Auto-correct checkbox) opens an editor presented as a **sheet** on Settings — modal to it (`fed34de`). Add apps via "Exclude current app" (the last non-self frontmost app, tracked via `didActivateApplication`; stored as a bundle-id string after a weak-ref bug nilled it) or "Choose…" (`NSOpenPanel`). Remove via a per-row button that appears on hover (`ExcRowView` + `NSTrackingArea`, `68e6faa`).
- The hotkey/auto focus-gate now covers both config windows (Settings + Exceptions), recomputed from the actual key window (`37fe683`, `fed34de`).
- `settings.exc.*` localization across all 12 languages. Tagged **v1.2.13**.

## v1.2.12 — Settings rework (single window, three sections)

- Merged the standalone About panel into the Settings window: one auto-sizing window (logo / name / sections / footer); removed `showAbout`, `aboutResignObserver`, `menuGlyphImage` (`112ba26`, later cleanup `7168935`).
- Fixed the window opening invisible (content view had no width constraint → `fittingSize` collapsed) — pin the stack on both sides + auto-fit width (`879f303`, `e384b3a`).
- Regrouped into three separator-divided sections: login + auto-update + language / auto-correct + hotkey / version + link + copyright (`52c27e3`). Checkbox rows and grid captions left-aligned, logo/name/footer kept centered, Hotkey caption vertically centered with the field (`82b467f`, `0eccd12`). Hotkey field width == language popup (`034bbed`).
- `Cmd+W` (close) and `Cmd+Q` (quit) handled in `SettingsWindow` by physical keyCode so they work on any layout (no main menu in an agent app) (`8e693b1`, `0d85bf3`, `554ff9b`). First checkbox no longer grabs focus on open (`c979861`).
- Tagged **v1.2.12**.

## v1.2.11 — auto-correct mode + tap-sequence hotkey

- **Auto-correct (trigram detector).** Phase 0: char-trigram language model (`Core/Trigram.swift`) + offline calibration (`scripts/trigram/gen.py`, `calibrate.py`) sweeping θ_garbage/θ_margin for ≥99% precision; confirmed Latin↔Latin (de/fr/es) not viable, so the mode is **cross-script only** (ru/uk ↔ en) (`363808d`, `cf5f12c`). Phase 1: decision logic + bundled models in `Resources/trigram/`, then a live `keyDown` monitor that auto-fixes the last word; default **off** (`098f040`, `4542cc9`). Engine gained `dominantScript` / `textHasScript` (`Core/Engine.swift`).
- **Hotkey is now a recorded tap-sequence** — dropped the "Trigger on double-tap" checkbox; the recorder accumulates N taps within a window (`b08782a`). Reset works mid-recording; Esc closes Settings instead of cancelling (`71be83a`, `aaacfe4`). Press-again-undo simplified — the standalone double-tap-to-undo hint removed (`b234723`, `cf6e002`).
- **Focus-gate fix:** live hotkey + auto-correct suspended while the Settings window is key — committing a tap-sequence no longer re-arms the hotkey under the still- focused recorder (which fired a retype and fed the synthetic Cmd+X back into the field) (`5d97a22`, `5355bc3`).
- Removed the "Keyboard settings" menu item (`d8040b7`). CI appcast commits now authored by the repo owner — no stray bot/user contributor (`343c1d2`, `f11d85d`).
- **Refactor, no behavior change:** extracted `installEventTap`/`removeEventTap`, `makeCheckbox`/`makeSecondaryLabel`, `markSynth`, and Core `wordTokens`; removed 9 unused localization keys (`6d0f5b6`, `7168935`).
- Tagged **v1.2.11**. (Windows excluded from tag releases — macOS-only.)

## Repo reorg + handoff docs

- Added cross-session context machinery: `CLAUDE.md` (lean onboarding) + `docs/SNAPSHOT.md` (operational state, overwrite) + `docs/HISTORY.md` (this file, append-only). Deep reference split into `docs/ARCHITECTURE.md`.
- Reorganized the tree: scripts → `scripts/`, macOS sources (`main.swift`, `tests.swift`, `Info.plist`) → `macos/` (mirrors `windows/`), docs → `docs/`, source art (`rL-logo.svg`) → `assets/`. Build output (`.app`/`.dmg`/`.zip`) now lands under `dist/` (gitignored) instead of the repo root. `Core/`, `Tests/`, `Resources/`, `windows/`, `packaging/` unchanged.
- Updated all path references: `scripts/*.sh` internals (`cd` to repo root, source paths), `build.yml` CI invocations, README / RELEASING / ARCHITECTURE / CLAUDE. Build + tests re-verified green post-move.

## Windows port — Phase 2b MVP (current arc)

- Extracted the platform-free conversion engine into `Core/Engine.swift`; macOS app
  + Windows port + tests all consume it (`215bc45`, `f4f7ba7`).
- SwiftPM `Package.swift` exposes `ReLayoutCore`; cross-platform engine tests run on macOS and Windows CI (`core.yml`).
- `WinLayout` builds `LayoutMaps` via `ToUnicodeEx`; lists/switches HKLs (`ee4a7d7`, `cb140aa`).
- Windows MVP: hotkey (Ctrl+Alt+R), clipboard read, `SendInput` write, layout switch (`d338c68`), system tray with right-click Quit (`f96905c`, `8925c37`).
- CI: bumped Windows Swift toolchain to 6.1 (ucrt module-cycle fix, `d98432b`).
- **Open:** UI Automation selection read (clipboard-only now), Settings UI, Windows release packaging + signing in CI, storage adapter (Registry/AppData).

## v1.2.6 — mod-tap correctness

- Mod-tap ignores cycles where an out-of-set modifier appeared, so Option+Control no longer spuriously fires a retype (was triggering DeepL) (`eecff27`).

## Distribution pipeline (v1.2.x)

- Developer ID signing + notarization (App Store Connect API key) + staple in CI (`4160320`, `4941d87`).
- Sparkle auto-update for release builds; real `SUPublicEDKey`; Settings checkbox + "Check for Updates" menu item (`cb61f8f`, `7375244`, `c0cea4b`).
- Homebrew cask + CI tap auto-bump via SSH deploy key (`db046be`, `54630f1`).
- Dev vs release split: distinct bundle id + suffixed `.app` name so macOS keeps separate TCC grants / prefs (`a506346`, `17f7f04`); About shows full git version (`ffab7e6`).
- Build fixes: brace-delimit `$SPARKLE_VERSION` (C-locale unbound var, `e94f962`), retry `hdiutil` on transient busy (`f72fb05`), drop Node-20 JS actions (`902a5e6`).

## Icons

- App icon (keycap) → rL wordmark; opaque tile so it's visible in Sparkle/Finder (`5504905`, `776d1ed`, `766ee12`).
- Menu-bar icon: live layout-state mode or static template icon, appearance-aware (`3fa3e3e`, `f459ced`, `4276476`).

## Localization + UI (RuSwitcher gap-closing)

- 12-language localization; language list derived from shipped `.lproj` bundles (`deeee10`, `40c2e09`).
- Language picker in Settings, undo hint, spacing/focus polish (`527b2d3`, `f6610b3`, `9a82453`, `2d655db`).
- Double-tap undo to reverse the last conversion (`5ddbbd6`).

## Apple HIG + quality pass

- HIG + accessibility polish for menu and Settings; standard About panel (`5aaf867`, `a49b0e8`).
- Unit-test harness for the conversion engine + hotkey helpers (`c6fd5b6`).
- Fixes: stop clipboard wipe on AX path, guard AX downcasts (`8fe11da`); never write selected text to `/tmp` in release builds (`436c6b1`); cache enabled-layout list (`6de830c`).

## Initial build (v1.0.0)

- macOS menu-bar layout-retype tool: hotkey → read selection → convert via active OS layouts → type back → switch input source (`b3cf89b`).
- Caramba-style write + AX-strict read (`80d3b80`); HIG settings + inline shortcut recorder, default = tap left Option (`65498ee`).
- Versioning from git tag; GitHub Actions build + release on tag (`ecb7c9f`, `26d4d51`, `c62e247`).
