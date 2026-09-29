# vet-skill — Process Breakdown

*A security tool for Claude Code (Windows) that vets agent "skills" before they can run, and defends its own integrity against a compromised update.*

This document explains how the whole system works end to end. It is a companion to `README.md` (which is task-oriented); this one is architecture-oriented.

---

## 1. The problem it solves

Claude Code (and the Cowork desktop app) can load **skills** and **plugins** — folders of `SKILL.md` instructions plus scripts/hooks that Claude will read and, in some cases, execute. A malicious or prompt-injected skill can exfiltrate data, run download-and-execute payloads, tamper with config, or quietly steer the agent. vet-skill puts a **human-reviewed gate** in front of that: nothing lands in your skills folder unvetted, an agent can't silently write new skill files, and drift is caught weekly.

A second, subtler problem: *a security tool that lives in a repo can be attacked through its own updates* — a poisoned `check-skills.ps1` could rubber-stamp malware as SAFE. vet-skill therefore also **protects itself** with an out-of-repo trust anchor that every entry point must pass through.

So there are **two layers**, and it's important to keep them separate:

- **Layer A — vetting *other* skills** (the everyday job).
- **Layer B — protecting *vet-skill itself*** (the self-integrity system).

---

## 2. Architecture at a glance

```
~/.claude/skills/vet-skill/            <- the skill (in-repo, updatable)
├── SKILL.md                 Layer A   the /vet-skill review procedure Claude follows
├── check-skills.ps1         Layer A   baseline + weekly drift check of OTHER units
├── guard-skills.ps1         Layer A   PreToolUse hook: block writes into unvetted skills
├── verify-vet-skill.ps1     Layer B   (source copy of the integrity gate)
├── install-vet-skill.ps1              installer / updater / -Status
├── README.md                          task-oriented usage
├── PROCESS.md                         this document
├── baseline.json            Layer A   SHA-256 hashes of every VETTED unit
└── reports/                 Layer A   weekly drift-check output

%LOCALAPPDATA%/vet-skill-trust/        <- OUT-OF-REPO trust anchor (Layer B)
├── verify-vet-skill.ps1               the integrity gate that actually runs (never
│                                      overwritten by repo updates)
├── manifest.bin             DPAPI-sealed hashes pinned at the last human APPROVE
├── known-good/                         byte-for-byte copies of vet-skill at approval
└── alerts/                             integrity-failure alarms

~/.claude/settings.json                PreToolUse hook -> verify-vet-skill.ps1 -Hook
Windows Task Scheduler: "vet-skill-weekly-check" -> verify-vet-skill.ps1 -Task
```

**The key architectural idea:** the repo copy of the skill can be updated, but the thing that *judges* the repo copy (`verify-vet-skill.ps1`, the sealed manifest, and the known-good copies) lives **outside** the repo and is only ever changed by an explicit human `APPROVE`. A compromised update can change files in the skill folder, but it cannot change the out-of-repo judge — so the change is detected and blocked.

---

## 3. Components in detail

### 3.1 `SKILL.md` — the vetting procedure (Layer A)
The instructions Claude follows when asked to "vet this skill." It is a **review checklist**, not code that runs automatically:
1. Get the target files locally **without executing** anything (never into `~/.claude/skills`).
2. Inventory files; any non-reviewable binary/obfuscated blob → **DO NOT INSTALL**.
3. Run the Cisco `skill-scanner` (automated first pass) if present.
4. Hidden-Unicode check (zero-width / bidi / tag characters) → any hit is **DO NOT INSTALL**.
5. Grep the tree for URLs, network calls, download-and-execute, credential access, exfiltration, config tampering, prompt injection, destructive ops — read every hit in context.
6. Read `SKILL.md` and every short script in full (injection is often plain English).
7. Emit a verdict: **SAFE / CAUTION / DO NOT INSTALL** with evidence.
8. Only after the human agrees, install and **record it as vetted** via `check-skills.ps1 -Approve <name>`.

Also carries the rule that Claude must **never** edit vet-skill's own folder or approve it — those are human-only.

### 3.2 `check-skills.ps1` — baseline + weekly drift check (Layer A)
Enumerates every **unit** on the machine and compares each against `baseline.json` (a map of `unit → {file → SHA-256}`).

Units covered:
- Claude Code **skills** (`~/.claude/skills/*`)
- Claude Code **plugins** (`~/.claude/plugins/cache/**`, one unit per installed version)
- **Cowork** desktop-app skills (`%APPDATA%/Claude/local-agent-mode-sessions/**/skills/*`)

Not covered (by design): claude.ai Chat skills (server-side, no local files) and the official Anthropic marketplace cache (vendor auto-updates → would false-flag).

