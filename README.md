# vet-skill — check a Claude Code skill for malicious content BEFORE installing it

## Why this exists

Claude Code skills are instructions and scripts that Claude follows automatically. A malicious skill doesn't need a virus — plain English in its SKILL.md can tell Claude to steal credentials, send your files somewhere, or quietly change your settings. Security research (Snyk's ToxicSkills study, 2026) found prompt injection in roughly a third of publicly shared skills. So: **never install a skill from the internet without vetting it first.** This tool is that vetting step.

## What's in this folder

| File | Purpose |
|---|---|
| `SKILL.md` | The vet-skill itself — instructions Claude follows to audit another skill |
| `guard-skills.ps1` | Hook script — blocks Claude from writing into unvetted skill folders |
| `check-skills.ps1` | Baseline + weekly drift check — flags skills installed or changed without vetting |
| `verify-vet-skill.ps1` | Integrity gate for vet-skill ITSELF — installed outside the repo, checks every vet-skill file against an out-of-repo pinned baseline before any other script runs |
| `install-vet-skill.ps1` | Installer (Windows): skill, scanner, hook, weekly task, trust anchor. Re-runs refuse to update unless pinned to a reviewed commit |
| `README.md` | This file |

## Install (once per machine)

Get the files (either works):

```
git clone https://github.com/redlutoprint-svg/vet-skill
```

or download the zip from https://github.com/redlutoprint-svg/vet-skill/archive/refs/heads/master.zip and extract it. **Read the files before running the installer** — the same rule this tool exists to enforce applies to this tool.

Then run:

```
powershell -ExecutionPolicy Bypass -File install-vet-skill.ps1
```

