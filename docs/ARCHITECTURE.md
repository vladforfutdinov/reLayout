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

The hotkey acts **only on a selection** — what the user pointed at. Unselected text is never guessed at: no line grab, no word-at-the-caret window. Text the user typed but did not select belongs to the auto-correct mode, which knows what it saw typed. `caretWord(_:)` stays in the engine for that mode.

A word that mixes scripts comes from a **mid-word layout switch** ("ghjсто"). `convertWrong` converts only such a token's src-script runs (`convertScriptRuns`), and `planRetype` sends a single-word selection to `fixMixedWord` first: which half is wrong is not decidable from the layouts ("ghjсто" wants its head fixed, "мирqwerty" its tail), so both readings are trigram-scored and the better wins — no confidence gates, the hotkey is an explicit request.

`Core/Auto.swift` — the auto-correct mode's platform-free half, shared by both apps: `decideAutoTarget` (the cross-script trigram decision), `AutoRun` (the typed-word run — word, punctuation trail, previous word — with its feed/Backspace/short-word rules) `awaitSettledField` (the Enter follow-up's settle loop), and the hotkey's `planRetype` / `pickTarget` / `fixMixedWord` (which layouts a selection converts between). Each app only feeds it keystrokes and performs the fix it returns.

`Core/Strings.swift` — `parseStrings`, a reader for the `.strings` files, so the Windows port shows the macOS translations (macOS itself reads them through `Bundle`).

`Core/Trigram.swift` — a character-trigram language model used by the auto-correct mode. `TrigramModel.score(_:)` returns a word's length-normalized mean trigram log-prob under a per-language model; models are generated offline (`scripts/trigram/gen.py`) from frequency word lists and shipped as `Resources/trigram/<lang>.txt`. Platform-free, so it lives in the engine.

## macOS app (`macos/main.swift`, single file)

