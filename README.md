# vet-skill — check a Claude Code skill for malicious content BEFORE installing it

## Why this exists

Claude Code skills are instructions and scripts that Claude follows automatically. A malicious skill doesn't need a virus — plain English in its SKILL.md can tell Claude to steal credentials, send your files somewhere, or quietly change your settings. Security research (Snyk's ToxicSkills study, 2026) found prompt injection in roughly a third of publicly shared skills. So: **never install a skill from the internet without vetting it first.** This tool is that vetting step.

## What's in this folder

| File | Purpose |
|---|---|
| `SKILL.md` | The vet-skill itself — instructions Claude follows to audit another skill |
| `guard-skills.ps1` | Hook script — blocks Claude from writing into unvetted skill folders |
| `check-skills.ps1` | Baseline + weekly drift check — flags skills installed or changed without vetting |
| `install-vet-skill.ps1` | One-time installer (Windows): skill, scanner, hook, weekly task |
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
2. Installs the Cisco AI Defense `skill-scanner` (`pip install cisco-ai-skill-scanner`, requires Python 3.10+). If you don't have Python, the skill still works — Claude just does the review without the automated scanner layer.
3. **Audits every skill already on your machine** — nothing is trusted blindly, and nothing is auto-approved. Each existing skill gets the scanner pass plus a headless Claude review; the report lists ready-to-paste approve commands for units that received a SAFE verdict, and YOU run them after reading. Anything rated CAUTION or worse deserves a closer look before approving. The audit takes a few minutes and requires a logged-in `claude` CLI (run `claude`, then `/login`, if you get 401 errors). To skip the audit and trust everything as-is: `check-skills.ps1 -Baseline`.
4. Adds the guard hook to your Claude Code settings (backup saved first) and schedules the weekly drift check.

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

The installer sets up two enforcement layers beyond the manual `/vet-skill` command:

**Guard hook (blocks at install time).** A Claude Code PreToolUse hook intercepts any attempt by Claude to write files into a skill folder that isn't in the vetted baseline (`baseline.json`). The write is blocked with instructions to run `/vet-skill` first. After a skill passes vetting and you approve it, it's recorded with:

```
powershell -File check-skills.ps1 -Approve <skill-name>
```

**Weekly drift check (catches everything else).** The hook only sees installs that go through Claude Code — someone hand-copying a folder or running `git clone` in a terminal bypasses it. So a scheduled task (Mondays 9:00) re-hashes every unit and compares against the baseline. Covered surfaces: Claude Code skills (`~\.claude\skills`), Claude Code plugins (`~\.claude\plugins\cache`, one unit per plugin version, key `plugin:marketplace/name/version`), and Cowork desktop-app skills (keyed `cowork:<name>`; session paths churn, so the newest copy of each skill name is checked). Deliberately NOT covered: the official Anthropic marketplace cache (vendor-published, auto-updates — would false-flag weekly) and claude.ai Chat skills, which live server-side with no local files — vet those with `/vet-skill` BEFORE uploading them to claude.ai. Any unit that is NEW (never vetted) or CHANGED (modified since vetting) automatically gets the full check: a Cisco scanner pass plus a headless Claude review, written to `reports\`. Nothing is ever auto-approved — a human reads the report and runs the listed approve command for each unit they accept. Units deleted from disk are reported once and pruned. If the headless Claude call can't authenticate, the report says so — review that unit manually and re-login (`claude`, then `/login`).

**Why both layers matter:** in testing, the Cisco scanner rated a skill containing a literal `curl | bash` payload instruction as SAFE — pattern scanners miss attacks written as plain English. The Claude judgment layer is not optional.

## Team rule

> Never install a skill without running `/vet-skill` on it first.

The tooling only protects you if it runs *before* the install. The main attack vector is the SKILL.md text itself, which activates the moment Claude Code loads it.

## Limits

This is a strong filter, not a guarantee. A sufficiently clever injection can read as innocent English. Treat CAUTION verdicts seriously, prefer skills from known publishers, and when in doubt, don't install.
