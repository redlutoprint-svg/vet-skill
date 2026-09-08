# vet-skill setup. Run once per machine; safe to re-run.
#
#   powershell -File setup.ps1
#
# Installs vet-skill as a GIT CLONE at ~\.claude\skills\vet-skill (the clone is what makes
# self-check and self-update work - see check-skills.ps1), installs the Cisco scanner,
# registers the guard hook and the deny rule that protects this tool from agent edits,
# and schedules the monthly maintenance run.
#
# Replaces install-vet-skill.ps1, which also built an out-of-repo trust store
# (verify-vet-skill.ps1 + manifest.bin + known-good copies) and pinned updates to a
# reviewed SHA behind an interactive APPROVE prompt. Git and the deny rule do that job
# now; -Migrate cleans up what the old installer left behind.
param([switch]$Migrate)
$ErrorActionPreference = 'Stop'

$repoUrl = 'https://github.com/redlutoprint-svg/vet-skill.git'
$skillsDir = Join-Path $HOME '.claude\skills'
$vetDir = Join-Path $skillsDir 'vet-skill'
$settingsFile = Join-Path $HOME '.claude\settings.json'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Error 'git is required (it is the tamper check). Install Git for Windows, then re-run.'
}
New-Item -ItemType Directory -Force $skillsDir | Out-Null

# 1. Clone or verify the checkout ------------------------------------------------
if (-not (Test-Path (Join-Path $vetDir '.git'))) {
    if (Test-Path $vetDir) {
        # An old file-copy install. Move it aside rather than deleting: baseline.json is in there.
        $stash = "$vetDir.pre-git-$(Get-Date -Format 'yyyyMMddHHmmss')"
        Move-Item $vetDir $stash
        Write-Host "Existing non-git install moved to $stash"
    }
    git clone --quiet $repoUrl $vetDir
    Write-Host "Cloned vet-skill to $vetDir"
    $stashed = Get-ChildItem (Split-Path $vetDir) -Directory -Filter 'vet-skill.pre-git-*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    if ($stashed) {
        $oldBaseline = Join-Path $stashed.FullName 'baseline.json'
        if (Test-Path $oldBaseline) {
            Copy-Item $oldBaseline (Join-Path $vetDir 'baseline.json')
            Write-Host 'Carried over your existing baseline.json (nothing needs re-vetting).'
        }
    }
} else {
    $remote = (& git -C $vetDir remote get-url origin 2>&1)
    if ($remote -notlike '*redlutoprint-svg/vet-skill*') { Write-Error "$vetDir is a git repo but its origin is '$remote', not vet-skill. Refusing to touch it." }
    Write-Host "vet-skill checkout already present at $vetDir ($(& git -C $vetDir rev-parse --short HEAD))"
}

# 2. Scanner ---------------------------------------------------------------------
if (Get-Command pip -ErrorAction SilentlyContinue) {
    Write-Host 'Installing/upgrading cisco-ai-skill-scanner...'
    pip install --upgrade cisco-ai-skill-scanner
    # pip's Scripts dir is often not on PATH on Windows - add it so skill-scanner resolves
    if (-not (Get-Command skill-scanner -ErrorAction SilentlyContinue)) {
        $scripts = Join-Path (Split-Path (Get-Command python).Source) 'Scripts'
        if (Test-Path $scripts) {
            $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
            if ($userPath -notlike "*$scripts*") {
                [Environment]::SetEnvironmentVariable('Path', "$userPath;$scripts", 'User')
                Write-Host "Added $scripts to your PATH (takes effect in new terminals)."
            }
        }
    }
} else {
    Write-Warning 'pip not found. Install Python 3.11+ from python.org, then: pip install cisco-ai-skill-scanner'
}