Holds everything outside the engine:
- `Loc` / `L(_:)` — localization. UI strings live in `Resources/<lang>.lproj/Localizable.strings`. Languages are discovered from shipped `.lproj` bundles; user override in `UserDefaults["language"]` switches live, no relaunch.
- Hotkey system — supports **combos** (e.g. ⌃⌥R via `RegisterEventHotKey`) and **modifier taps/chords** (e.g. tap left Option). Tap/chord detection uses a `CGEventTap` and fires only on release with no other key/mouse press in between; a `tapPolluted` guard ignores cycles where an out-of-set modifier appeared. A hotkey can also be a **tap sequence** (`hotKeyTaps` — N activations within `doubleTapWindow`, e.g. double-tap Shift), recorded by repeating it in the `ShortcutField`.
- Auto-correct mode (`autoMode`, default off) — a second `CGEventTap` (keyDown) feeds the engine's `AutoRun` and, on a word boundary, runs `autoDecide` (engine `decideAutoTarget`: trigram scores, cross-script targets only) → `autoCorrect` deletes + retypes the fixed word and switches layout. Short words (1-2 chars, e.g. prepositions `d`→в, `yf`→на) score fine — the model pads `^^w$` — but aren't trusted alone; `AutoRun.plan` remembers a short candidate and only converts it when it borders a real conversion of the same script, so a following long word swallows a pending preposition into one edit ("d ljhjut"→"в дороге") while a lone short junk token is left untouched. Punctuation that is a letter on an enabled Cyrillic layout (`,`=б, `'`=э, `;`=ж, `[`=х …) buffers as word material, so ",skj" fixes to "было"; `autoWordCore` (engine) vets the shape — a trailing mapped char is word material too ("vj]" → "мої", "gj[j;" → "похож") — the word minus its edge punctuation must not already be plausible ("hello," stays), and a word shorter than 3 chars without its trailing mapped run waits for a neighbour like a preposition ("vs." would read as "мію") — and punctuation-bearing words must clear an absolute plausibility gate (`autoPunctPlausible`) on top of the usual margin. Other punctuation/symbols right after a word (not word material on any enabled layout) collect in the run's trail; the word is still judged only at whitespace, and the trail is retyped through the same layouts, so "ltkfq? " fixes to "делай, " — no character table, and "@"/"/" inside an address or path (never followed by whitespace) end nothing. A keystroke producing no character (Globe/fn, dead keys, F-keys) is skipped instead of ending the word run — otherwise the layout switch itself would drop the pre-switch half. Switching the layout mid-word leaves one word with both scripts ("ghjсто"): `autoDecide` takes a mixed-word branch built on engine `convertScriptRuns` (converts only the runs of the source layout's script), trying both readings — fix the pre-switch run into the current script ("просто", no input-source switch) or the current-layout run into the cross-script candidate — each scored under the model of its resulting script. A user deny-list (`autoExcludedApps`, edited via the Exceptions sheet) plus a secure-text-field check gate it per app; our own synthesized events carry `synthMarker` so the monitor ignores them. Fast typists outrun the retype — the delete+retype of a finished word would interleave with whatever was typed since, mixing the text and converting the wrong characters — so the auto tap is a `.defaultTap` and, while a correction is in flight (`autoPending`), it *swallows* text-producing keys into `autoHeld` and returns nil; `finishCorrection` replays them once the queue drains, feeding each key through the word buffer *before* typing it — a replayed boundary that starts another correction is typed by that correction, and the keys after it go back on hold. Return is never swallowed and never corrects before it lands (it may submit a launcher query or a chat message). `autoEnterFollowUp` reads the focused field over AX (`fieldSnapshot`: length, caret, 64 chars before it) and, under the keystroke gate, `finishEnter` polls until the field is stable for ~75 ms (the system capitalizes the word ~50 ms after the break), then engine `enterOutcome` decides: only `.newline` deletes break + word and retypes the fix + a real Return. Short words, held Returns, fields without `AXStringForRange` (Chromium/Electron) and the Settings sub-option `autoEnterNewline` (default on, disabled while auto-correct is off) keep plain Return. Replayed Return and a swallowed Tab boundary are posted as real keys with their Shift/Option flags (`typeKey`), never as a Unicode "\r"/"\t": apps act on the key code. The tap also watches mouse-downs: a click, like any Cmd/Ctrl shortcut, may move the caret or focus, so either ends the run (buffer, trail and pending preposition) — otherwise a later correction deletes text before the new caret and pastes the stale word there. Only character keys are held: modifiers, Globe, arrows and delete always pass through, so a stuck correction can never freeze the keyboard.
- Selection read/write — Accessibility API first (so DeepL etc. don't see clipboard churn); clipboard fallback reads the selection with **Cmd+C** (copy keeps the selection and typing replaces exactly it — smart cut-and-paste in Word-like apps would otherwise swallow an adjacent space along with a cut word). Saves/restores pasteboard.
- Input source switching — Text Input Sources / TISSelectInputSource.
- Settings — the auto-correct checkbox is disabled (shown off, stored preference kept, ⓘ icon with the reason `settings.autoCorrectUnavailable` naming the enabled layouts as an instant tooltip — `NSInitialToolTipDelay` = 0, app-wide) while the enabled layouts are all one script (`updateAutoAvailability`, re-run on the enabled-sources notification).
- Settings — a single window that also holds the About info (logo / version / link). Menu-bar item (`NSStatusItem`), login item (`SMAppService`), conflict check against `com.apple.symbolichotkeys`. The live hotkey + auto-correct are suspended only while the shortcut recorder field is actively capturing (`recordingHotkey`, set by `ShortcutField.onRecordingChanged`), so the keys being recorded can't trigger a conversion — merely having Settings open leaves the hotkey live. `finalizeSequence` commits a tap sequence and re-applies the hotkey while the field is still focused, so the gate holds the re-apply off until the recorder stops. `Cmd+W`/`Cmd+Q` handled by physical keyCode (no main menu).
- Press-again undo: a second hotkey within `undoWindow` (1.5 s) of a conversion reverses it (single-tap hotkeys only).
- Sparkle auto-update under `#if SPARKLE` (only compiled when `WITH_SPARKLE=1`).
- `dbg(_:)` writes to `/tmp/relayout.log` only under `-DDEBUG`. Release builds **must never** write selection text to disk — the empty release body is inlined away under `-O`. Don't add prints of user text outside this guard.

`macos/tests.swift` provides a `@main` entry under `-DTESTING` that replaces the GUI bootstrap so the unit tests exercise the **real** engine + helpers, not copies.

## Windows port (`windows/`, preview)

- `main.swift` — single-instance mutex, message loop (with `IsDialogMessageW` for our windows), the hotkey retype and press-again undo.
- `WinHotkey.swift` — low-level keyboard hook: combos and bare-modifier taps, hotkey capture for Settings; also feeds the auto mode.
- `WinLayout.swift` — builds `LayoutMaps` via `ToUnicodeEx` (cached per HKL), language code, lists/switches HKLs.
- `WinInput.swift` — `SendInput` writes (Unicode text, real keys, Backspace, Shift+Left), the Ctrl+C fallback read with clipboard save/restore, `pumpWait`, focus/console helpers.
- `WinUIA.swift` + `uia/relayout_uia.cpp` — UI Automation: the selection, the field snapshot for the Enter follow-up, the password-field flag. C++ because Swift has no COM.
- `WinAuto.swift` — the auto-correct mode around the engine's `AutoRun`, with a mouse hook that ends the run on a click.
- `WinTray.swift` — tray icon and menu, launch-at-login (HKCU Run), the hidden window that runs fixes off the hook.
- `WinSettings.swift` / `WinExceptions.swift` / `WinPrefs.swift` / `WinLoc.swift` — Settings and Exceptions windows, preferences in the registry, UI strings.

Only built when host OS is Windows (`#if os(Windows)` gate in `Package.swift`); macOS `swift test` ignores the executable target. Selection is read through UI Automation (`windows/uia/relayout_uia.cpp`, a C++ target — Swift has no COM); the clipboard is the fallback for controls without UIA text, and is saved and restored around it. `WinAuto.swift` is the opt-in auto-correct mode: the keyboard hook feeds typed characters into a word buffer, a boundary (space/Tab) runs the shared `decideAutoTarget`, and the fix is backspaced in and retyped. Trigram models ship as `trigram/<lang>.txt` next to the exe. Short words follow the macOS neighbour rule, and the Enter follow-up uses a second UIA call (field length, caret, selection, the text before the caret) with the engine's `enterOutcome`. A deny-list of executables (Settings > Exceptions) and the UIA password-field flag gate it per app and per field. UI strings come from the macOS `Localizable.strings`, shipped as `lang/<code>.lproj` next to the exe and read with the engine's `parseStrings` (`WinLoc.swift`); Settings has a language picker that rebuilds the window live, and rebuilds it on `WM_DPICHANGED` too. The hook runs on the main thread, so every wait in the retype path uses `pumpWait` (pumps messages), never `Sleep`. Not released: `build-windows` runs only on manual dispatch (installer + portable SFX for x64 and arm64, unsigned).
