---
description: Update cross-session context (SNAPSHOT + HISTORY) before /clear or ending a session
---

Refresh the handoff docs so the next session picks up cleanly. Steps:

1. **Run the gate.** `./scripts/run-tests.sh` and (if engine touched) `swift test`.
   Record the result for the Test-status section. Red → stop and fix first.

2. **Rewrite `docs/SNAPSHOT.md`** — operational current state, not a log.
   **Overwrite** each section (don't append):
   - **Status / Last updated** — short header.
   - **What's done (this session)** — only what closed *this* session. Drop
     prior-session entries entirely.
   - **In progress / Known issues / Next steps / Test status / Uncommitted.**

3. **Append to `docs/HISTORY.md`** — one block per milestone completed this session
   (not per commit). Newest on top, under the intro `---`. Reference commit SHAs.
   Skip if nothing milestone-worthy landed.

4. **Verify before claiming.** Any path/count/SHA you write must match reality —
   `git log --oneline`, `git status`, actual file paths. Don't guess.

5. **Don't** commit or push as part of this command unless explicitly asked.

Keep SNAPSHOT to ~one screen. Chronology lives in HISTORY; SNAPSHOT is the snapshot.