# 3. settings.json: guard hook + deny rule ---------------------------------------
# The deny rule is the important half. Claude Code enforces it before any hook runs, no
# session can re-allow it, and unlike a hook script it cannot itself be edited away.
# Paths are POSIX-normalized on Windows (C:\Users\me -> /c/Users/me), and '//' anchors
# at the filesystem root - a single leading slash would anchor at the settings file.
$drive = $vetDir.Substring(0, 1).ToLower()
$denyRule = "Edit(//$drive$(($vetDir.Substring(2) -replace '\\','/'))/**)"
$hookCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $vetDir 'guard-skills.ps1')`""

$settings = if (Test-Path $settingsFile) { Get-Content $settingsFile -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
if (Test-Path $settingsFile) { Copy-Item $settingsFile "$settingsFile.bak" -Force }

# Drop any previous vet-skill PreToolUse entry (old verifier-routed one, or an earlier guard)
if ($settings.hooks -and $settings.hooks.PreToolUse) {
    $kept = @($settings.hooks.PreToolUse | Where-Object {
        $isOurs = $false
        foreach ($h in $_.hooks) { if ($h.command -match 'verify-vet-skill\.ps1|guard-skills\.ps1') { $isOurs = $true } }
        -not $isOurs
    })
    $settings.hooks.PreToolUse = $kept
}
if (-not $settings.hooks) { $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force }
if (-not $settings.hooks.PreToolUse) { $settings.hooks | Add-Member -NotePropertyName PreToolUse -NotePropertyValue @() -Force }
$settings.hooks.PreToolUse = @($settings.hooks.PreToolUse) + [pscustomobject]@{
    matcher = 'Write|Edit'
    hooks   = @([pscustomobject]@{ type = 'command'; command = $hookCmd; timeout = 15; statusMessage = 'Checking vetted-skill baseline' })
}

if (-not $settings.permissions) { $settings | Add-Member -NotePropertyName permissions -NotePropertyValue ([pscustomobject]@{}) -Force }
if (-not $settings.permissions.deny) { $settings.permissions | Add-Member -NotePropertyName deny -NotePropertyValue @() -Force }
$existingDeny = @($settings.permissions.deny)
if ($existingDeny -notcontains $denyRule) {
    $settings.permissions.deny = $existingDeny + $denyRule
    Write-Host "Added deny rule: $denyRule"
} else {
    Write-Host 'Deny rule already present.'
}
$settings | ConvertTo-Json -Depth 20 | Set-Content $settingsFile -Encoding utf8
Write-Host "settings.json updated (backup at $settingsFile.bak). Restart Claude Code sessions to activate."

# 4. Monthly maintenance task ----------------------------------------------------
# -StartWhenAvailable is why this uses Register-ScheduledTask instead of schtasks: without it
# a run missed because the machine was off/asleep is silently skipped until the next month.
$taskArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $vetDir 'check-skills.ps1')`""
Register-ScheduledTask -TaskName 'vet-skill-monthly' -Force `
    -Action (New-ScheduledTaskAction -Execute 'powershell' -Argument $taskArgs) `
    -Trigger (New-ScheduledTaskTrigger -Weekly -WeeksInterval 4 -DaysOfWeek Monday -At '09:00') `
    -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable) | Out-Null
Write-Host 'Scheduled vet-skill-monthly (every 4 weeks, Mondays 09:00; a missed run fires at next startup).'

# 5. Migration cleanup -----------------------------------------------------------
$oldTask = Get-ScheduledTask -TaskName 'vet-skill-weekly-check' -ErrorAction SilentlyContinue
if ($oldTask) {
    if ($Migrate) {
        Unregister-ScheduledTask -TaskName 'vet-skill-weekly-check' -Confirm:$false
        Write-Host 'Removed the old weekly task (the monthly run does its job now).'
    } else {
        Write-Warning 'Old task vet-skill-weekly-check still exists and will duplicate this work. Re-run with -Migrate to remove it, or delete it in Task Scheduler.'
    }
}
$trustDir = Join-Path $env:LOCALAPPDATA 'vet-skill-trust'
if (Test-Path $trustDir) {
    if ($Migrate) {
        Remove-Item $trustDir -Recurse -Force
        Write-Host "Removed the old trust store at $trustDir (git + the deny rule replace it)."
    } else {
        Write-Warning "Old trust store still at $trustDir. It is no longer read by anything. Re-run with -Migrate to remove it."
    }
}

# 6. Baseline --------------------------------------------------------------------
if (Test-Path (Join-Path $vetDir 'baseline.json')) {
    Write-Host ''
    Write-Host 'Setup complete. Running a first maintenance pass...'
    & (Join-Path $vetDir 'check-skills.ps1')
} else {
    Write-Host ''
    Write-Host 'Setup complete. No baseline yet. Either:'
    Write-Host "  audit everything now:  powershell -File `"$(Join-Path $vetDir 'check-skills.ps1')`""
    Write-Host "  or trust what is already installed: powershell -File `"$(Join-Path $vetDir 'check-skills.ps1')`" -Baseline"
}