The installer sets up the whole system:
1. Copies the skill into your `~\.claude\skills\` folder so Claude Code can use it.
2. Installs the **integrity verifier** (`verify-vet-skill.ps1`) to `%LOCALAPPDATA%\vet-skill-trust\` — *outside* the skill folder, where repo updates can't touch it — and asks you to type `APPROVE` to pin the files you just reviewed as the known-good reference. See "vet-skill protecting itself" below.
3. Installs the Cisco AI Defense `skill-scanner` (`pip install cisco-ai-skill-scanner`, requires Python 3.10+). If you don't have Python, the skill still works — Claude just does the review without the automated scanner layer.
4. **Audits every skill already on your machine** — nothing is trusted blindly, and nothing is auto-approved. Each existing skill gets the scanner pass plus a headless Claude review; the report lists ready-to-paste approve commands for units that received a SAFE verdict, and YOU run them after reading. Anything rated CAUTION or worse deserves a closer look before approving. The audit takes a few minutes and requires a logged-in `claude` CLI (run `claude`, then `/login`, if you get 401 errors). To skip the audit and trust everything as-is: `check-skills.ps1 -Baseline`.
5. Adds the guard hook to your Claude Code settings (backup saved first) and schedules the weekly drift check (Mondays 9:00; if the machine is off at that time, the check runs at the next startup instead of waiting a full week) — both routed through the integrity verifier.

**Re-running the installer does NOT update an existing install.** Updates must be pinned to a commit you reviewed — see "Updating vet-skill" below. (A zip download works for the *first* install; updates require a git clone, because a zip can't prove which commit it contains.)

Mac/Linux: copy this folder into `~/.claude/skills/` manually and run `pip install cisco-ai-skill-scanner`.

## Use

In Claude Code, before installing any skill you downloaded or were sent:

```
/vet-skill C:\path\to\downloaded-skill
/vet-skill https://github.com/someone/some-skill
```

Claude then:

1. **Fetches the files without executing anything** — no installer scripts are run, URLs are downloaded to a scratch folder, never straight into your skills directory.
2. **Inventories every file** — any binary, compiled, or obfuscated content (`.exe`, `.dll`, minified JS, base64 blobs) is an automatic fail, because it can't be reviewed.
3. **Runs the Cisco skill-scanner** (if installed) — automated detection of known malicious patterns.
4. **Checks for hidden Unicode** — invisible characters (zero-width spaces, Unicode Tags) that can carry instructions you can't see in a text editor. Any hit is an automatic fail.
5. **Greps for eight risk categories** — external URLs, network calls, download-and-execute patterns, credential/secret access, data exfiltration, settings/config tampering, prompt-injection language ("ignore previous instructions", "do not tell the user"), and destructive commands.
6. **Reads the entire SKILL.md and every script** — pattern-matching catches the obvious; a human-style read catches injection written as innocent-sounding English.
7. **Reports a verdict:**
   - **SAFE** — no network calls, no scripts, no injection language. OK to install.
   - **CAUTION** — has network access or scripts that look legitimate. The report names exactly what it contacts and what it sends; you decide.
   - **DO NOT INSTALL** — download-and-execute, exfiltration, hidden Unicode, unreviewable binaries, or injection language found.
8. **Installs only if you explicitly say so** after reading the report.

## Automatic protection

The installer sets up two enforcement layers beyond the manual `/vet-skill` command. Both are entered through the out-of-repo integrity verifier: `verify-vet-skill.ps1` first confirms that every vet-skill file still matches what you approved, and only then hands off to the repo-shipped scripts — so a tampered checker or guard never gets to run.

**Guard hook (blocks at install time).** A Claude Code PreToolUse hook intercepts any attempt by Claude to write files into a skill folder that isn't in the vetted baseline (`baseline.json`). The write is blocked with instructions to run `/vet-skill` first. vet-skill's own folder is hard-locked — even though it's baselined, Claude can never edit it; if vet-skill's integrity check fails, *all* skill-folder writes are blocked until you resolve it. After a skill passes vetting and you approve it, it's recorded with:

```
powershell -File check-skills.ps1 -Approve <skill-name>
```

**Weekly drift check (catches everything else).** The hook only sees installs that go through Claude Code — someone hand-copying a folder or running `git clone` in a terminal bypasses it. So a scheduled task (Mondays 9:00) re-hashes every unit and compares against the baseline. Covered surfaces: Claude Code skills (`~\.claude\skills`), Claude Code plugins (`~\.claude\plugins\cache`, one unit per plugin version, key `plugin:marketplace/name/version`), and Cowork desktop-app skills (keyed `cowork:<name>`; session paths churn, so the newest copy of each skill name is checked). Deliberately NOT covered: the official Anthropic marketplace cache (vendor-published, auto-updates — would false-flag weekly) and claude.ai Chat skills, which live server-side with no local files — vet those with `/vet-skill` BEFORE uploading them to claude.ai. Any unit that is NEW (never vetted) or CHANGED (modified since vetting) automatically gets the full check: a Cisco scanner pass plus a headless Claude review, written to `reports\`. Nothing is ever auto-approved — a human reads the report and runs the listed approve command for each unit they accept. Units deleted from disk are reported once and pruned. If the headless Claude call can't authenticate, the report says so — review that unit manually and re-login (`claude`, then `/login`).

**Why both layers matter:** in testing, the Cisco scanner rated a skill containing a literal `curl | bash` payload instruction as SAFE — pattern scanners miss attacks written as plain English. The Claude judgment layer is not optional.

## vet-skill protecting itself

vet-skill vets other skills — but what vets vet-skill? If this repo were compromised and you pulled a malicious update, the update could rewrite `check-skills.ps1` to always report SAFE, and the system would go quiet instead of alarming. The self-protection layer closes that loop. The design principle: **nothing inside the folder that updates can overwrite is allowed to verify that folder.**

**The trust anchor lives outside the repo.** On first install, `verify-vet-skill.ps1` is copied to `%LOCALAPPDATA%\vet-skill-trust\` and never touched by updates again. When you type `APPROVE`, it pins two things there: a manifest of SHA-256 hashes sealed with Windows DPAPI (CurrentUser), and plaintext known-good copies of every file (themselves validated against the sealed manifest before use, so they can't be silently swapped). The scheduled task and the guard hook point at this verifier — not at the repo scripts — so the gate runs *before* any repo-shipped code.

**On any change to vet-skill's own files** — whether from a `git pull`, a hand edit, or a hostile update:
- The verifier refuses to run `check-skills.ps1` or `guard-skills.ps1` at all. No scanner pass, no headless Claude review — that pipeline is exactly what may have been tampered with.
- It prints a **diff against the pinned known-good copies** (using `git diff --no-index` when git is available) and writes an alarm file to `%LOCALAPPDATA%\vet-skill-trust\alerts\`.
- The guard hook blocks all skill-folder writes, and `check-skills.ps1` (if invoked directly) halts before scanning anything, for the same reason.
- Nothing runs again until a human either **re-approves** (`verify-vet-skill.ps1 -ApproveSelf` — after reading the diff) or **rolls back** (`verify-vet-skill.ps1 -Restore` — copies the pinned known-good files back over the skill folder).

Both `-ApproveSelf` and `-Restore` require typing a confirmation word at an interactive prompt, which an agent-driven session cannot do — Claude cannot re-pin trust on your behalf.

### Updating vet-skill after a legitimate new release

0. **Check what's on this machine first:** `powershell -ExecutionPolicy Bypass -File install-vet-skill.ps1 -Status`. This read-only command reports whether the skill is installed, whether the out-of-repo trust anchor exists, and whether the guard hook is the current (verifier-routed) or a legacy (direct `guard-skills.ps1`) one. Use it instead of guessing install state from the file layout — the layout changed across versions, so eyeballing it can wrongly conclude vet-skill isn't installed. An older install (no trust anchor, legacy hook) still updates correctly with the steps below.
1. See what's pinned: `powershell -File "$env:LOCALAPPDATA\vet-skill-trust\verify-vet-skill.ps1"` prints the approved commit.
2. **Read the diff on GitHub** between that commit and the new one. This is the actual review — nothing downstream substitutes for it.
3. Clone fresh and confirm you have exactly what you reviewed: `git clone https://github.com/redlutoprint-svg/vet-skill && git -C vet-skill rev-parse HEAD`.
4. Run the pinned update: `powershell -ExecutionPolicy Bypass -File install-vet-skill.ps1 -AllowUpdate <that full sha>`. The installer refuses if the checkout's HEAD doesn't match the flag or the working tree is dirty.
5. Type `APPROVE` at the prompt — this re-pins the hashes and known-good copies in the trust folder.

