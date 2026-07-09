# Session handoff — self-protection feature (delete this file before merging)

**Branch:** `claude/vet-skill-project-pmi3bd` · **Work commit:** `88ec20d` ·
**Written:** 2026-07-09 for a follow-up session on Friday 2026-07-10.

## What was done (complete, pushed, NOT yet runtime-verified)

Commit `88ec20d` adds self-protection against a compromised repo update.
Design principle: nothing inside the folder that updates can overwrite is allowed
to verify that folder.

- **`verify-vet-skill.ps1` (new)** — external integrity gate. Installer copies it to
  `%LOCALAPPDATA%\vet-skill-trust\` and never overwrites that copy. Pins a
  DPAPI-sealed SHA-256 manifest (`manifest.bin`) + plaintext known-good copies
  (`known-good\`, validated against the manifest before use). Modes: default
  (check + diff), `-Task` (gate, then run check-skills.ps1), `-Hook` (gate +
  hard-lock of vet-skill folder, then run guard-skills.ps1), `-ApproveSelf`
  (interactive "APPROVE" prompt; also writes the vet-skill entry in baseline.json),
  `-Restore` (interactive "RESTORE"; rolls skill folder back to pinned copies).
- **`check-skills.ps1`** — halts the whole scan pass if its own unit drifted
  (pipeline may be compromised); refuses `-Approve vet-skill`; update notice now
  describes the pinned-commit flow instead of "re-run the installer"; skips
  missing local files in the update check; compares `verify-vet-skill.ps1` too.
- **`guard-skills.ps1`** — hard-locks vet-skill's own folder (exit 2) even though
  it is baselined.
- **`install-vet-skill.ps1`** — refuses to overwrite an existing install unless
  `-AllowUpdate <sha>` equals `git rev-parse HEAD` of a clean checkout (updates
  git-only; zip valid for first install only); bootstraps the trust anchor; warns
  (never overwrites) when the repo ships a different verifier than the pinned one;
  migrates old direct guard-skills.ps1 hooks in settings.json to the verifier;
  re-points the weekly schtasks entry at `verifier -Task`.
- **README.md / SKILL.md** — self-protection docs, re-approval steps, Limits
  updated (gap closed; TOFU and same-user malware stated as still open).

## What is NOT done — Friday's job

The 2026-07-09 container had no PowerShell and the network policy blocked
installing it (github.com release downloads 403 outside the scoped repo;
packages.microsoft.com 403). Everything below is unverified beyond careful
manual review.

### 1. Parse check (do this first)

If `pwsh` is available (or installable) in the new container:

```
for f in *.ps1; do pwsh -NoProfile -Command \
  "[void][System.Management.Automation.Language.Parser]::ParseFile('$PWD/$f', [ref]\$null, [ref]\$err); \$err | ForEach-Object { \$_.Message; \$_.Extent }; exit [int](\$err.Count -gt 0)" \
  && echo "OK: $f" || echo "FAIL: $f"; done
```

### 2. Functional smoke tests

DPAPI (`[Security.Cryptography.ProtectedData]`) is **Windows-only** — on Linux
pwsh the verifier will throw at `Read-Manifest`/`Save-Manifest`. Do NOT add a
Linux fallback to make tests pass; the tool is Windows-first. On Linux you can
still verify: parse-clean, `-Hook` fast-path (non-skills write exits 0 before any
DPAPI call), and guard-skills.ps1 / check-skills.ps1 logic that doesn't touch DPAPI.
Full flows need Windows (or the user runs them):

- First install → `APPROVE` prompt → trust store created, `baseline.json` has
  vet-skill entry, schtasks points at verifier `-Task`, settings.json hook points
  at verifier `-Hook`.
- Tamper with `check-skills.ps1` in the skills folder → verifier default mode
  prints diff + writes alert; `-Task` refuses to run the drift check; `-Hook`
  blocks a skills-dir write; `-Restore` rolls back and verifier reports OK.
- Re-run installer with no flag → refuses. With wrong sha → refuses. With
  `-AllowUpdate $(git rev-parse HEAD)` on a clean clone → updates + re-pins.
- Legacy migration: settings.json containing the OLD direct guard-skills.ps1 hook
  gets it replaced by the verifier hook (check the `Add-Member ... -Force` path
  when PreToolUse ends up an empty array).

### 3. Constructs I flagged as highest syntax/behavior risk during review

- `verify-vet-skill.ps1`: comma-operator array returns (`return ,@(...)` in
  `Get-Drift`/`Get-DiffText`); `$manifest.files.PSObject.Properties[$rel]`
  indexer; stdin re-pipe `$stdin | & powershell.exe ... guard-skills.ps1` and
  `exit $LASTEXITCODE` propagation; `git diff --no-index` exit code 1 under
  `$ErrorActionPreference='Stop'` (should not throw — native command).
- `install-vet-skill.ps1`: in-process `& $verifier -ApproveSelf` — child `exit`
  must return to installer with `$LASTEXITCODE` set, not kill it; `$files` array
  flattening into `git status --porcelain -- $files`; hook-migration branch
  logic (`$alreadyHooked`/`$removedLegacy` matrix).

### 4. Cleanup

Delete this HANDOFF.md (and this line item) once verification passes, then push.
No PR was created — the user has not asked for one.
