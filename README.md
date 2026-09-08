# vet-skill — check a Claude Code skill for malicious content BEFORE installing it

## Why this exists

Claude Code skills are instructions and scripts that Claude follows automatically. A malicious skill doesn't need a virus — plain English in its SKILL.md can tell Claude to steal credentials, send your files somewhere, or quietly change your settings. Security research (Snyk's ToxicSkills study, 2026) found prompt injection in roughly a third of publicly shared skills. So: **never install a skill from the internet without vetting it first.** This tool is that vetting step.

## What's in this folder

| File | Purpose |
|---|---|
| `SKILL.md` | The vet-skill itself — instructions Claude follows to audit another skill |
| `guard-skills.ps1` | Hook script — asks before Claude writes into an unvetted skill folder |
| `check-skills.ps1` | The monthly run: self-check, self-update, then flag skills installed or changed without vetting |
| `setup.ps1` | Installer (Windows): clone, scanner, hook, deny rule, monthly task |
| `test-check-skills.ps1` | Self-check for the checker — builds a throwaway skill tree and a throwaway git remote in `%TEMP%` and asserts the checker flags what it should, stays quiet about what it shouldn't, and updates itself correctly. Run it after changing `check-skills.ps1` or `guard-skills.ps1` |
| `README.md` | This file |

## Install (once per machine)

```
git clone https://github.com/redlutoprint-svg/vet-skill
powershell -ExecutionPolicy Bypass -File vet-skill\setup.ps1
```

**Read the files before running the installer** — the same rule this tool exists to enforce applies to this tool. Git is required: the checkout *is* the tamper check.

The installer:
1. Clones the skill to `~\.claude\skills\vet-skill` so Claude Code can use it — as a git checkout, which is what lets it self-check and self-update later.
2. Installs the Cisco AI Defense `skill-scanner` (`pip install cisco-ai-skill-scanner`, requires Python 3.11+). Without Python the skill still works — Claude just does the review without the automated scanner layer.
3. Adds the guard hook **and** the `permissions.deny` rule that locks this folder against agent edits (settings.json backed up first).
4. Schedules the monthly maintenance run (every 4 weeks, Mondays 09:00; a run missed while the machine was off fires at next startup).
5. **Audits every skill already on your machine** — nothing is trusted blindly, nothing is auto-approved. Each unit gets the scanner pass plus a headless Claude review; the report lists ready-to-paste approve commands for units that came back SAFE, and YOU run them after reading. Requires a logged-in `claude` CLI (run `claude`, then `/login`, if you get 401s). To skip the audit and trust what's already installed: `check-skills.ps1 -Baseline`.

Re-running `setup.ps1` is safe and idempotent. Upgrading from a pre-git install? Add `-Migrate` to also remove the old weekly task and the old `%LOCALAPPDATA%\vet-skill-trust` store; your existing `baseline.json` is carried over, so nothing needs re-vetting.

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

Two enforcement layers back up the manual `/vet-skill` command.

**Guard hook (asks at install time).** A Claude Code PreToolUse hook intercepts any attempt by Claude to write files into a skill folder that isn't in the vetted baseline (`baseline.json`), and turns it into a permission prompt naming the skill. Allow it when you're authoring a skill yourself; deny it when Claude is installing something you haven't vetted. It used to hard-block, which meant every legitimate skill-authoring session died and sent you to another terminal — same interception, far less friction. Once a skill passes vetting:

```
powershell -File check-skills.ps1 -Approve <skill-name>
```