Modes:
- `check-skills.ps1` — **weekly check.** Flags NEW/CHANGED/REMOVED units, then runs a full check on the flagged ones: (1) `skill-scanner` pass, (2) a headless read-only `claude -p` judgment that must end in `VERDICT_SAFE/CAUTION/DO_NOT_INSTALL`. **Nothing is auto-approved** — the report lists ready-to-paste approve commands for SAFE units, and a human runs them.
- `-Approve <key>` — record a unit as vetted (refuses `vet-skill` itself — that routes to the out-of-repo verifier).
- `-Baseline` — escape hatch: trust every current unit as-is.

Two safety behaviors:
- **Update notice** (read-only): compares local vet-skill files against the GitHub `raw` copies and prints `UPDATE AVAILABLE` if they differ — but **never auto-applies** (auto-applying would install a compromise).
- **Self-drift halt:** if `vet-skill` itself is among the flagged units, it does **not** scan (its own pipeline may be what changed) — it writes a note and stops.

### 3.3 `guard-skills.ps1` — the write-time guard (Layer A)
A `PreToolUse` hook on `Write|Edit`. On every file write it:
1. Ignores writes outside `~/.claude/skills`.
2. **Hard-locks vet-skill's own folder** — blocks (`exit 2`) any agent write there, even though it's baselined (otherwise a prompt-injected session could edit the guard itself).
3. For any other skill folder, allows the write only if that skill is in `baseline.json`; otherwise blocks with instructions to `/vet-skill` it first.

Normally it is **not** called directly — it runs *through* the verifier (below), which confirms vet-skill is intact first.

### 3.4 `verify-vet-skill.ps1` — the self-integrity gate (Layer B)
The heart of the self-protection. Installed **outside** the repo and **never overwritten by updates**. Every automated entry point routes through it, and it **fails closed**.

State it owns (in `%LOCALAPPDATA%/vet-skill-trust/`):
- `manifest.bin` — a **DPAPI-sealed** (CurrentUser) JSON of `{approvedAt, pinnedCommit, files:{path→SHA-256}}`, written only at human approval.
- `known-good/` — byte-for-byte copies of every vet-skill file at approval time (used to *diff* and to *restore*).

Core operation — **drift detection**: hash every current vet-skill file (excluding `.git/`, `reports/`, `baseline.json`) and compare to the sealed manifest.

Entry points:
- **(no args)** — plain integrity check; prints the diff on mismatch.
- **`-Task`** — gate, then run the weekly `check-skills.ps1`. On drift → writes an **alarm** and refuses to scan.
- **`-Hook`** — gate + self-folder lock, then hand stdin to `guard-skills.ps1`. On drift/no-manifest/error → **blocks the write** (fail closed).
- **`-ApproveSelf [-PinnedCommit <sha>]`** — interactive: shows what changed, requires the human to type `APPROVE`, then reseals the manifest, refreshes `known-good/`, and syncs the `vet-skill` entry in `baseline.json`.
- **`-Restore`** — roll the skill folder back to the pinned known-good copies (requires typing `RESTORE`).

