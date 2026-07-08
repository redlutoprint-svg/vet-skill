# vet-skill — check a Claude Code skill for malicious content BEFORE installing it

## Why this exists

Claude Code skills are instructions and scripts that Claude follows automatically. A malicious skill doesn't need a virus — plain English in its SKILL.md can tell Claude to steal credentials, send your files somewhere, or quietly change your settings. Security research (Snyk's ToxicSkills study, 2026) found prompt injection in roughly a third of publicly shared skills. So: **never install a skill from the internet without vetting it first.** This tool is that vetting step.

## What's in this folder

| File | Purpose |
|---|---|
| `SKILL.md` | The vet-skill itself — instructions Claude follows to audit another skill |
| `install-vet-skill.ps1` | One-time installer (Windows) |
| `README.md` | This file |

## Install (once per machine)

```
powershell -ExecutionPolicy Bypass -File install-vet-skill.ps1
```

This does two things:
1. Copies the skill into your `~\.claude\skills\` folder so Claude Code can use it.
2. Installs the Cisco AI Defense `skill-scanner` (`pip install cisco-ai-skill-scanner`, requires Python 3.10+). If you don't have Python, the skill still works — Claude just does the review without the automated scanner layer.

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

## Team rule

> Never install a skill without running `/vet-skill` on it first.

The tooling only protects you if it runs *before* the install. The main attack vector is the SKILL.md text itself, which activates the moment Claude Code loads it.

## Limits

This is a strong filter, not a guarantee. A sufficiently clever injection can read as innocent English. Treat CAUTION verdicts seriously, prefer skills from known publishers, and when in doubt, don't install.
