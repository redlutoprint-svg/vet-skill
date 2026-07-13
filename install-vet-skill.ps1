# Installs the vet-skill Claude Code skill, the Cisco skill-scanner CLI,
# the unvetted-skill guard hook, the weekly drift-check scheduled task, and
# vet-skill's own out-of-repo trust anchor (verify-vet-skill.ps1 + pinned hashes).
# First install (run from a checkout you have READ first):
#   powershell -ExecutionPolicy Bypass -File install-vet-skill.ps1
# Updates REFUSE to run unless pinned to the exact commit you reviewed:
#   powershell -ExecutionPolicy Bypass -File install-vet-skill.ps1 -AllowUpdate <full 40-char sha>
# Check what is installed on this machine WITHOUT changing anything (safe for an agent to run):
#   powershell -ExecutionPolicy Bypass -File install-vet-skill.ps1 -Status
param([string]$AllowUpdate, [switch]$Status)
$ErrorActionPreference = 'Stop'

$dest = Join-Path $HOME '.claude\skills\vet-skill'
$trustDir = Join-Path $env:LOCALAPPDATA 'vet-skill-trust'
$verifier = Join-Path $trustDir 'verify-vet-skill.ps1'
$files = 'SKILL.md', 'check-skills.ps1', 'guard-skills.ps1', 'install-vet-skill.ps1', 'verify-vet-skill.ps1', 'README.md'

# -Status: read-only report of what is installed here. Changes nothing, prompts for nothing, so
# an agent can run it safely. Use it INSTEAD of eyeballing the file layout to decide whether
# vet-skill is installed - the layout changed across versions (older installs have no trust
# anchor and a direct guard-skills.ps1 hook), and guessing from it has produced false "vet-skill
# isn't installed" reads that derail updates. The installer keys "is this an update?" off the
# SAME check used here (SKILL.md at $dest), so this report is authoritative, not a heuristic.
if ($Status) {
    $skillInstalled = Test-Path (Join-Path $dest 'SKILL.md')
    Write-Host 'vet-skill status'
    Write-Host '================'
    Write-Host ("Skill folder : {0}" -f $(if ($skillInstalled) { "INSTALLED  ($dest)" } else { "not found  ($dest)" }))
    Write-Host ("Trust anchor : {0}" -f $(if (Test-Path $verifier) { "present    ($verifier)" } else { "MISSING    ($verifier)" }))
    # Guard hook: mirror step 6's classification - verifier-routed (current) vs direct guard-skills.ps1 (legacy).
    $settingsFile = Join-Path $HOME '.claude\settings.json'
    $hookState = 'none'
    if (Test-Path $settingsFile) {
        try {
            $s = Get-Content $settingsFile -Raw | ConvertFrom-Json
            foreach ($entry in @($s.hooks.PreToolUse)) {
                foreach ($h in @($entry.hooks)) {
                    if ($h.command -like '*verify-vet-skill.ps1*') { $hookState = 'verifier-routed (current)' }
                    elseif ($h.command -like '*guard-skills.ps1*' -and $hookState -eq 'none') { $hookState = 'legacy (direct guard-skills.ps1)' }
                }
            }
        } catch { $hookState = "unreadable ($settingsFile)" }
    }
    Write-Host ("Guard hook   : {0}" -f $hookState)
    Write-Host ''
    if ($skillInstalled) {
        Write-Host 'vet-skill IS installed. To update to a reviewed commit, from a git clone checked out at that commit:'
        Write-Host '  install-vet-skill.ps1 -AllowUpdate <full 40-char sha>'
        if (-not (Test-Path $verifier) -or $hookState -like 'legacy*') {
            Write-Host 'This install predates the self-protection hardening (no trust anchor and/or a legacy hook); the update above installs it.'
        }
    } else {
        Write-Host 'vet-skill is NOT installed. For a first install, from a checkout you have read:'
        Write-Host '  install-vet-skill.ps1'
    }
    exit 0
}

