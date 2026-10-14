# reLayout

A tiny open-source menu-bar app that instantly retypes text typed in the wrong keyboard layout.

**Website:** [relayout.forfutdinov.com](https://relayout.forfutdinov.com/)

![reLayout in action: ](assets/demo.gif)

Typed `ghbdtn` instead of `привет`? Select it, press the hotkey, and it's retyped in the right layout — the system input source switches too, so you can keep typing. Works with **any** installed layouts, not a hard-coded pair. macOS; Windows port in preview.

## Install

**macOS:**

```sh
brew install --cask vladforfutdinov/relayout/relayout
```

or download `reLayout.dmg` from the [latest release](https://github.com/vladforfutdinov/reLayout/releases/latest) and drag it to Applications (signed and notarized). On first launch, grant **Accessibility**: System Settings → Privacy & Security → Accessibility → enable reLayout → relaunch.

**Windows (preview):** each release has an installer (`reLayout-windows-<arch>-setup.exe`) and a portable `.exe` for x64 and arm64. They aren't code-signed yet, so SmartScreen asks once ("More info" → "Run anyway"). No auto-update yet — download a newer release to upgrade.

## Use

1. Select the mistyped text — or select nothing right after typing a word to fix that word.
2. Press the hotkey (default: **tap left Option**; Ctrl+Alt+R on Windows).
3. Press again within ~1.5 s to try the next layout, and once there's none left, to undo.

Only words in the wrong layout are converted: `я сказал ghbdtn` → `я сказал привет`. A word split by a layout switch is fixed too: `ghj` + switch + `сто` → `просто`.

Change the hotkey (combo, modifier tap, or tap sequence) in **rL → Settings…**.

## Auto-correct (optional, off by default)

Fixes wrong-layout words **as you type**, no hotkey:

- Between Cyrillic and Latin layouts (ru/uk ↔ en/de/fr/es/pl/pt), judged by small on-device language models tuned for ≥99% precision.
- Experimental: between similar layouts of different languages (ru ↔ uk).
- Skips password fields; terminals, code editors, VMs and remote desktops are excluded by default (Settings → Auto-correct → Exceptions…).
- Learns from you: undo a fix, or correct the same word with the hotkey a few times, and auto-correct follows your choice.

How it decides: [ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Privacy

- **Your text never leaves the machine and is never written to disk.** No analytics, telemetry, or account. The only network call is the [Sparkle](https://sparkle-project.org) update check (can be turned off).
- **The clipboard is left untouched** when Accessibility can read the selection.
- Only settings and auto-correct's learned words are stored (Settings → Learned words to view or reset).

## Limitations

- Needs at least two keyboard layouts.
- Same-script layouts (e.g. ABC vs German) can't be told apart word by word.
- Secure input fields block synthetic keystrokes.

## Build from source

```sh
./scripts/make-cert.sh   # one-time: keeps the Accessibility grant across rebuilds
./scripts/build.sh       # -> dist/ReLayout.app
```

Architecture, the Windows port and diagnostics: [ARCHITECTURE.md](docs/ARCHITECTURE.md). Releasing (including from a fork): [RELEASING.md](docs/RELEASING.md).

## Credits

UI in 12 languages. Auto-correct models are built from [FrequencyWords](https://github.com/hermitdave/FrequencyWords) by Hermit Dave (MIT, from OpenSubtitles), with the Ukrainian list filtered through [dict_uk](https://github.com/brown-uk/dict_uk); only derived statistics ship. Updates via [Sparkle](https://sparkle-project.org).

## License

[MIT](LICENSE) © 2026 Volodymyr Forfutdinov.