On any integrity failure it writes an alarm to `…/alerts/` with a full diff and the two options: `-ApproveSelf` (if you made the change) or `-Restore` (if you didn't).

### 3.5 `install-vet-skill.ps1` — installer / updater
Wires everything together. Steps on a run:
0. **`-Update`**: fetch the requested ref from GitHub **over HTTPS, no git binary** (`codeload.github.com` zip → `Invoke-WebRequest` + `Expand-Archive`), show which files differ from the installed copy, and use that as the install source.
1. Copy skill files into `~/.claude/skills/vet-skill` (first install, or an authorized update).
2. Install the out-of-repo verifier (only if not already present — the pinned copy stays in charge).
3. **`-ApproveSelf`** → the human types `APPROVE` to pin the baseline.
4. `pip install cisco-ai-skill-scanner`.
5. Full audit of every existing unit (scanner + Claude review); nothing auto-approved.
6. Add/repair the `PreToolUse` guard hook (routes through the verifier; removes any legacy direct-to-`guard-skills.ps1` hook).
7. Register the weekly scheduled task (Mondays 09:00, `-StartWhenAvailable` so a missed run fires at next startup).

Flags:
- **`-Update` / `-Ref <sha|tag|branch>`** — the git-free HTTPS update above (default ref `master`).
- **`-AllowUpdate <sha>`** — optional stronger path when git *is* installed: verifies a local clone's HEAD equals the reviewed commit and the tree is clean before installing.
- **`-Status`** — read-only report of whether the skill is installed, whether the trust anchor exists, and whether the hook is current (verifier-routed) or legacy. Safe for an agent to run; the authoritative "is it installed?" check.

---

## 4. End-to-end flows

### 4.1 Vetting and installing a new skill
```
User: "vet this skill <path/URL>"
  -> Claude follows SKILL.md: fetch to scratchpad, inventory, scanner, unicode,
     grep, full read -> verdict SAFE/CAUTION/DO NOT INSTALL (with evidence)
  -> Human decides. If installing: copy into ~/.claude/skills, then
     check-skills.ps1 -Approve <name>  (adds SHA-256 hashes to baseline.json)
```

### 4.2 An agent tries to write into a skill folder (guard)
```
Write|Edit into ~/.claude/skills/...  ->  PreToolUse hook
  -> verify-vet-skill.ps1 -Hook
       - vet-skill drift?  -> BLOCK (exit 2), fail closed
       - target is vet-skill's own folder?  -> BLOCK (hard lock)
       - target skill in baseline.json?  -> ALLOW ;  else -> BLOCK ("/vet-skill it first")
```

### 4.3 Weekly drift check
```
Task Scheduler (Mon 09:00, catch-up on next boot if missed)
  -> verify-vet-skill.ps1 -Task
       - vet-skill drift?  -> write ALARM to trust/alerts, DO NOT scan
       - else -> check-skills.ps1
             - enumerate skills+plugins+cowork units
             - compare to baseline.json
             - flagged units: scanner pass + headless claude verdict
             - write reports/check_<stamp>.txt ; NOTHING auto-approved
```

### 4.4 Updating vet-skill (post-change)
```
Simple path (no git):
  install-vet-skill.ps1 -Update  [-Ref <sha|tag>]
    -> fetch from GitHub over HTTPS -> list changed files -> install
    -> APPROVE prompt re-pins the manifest/known-good  (THE verification)

Stronger path (git installed, optional):
  git clone; confirm rev-parse HEAD == reviewed sha
  install-vet-skill.ps1 -AllowUpdate <sha>   (refuses unless HEAD matches, tree clean)
    -> same APPROVE re-pin
```
The `APPROVE` is the trust root of the whole update: a compromised fetch still has to pass human review before it is pinned.

---

## 5. Trust & threat model

**What it defends against**
- Installing/running an unvetted or malicious third-party skill (Layer A: review + scanner + baseline + guard hook + weekly drift).
- An agent silently creating/altering skill files (guard hook, fail-closed).
- A **compromised vet-skill update** self-certifying (Layer B: out-of-repo DPAPI-sealed manifest, verifier-gated execution, hard-locked folder, human `APPROVE` on every update).

**Residual risks (stated honestly)**
- **Trust-on-first-use.** The first install / first approval pins whatever you reviewed. If the repo was compromised *before* you ever installed, that becomes your baseline. Your read of the code is the only defense.
- **Malware already running as your user** can, in principle, get past DPAPI (it seals *to* your user). The manifest stops a *file-dropping* repo compromise, not code already executing as you.
- **"GitHub gets corrupted."** An `-Update` fetch trusts GitHub/TLS to serve honest bytes — but the human `APPROVE` is the backstop: a poisoned fetch must still pass review. Residual risk = repo compromised **and** you approve it anyway.
- **The alarm is only as loud as its channel.** Drift alarms are written to disk; if you never read reports/alerts, detection is delayed.
- Injection can read as innocent English; CAUTION verdicts deserve real attention.

---

## 6. Where state lives (quick reference)

| Artifact | Location | Meaning |
|---|---|---|
| Skill files | `~/.claude/skills/vet-skill/` | The updatable, in-repo skill |
| `baseline.json` | (in the skill folder) | SHA-256 of every **vetted other unit** |
| Weekly reports | `…/vet-skill/reports/` | Drift-check output |
| Integrity gate | `%LOCALAPPDATA%/vet-skill-trust/verify-vet-skill.ps1` | Out-of-repo judge |
| `manifest.bin` | `…/vet-skill-trust/` | DPAPI-sealed hashes pinned at last APPROVE |
| `known-good/` | `…/vet-skill-trust/` | Byte-copies for diff & restore |
| `alerts/` | `…/vet-skill-trust/` | Integrity-failure alarms |
| Guard hook | `~/.claude/settings.json` → PreToolUse | Routes writes through the verifier |
| Weekly task | Task Scheduler `vet-skill-weekly-check` | Mon 09:00, catch-up enabled |

---

## 7. Design notes on recent hardening

- **Weekly task catch-up.** The task is registered with `Register-ScheduledTask -StartWhenAvailable`, so a run missed while the machine was off/asleep fires at next startup instead of waiting a full week.
- **`-Status`.** A read-only, authoritative install probe, so install state is never guessed from a version-shifted file layout.
- **Git-free updates.** `-Update` fetches over HTTPS with no git binary or managed clone, gated by the human `APPROVE`; `-AllowUpdate <sha>` remains as an optional git-backed provenance check for those who want the installed bytes tied to a specific public commit.
- **Robust drift-check output.** The scanner layer captures `skill-scanner` output into a variable (stderr merged, wrapped in try/catch) before writing the report, rather than piping a live native-command stream straight into `Add-Content` — the latter threw `Stream was not readable` mid-run and left header-only reports.