# 1. Copy the skill into this user's Claude Code skills directory.
#    An existing install is only overwritten when -AllowUpdate names the exact commit
#    checked out here - a compromised repo can't ride in on a casual re-run, and the
#    human asserts "I read the diff at this SHA" every time. Zip archives can't prove
#    which commit they contain, so updates require a git clone (first install is
#    trust-on-first-use either way - you read the files, that IS the review).
$isUpdate = (Test-Path (Join-Path $dest 'SKILL.md')) -and ($PSScriptRoot -ine $dest)
if ($PSScriptRoot -ieq $dest) {
    Write-Host "Already running from $dest - skill files not copied."
} elseif ($isUpdate -and -not $AllowUpdate) {
    Write-Error "vet-skill is already installed. Updates must name the exact reviewed commit: install-vet-skill.ps1 -AllowUpdate <full sha>. Read the diff since your pinned version first (verify-vet-skill.ps1 shows the pinned commit), then take the sha from 'git rev-parse HEAD' in the clone you reviewed."
} elseif ($isUpdate) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Error 'Updates require git so the commit can be verified (zip archives cannot prove which commit they contain). Install git and update from a git clone.'
    }
    $head = & git -C $PSScriptRoot rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or -not $head) { Write-Error 'This folder is not a git checkout - updates must come from a git clone so the commit can be verified.' }
    if ($head -ine $AllowUpdate) { Write-Error "Checkout is at commit $head but -AllowUpdate says $AllowUpdate. Refusing - check out exactly the commit you reviewed." }
    $dirty = & git -C $PSScriptRoot status --porcelain -- $files
    if ($dirty) { Write-Error "Working tree differs from commit $head (local modifications: $($dirty -join '; ')). Refusing to install content that isn't the reviewed commit." }
    Copy-Item ($files | ForEach-Object { Join-Path $PSScriptRoot $_ }) $dest -Force
    Write-Host "Updated $dest to reviewed commit $AllowUpdate"
} else {
    New-Item -ItemType Directory -Force $dest | Out-Null
    Copy-Item ($files | ForEach-Object { Join-Path $PSScriptRoot $_ }) $dest -Force
    Write-Host "Skill installed to $dest"
}

# 2. Out-of-repo trust anchor: the verifier lives OUTSIDE the skill folder and is never
#    overwritten by updates - a compromised repo can't neuter the thing that checks it.
#    The guard hook and the weekly task (steps 5 and 6) enter through this script only.
New-Item -ItemType Directory -Force $trustDir | Out-Null
$verifierSrc = Join-Path $PSScriptRoot 'verify-vet-skill.ps1'
if (-not (Test-Path $verifier)) {
    Copy-Item $verifierSrc $verifier
    Write-Host "Integrity verifier installed to $verifier (outside the repo's update path)."
} elseif ((Get-FileHash $verifier -Algorithm SHA256).Hash -ne (Get-FileHash $verifierSrc -Algorithm SHA256).Hash) {
    Write-Warning "This checkout ships a DIFFERENT verify-vet-skill.ps1 than your pinned copy at $verifier. The pinned copy stays in charge. If you reviewed the new one and want it, copy it yourself:"
    Write-Warning "  Copy-Item `"$verifierSrc`" `"$verifier`" -Force"
}