**Monthly drift check (catches everything else).** The hook only sees writes that go through Claude Code — hand-copying a folder or running `git clone` in a terminal bypasses it. So a scheduled task re-hashes every unit and compares against the baseline. Covered surfaces: Claude Code skills (`~\.claude\skills`), Claude Code plugins (`~\.claude\plugins\cache`, one unit per plugin version, key `plugin:marketplace/name/version`), and Cowork desktop-app skills (keyed `cowork:<name>`; session paths churn, so the newest copy of each skill name is checked). Deliberately NOT covered: the official Anthropic marketplace cache (vendor-published, auto-updates — would false-flag every run) and claude.ai Chat skills, which live server-side with no local files — vet those with `/vet-skill` BEFORE uploading them. Any unit that is NEW or CHANGED gets the full check: a Cisco scanner pass plus a headless Claude review, written to `reports\`. Nothing is ever auto-approved — a human reads the report and runs the listed approve command for each unit they accept. Units deleted from disk are reported once and pruned. If the headless Claude call can't authenticate, the report says so — review that unit manually and re-login.

**Why monthly and not weekly?** It was weekly, and for a single user with a stable set of skills it printed "OK, all units match" every single week for months. A check that never says anything is a check you stop reading. The drift it catches doesn't decay in a month, and the same run now also updates the tool, so there's one job instead of two.

**Why both layers matter:** in testing, the Cisco scanner rated a skill containing a literal `curl | bash` payload instruction as SAFE — pattern scanners miss attacks written as plain English. The Claude judgment layer is not optional.

## vet-skill protecting itself

vet-skill vets other skills — but what vets vet-skill? Two mechanisms, one for prevention and one for detection. Neither is a script that could itself be tampered with, which is the flaw in the version this replaced.

**Prevention: a deny rule Claude Code enforces itself.** `setup.ps1` adds this to `~\.claude\settings.json`:

```
"permissions": { "deny": ["Edit(//c/Users/<you>/.claude/skills/vet-skill/**)"] }
```

Claude Code checks it before any hook runs, no session can re-allow it, and it also covers Bash redirections (`> file`) and the file commands Claude Code recognises in Bash — coverage a `Write|Edit` hook structurally cannot have. It doesn't restrict *you*: `setup.ps1` and `git pull` run in your terminal, outside Claude Code's permission system.

**Detection: git.** The skill folder is a clean checkout, and `baseline.json` and `reports/` are gitignored, so `git status --porcelain` is the integrity check. Every monthly run reports the current commit and whether the tree is clean. Local edits are reported prominently — and the audit still runs. (The old version halted the entire run on any self-drift; for a single user the overwhelmingly likely cause is "I edited it", and a security tool that dies every month is a security tool you switch off.)

**Updates are automatic.** The monthly run fast-forwards from GitHub and re-baselines itself, so a merged PR reaches both machines on its own. The incoming commit list is printed in the report — read it. This trusts the repo: a compromised GitHub account would be pulled without a prompt. That's an accepted trade for a single-owner private tool, and it's the honest cost of "self-managing". If this repo ever gets a second committer, put an approval step back.

If the tree is dirty and it wasn't you, treat it as a compromise: `git -C ~\.claude\skills\vet-skill diff` shows exactly what changed, and `git checkout -- .` restores it.

## Mirroring this setup on another machine

Same two commands as a fresh install — `setup.ps1` is idempotent and detects what's already there:

```
git clone https://github.com/redlutoprint-svg/vet-skill
powershell -ExecutionPolicy Bypass -File vet-skill\setup.ps1 -Migrate
```

`-Migrate` is what cleans up the previous generation. On a machine that had the old install it will:

- **Delete the `vet-skill-weekly-check` scheduled task.** The monthly task does its job. Without `-Migrate` you keep both and the work runs twice.
- **Delete `%LOCALAPPDATA%\vet-skill-trust\`** (the old verifier, DPAPI manifest, known-good copies, alerts). Nothing reads it any more.
- **Re-point the guard hook.** Any existing PreToolUse entry running `verify-vet-skill.ps1` or `guard-skills.ps1` is removed and replaced with the current one, so you don't accumulate duplicates.
- **Carry over `baseline.json`** if a pre-git install is found, so nothing needs re-vetting.

Without `-Migrate` the installer leaves the old task and trust folder in place and warns about each. To confirm afterwards:

```
Get-ScheduledTask -TaskName 'vet-skill-*' | Select-Object TaskName,State
```

You should see exactly one task, `vet-skill-monthly`. `baseline.json` is deliberately gitignored and per-machine — the two computers won't have identical skill sets, and syncing baselines would mean one machine vouching for files the other never saw.

## The one rule

> Never install a skill without running `/vet-skill` on it first.

The tooling only protects you if it runs *before* the install. The main attack vector is the SKILL.md text itself, which activates the moment Claude Code loads it.

## Limits

This is a strong filter, not a guarantee. A sufficiently clever injection can read as innocent English. Treat CAUTION verdicts seriously, prefer skills from known publishers, and when in doubt, don't install.

Stated honestly:

- **Scanners are weak, and this one is no exception.** Independent 2026 testing of eight skill scanners found none beat a flag-everything baseline; the Cisco scanner is the most *precise* of them but catches roughly a third of attacks and is blind to attacks written as plain English. That is exactly why the Claude judgment layer and the manual `/vet-skill` read exist — but two weak layers are still two weak layers. Curate the source; don't treat a SAFE verdict as proof.
- **Known evasions that will get past the automated layers.** Base64/hex-wrapped payloads, homoglyph substitution, shell reassembly (`c=cu; ${c}rl`), paraphrased injection, and malice split across several individually-clean skills. `/vet-skill` greps for the first two directly; the rest rely on somebody actually reading the file.
- **Trust-on-update.** The monthly run fast-forwards from GitHub without asking. If that repo or account were compromised, the compromise installs itself. The commit list is printed in the report; reading it is the only control.
- **Malware already running as your Windows user** can rewrite any of this — the scripts, the settings file, the baseline. No same-user mechanism survives that; it's an OS-level compromise, out of scope.
- **The alarm is only as loud as its channel.** Reports are written to disk. If you never read them, detection is delayed until you do.
- **MCP servers can't be hash-baselined the way skill files can.** The drift check hashes files on disk. An MCP server's actual behaviour lives on the server: it can present benign tool descriptions when you approve it and different ones later, with nothing on your disk changing. `/vet-skill` now treats a skill that touches MCP config as DO NOT INSTALL, which closes the *skill-bundles-a-server* path — but MCP servers you add yourself are outside this system's coverage entirely, and no amount of file hashing will fix that. Add them deliberately, from sources you'd trust with a shell on your machine.
