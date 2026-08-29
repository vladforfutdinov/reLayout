---
description: Cut a reLayout release — preflight, tag, push, and write user-facing release notes
---

Cut a tagged release of reLayout. Pushing a `vX.Y.Z` tag triggers the GitHub
Actions `build` job (notarized DMG/zip, Sparkle appcast, Homebrew cask bump),
which is **outward-facing and ships to all users via auto-update** — so the
preflight gate and the notes matter. Arguments: `$ARGUMENTS` (an explicit
version like `1.2.16` or `v1.2.16`; if empty, default to the next patch).

Steps:

1. **Pick the version.** If `$ARGUMENTS` names one, use it (normalize to
   `vX.Y.Z`). Else `git describe --tags --abbrev=0` → bump the patch. State the
   chosen version and the previous tag.

2. **Preflight gate — all must pass, else stop and report:**
   - On `main`, working tree clean (`git status --short` empty). A release tags
     committed code; uncommitted work means the tag won't contain it.
   - `./scripts/run-tests.sh` green (and `swift test` if the engine changed).
   - The version tag does not already exist (`git tag | grep`).

3. **Sync the docs.** Scan `git log <prevtag>..HEAD` for behavior changes and make
   sure the current-state docs still match: `README.md` (user-facing behavior /
   Use / Settings / Privacy), `docs/ARCHITECTURE.md` (engine algorithm, macOS app
   description), `CLAUDE.md` (layout/conventions). Grep the docs for the old
   behavior's terms and the touched symbol names; fix anything that now lies. Docs
   that describe old behavior are worse than no docs. If a fix is needed, commit it
   to `main` **before** tagging (the tag must contain it). `docs/HISTORY.md` gets a
   new append-only block via `/handoff`, not here; `docs/SNAPSHOT.md` is the
   gitignored working note.

4. **Draft the release notes.** Read `git log <prevtag>..HEAD --oneline` and the
   actual diffs for anything user-visible. Write short markdown: a `## What's new
   in vX.Y.Z` header, one bullet per **user-visible** change in plain language
   (not raw commit titles), with a concrete before/after example where it helps.
   Skip pure internal/refactor/test/doc commits. **Show the draft and get the
   user's OK before tagging** — wording is the point of this command.

5. **Commit the notes as `docs/release-notes/vX.Y.Z.md`.** This file is the single
   source: CI prepends it to the GitHub release body (keeping the auto-generated
   Full Changelog link) and renders it via the GitHub `/markdown` API into the
   Sparkle appcast item's `<description>`, which is what users read in the "new
   version available" window. It must be committed **before** the tag — CI reads it
   from the tagged commit. Keep it self-contained markdown (headers, bullets,
   inline code); no relative links, since it is rendered outside the repo.

6. **Tag and push.** Annotated tag (`git tag -a vX.Y.Z -m "<one-line summary>"`),
   then `git push origin main` and `git push origin vX.Y.Z`. This starts CI.

7. **Report CI.** `gh run list --limit 3` — confirm the `build` (tag) and `core`
   runs, surface any failure. Then verify the notes landed in both places:
   `gh release view vX.Y.Z --json body` and the `<description>` of the newest item
   in `appcast.xml` on `gh-pages`.

Don't bump version files (the version comes from the git tag). Don't touch the
Windows job (frozen; tag releases are macOS-only). Two standing rules apply: notes
are mandatory on every tag, and the docs must be current before tagging.