If the weekly check prints an `UPDATE AVAILABLE` notice, it deliberately does **not** tell you to re-run the installer — if the repo is compromised, that advice would install the compromise. Follow the steps above instead.

### If the alarm fires and you didn't change anything

Treat it as a compromise. Read the diff in the alarm (also saved under `%LOCALAPPDATA%\vet-skill-trust\alerts\`), then roll back with `verify-vet-skill.ps1 -Restore`. Don't run any script from the skill folder until the verifier reports OK again.

## Team rule

> Never install a skill without running `/vet-skill` on it first.

The tooling only protects you if it runs *before* the install. The main attack vector is the SKILL.md text itself, which activates the moment Claude Code loads it.

## Limits

This is a strong filter, not a guarantee. A sufficiently clever injection can read as innocent English. Treat CAUTION verdicts seriously, prefer skills from known publishers, and when in doubt, don't install.

**Closed gap — a hacked vet-skill repo.** Earlier versions had no defense against a compromised update to vet-skill itself: a malicious `check-skills.ps1` could self-certify as SAFE. That's now covered by the self-protection layer above — out-of-repo trust anchor, verifier-gated execution, hard-locked skill folder, and commit-pinned updates. To re-approve after a legitimate update, follow "Updating vet-skill after a legitimate new release."

Still open, stated honestly:

- **Trust-on-first-use.** The very first install pins whatever you cloned. If the repo was already compromised *before* you ever installed, the malicious version becomes your baseline. Your own read of the code at first install is the only defense.
- **Malware already running as your Windows user.** DPAPI (CurrentUser) stops a repo update from *forging* the trust store via files alone, but any code already executing as you can decrypt, re-seal, or delete it — and could equally rewrite the verifier. No same-user store can survive that; it's an OS-level compromise, out of scope for this tool.
- **The pinned verifier is frozen by design.** If `verify-vet-skill.ps1` itself needs a fix, the installer will warn but won't overwrite your pinned copy — you must read the new version and copy it into `%LOCALAPPDATA%\vet-skill-trust\` by hand.
- **The alarm is only as loud as its channel.** The weekly task writes alarms to disk; if you never look at reports or alerts, detection is delayed until you do.