# 3. Pin the just-installed files as the known-good reference. Interactive on purpose:
#    typing APPROVE is the human asserting they reviewed exactly this content, and an
#    agent-driven session (no interactive stdin) cannot complete it.
if ($AllowUpdate) { & $verifier -ApproveSelf -PinnedCommit $AllowUpdate } else { & $verifier -ApproveSelf }
if ($LASTEXITCODE -ne 0) {
    Write-Warning 'Trust store NOT pinned - the guard hook and weekly check will refuse to run vet-skill scripts until you run:'
    Write-Warning "  powershell -File `"$verifier`" -ApproveSelf"
}

# 4. Install the automated scanner (needs Python 3.10+)
$pip = Get-Command pip -ErrorAction SilentlyContinue
if ($pip) {
    pip install --upgrade cisco-ai-skill-scanner
    # pip's Scripts dir is often not on PATH on Windows - add it so skill-scanner resolves
    if (-not (Get-Command skill-scanner -ErrorAction SilentlyContinue)) {
        $scripts = Join-Path (Split-Path (python -c "import sys; print(sys.executable)")) 'Scripts'
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ((Test-Path (Join-Path $scripts 'skill-scanner.exe')) -and $userPath -notlike "*$scripts*") {
            [Environment]::SetEnvironmentVariable('Path', "$userPath;$scripts", 'User')
            Write-Host "Added $scripts to your PATH (takes effect in new terminals)."
        }
    }
    Write-Host 'Cisco skill-scanner installed.'
} else {
    Write-Warning 'pip not found. Install Python 3.10+ from python.org, then run: pip install cisco-ai-skill-scanner'
    Write-Warning 'The skill still works without it - Claude falls back to manual review.'
}

# 5. Full audit - nothing is trusted blindly. Runs on first install AND on updates,
# so newly covered surfaces (plugins, cowork skills) get audited immediately.
# Every unvetted unit gets the scanner + Claude review. NOTHING is auto-approved:
# the report lists ready-to-paste approve commands for units with SAFE verdicts,
# and a human runs them after reading. (vet-skill itself was just pinned in step 3
# by -ApproveSelf, which also writes its baseline.json entry.)
if (Get-Command claude -ErrorAction SilentlyContinue) {
    Write-Host 'Auditing unvetted skills/plugins (scanner + Claude review per unit - first run can take a while)...'
    & (Join-Path $dest 'check-skills.ps1')
    Write-Host 'Read the report, then approve units you accept (approve commands are listed in it). To skip auditing and trust everything instead: check-skills.ps1 -Baseline'
} else {
    Write-Warning 'claude CLI not found - existing skills are NOT vetted. Ask Claude to "audit my skills" in a Claude Code session, then approve them, or run: check-skills.ps1 -Baseline to trust them as-is.'
}

# 6. Guard hook: block Claude from writing into unvetted skill folders. Routed through
# the out-of-repo verifier, which confirms vet-skill's own integrity (and hard-locks
# vet-skill's folder) before letting the repo-shipped guard logic run.
$settingsFile = Join-Path $HOME '.claude\settings.json'
$hookCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$verifier`" -Hook"
$settings = if (Test-Path $settingsFile) { Get-Content $settingsFile -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
$alreadyHooked = $false
$removedLegacy = $false
if ($settings.hooks -and $settings.hooks.PreToolUse) {
    $kept = @()
    foreach ($entry in $settings.hooks.PreToolUse) {
        $isLegacy = $false
        foreach ($h in $entry.hooks) {
            if ($h.command -like '*verify-vet-skill.ps1*') { $alreadyHooked = $true }
            elseif ($h.command -like '*guard-skills.ps1*') { $isLegacy = $true }
        }
        if ($isLegacy) { $removedLegacy = $true } else { $kept += $entry }
    }
    $settings.hooks.PreToolUse = $kept
}
if ($alreadyHooked -and -not $removedLegacy) {
    Write-Host 'Guard hook already configured (via verifier).'
} else {
    if (Test-Path $settingsFile) { Copy-Item $settingsFile "$settingsFile.bak" -Force }
    if (-not $alreadyHooked) {
        $hookEntry = [pscustomobject]@{
            matcher = 'Write|Edit'
            hooks   = @([pscustomobject]@{ type = 'command'; command = $hookCmd; timeout = 15; statusMessage = 'Checking vetted-skill baseline' })
        }
        if (-not $settings.hooks) { $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) }
        if (-not $settings.hooks.PreToolUse) { $settings.hooks | Add-Member -NotePropertyName PreToolUse -NotePropertyValue @() -Force }
        $settings.hooks.PreToolUse = @($settings.hooks.PreToolUse) + $hookEntry
    }
    $settings | ConvertTo-Json -Depth 20 | Set-Content $settingsFile -Encoding utf8
    if ($removedLegacy) { Write-Host "Guard hook re-pointed through the integrity verifier (old direct guard-skills.ps1 hook removed; backup at $settingsFile.bak)." }
    else { Write-Host "Guard hook added to $settingsFile (backup at $settingsFile.bak). Restart Claude Code sessions to activate." }
}

# 7. Weekly drift check: flags skills installed or changed without vetting. Also routed
# through the verifier - if vet-skill's own files drifted, the check does NOT run and
# an alarm (with a diff against the known-good copies) is written instead.
# -StartWhenAvailable is why we use Register-ScheduledTask instead of schtasks: without it
# a run missed because the machine was off/asleep at 09:00 Monday is silently skipped until
# the NEXT Monday. With it, the missed run fires shortly after the machine is next available.
$taskArgs     = "-NoProfile -ExecutionPolicy Bypass -File `"$verifier`" -Task"
$taskAction   = New-ScheduledTaskAction -Execute 'powershell' -Argument $taskArgs
$taskTrigger  = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At '09:00'
$taskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable
Register-ScheduledTask -TaskName 'vet-skill-weekly-check' -Action $taskAction -Trigger $taskTrigger -Settings $taskSettings -Force | Out-Null
Write-Host 'Weekly drift check scheduled (Mondays 9:00; a run missed while the machine was off runs at next startup), gated by the integrity verifier. Reports land in skills\vet-skill\reports\, alarms in the trust folder.'

Write-Host ''
Write-Host 'Done. In Claude Code, vet any skill BEFORE installing it with:'
Write-Host '  /vet-skill <path or URL>'
