# verify-vet-skill.ps1 - external integrity gate for vet-skill ITSELF.
#
# vet-skill vets other skills; this script is the only thing that vets vet-skill.
# The installer copies it OUTSIDE the skill folder (%LOCALAPPDATA%\vet-skill-trust\)
# and never overwrites that copy on updates, so a compromised repo update cannot
# neuter it. The weekly scheduled task and the guard hook both enter through this
# script: if any file under ~\.claude\skills\vet-skill differs from the DPAPI-sealed
# manifest pinned at the last human approval, NO vet-skill script runs - the change
# is diffed against known-good copies and a human must -ApproveSelf or -Restore.
#
# Usage:
#   verify-vet-skill.ps1                integrity check; prints the diff on mismatch
#   verify-vet-skill.ps1 -Task          gate, then run the weekly drift check
#   verify-vet-skill.ps1 -Hook          gate + self-folder lock, then the guard hook (PreToolUse stdin)
#   verify-vet-skill.ps1 -ApproveSelf [-PinnedCommit <sha>]
#                                       pin the CURRENT files as trusted (interactive: type APPROVE)
#   verify-vet-skill.ps1 -Restore       roll the skill folder back to the pinned known-good copies
param([switch]$Task, [switch]$Hook, [switch]$ApproveSelf, [switch]$Restore, [string]$PinnedCommit)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

$skillsRoot   = Join-Path $HOME '.claude\skills'
$skillDir     = Join-Path $skillsRoot 'vet-skill'
$trustDir     = Join-Path $env:LOCALAPPDATA 'vet-skill-trust'
$manifestFile = Join-Path $trustDir 'manifest.bin'
$goodDir      = Join-Path $trustDir 'known-good'

# Same exclusions as check-skills.ps1's Get-DirHashes, so baseline.json and this
# manifest always agree about which files make up the vet-skill unit.
function Get-SkillFiles {
    Get-ChildItem $skillDir -Recurse -File | Where-Object { $_.FullName -notmatch '\\\.git\\|\\reports\\|baseline\.json$' }
}
function Get-SkillHashes {
    $h = @{}
    Get-SkillFiles | ForEach-Object { $h[$_.FullName.Substring($skillDir.Length + 1)] = (Get-FileHash $_.FullName -Algorithm SHA256).Hash }
    return $h
}
# The manifest is DPAPI-sealed (CurrentUser): a script that merely writes files into
# the repo cannot forge it without also running as this user AFTER getting past this
# gate. It is NOT proof against malware already executing as the user - see README.
function Read-Manifest {
    if (-not (Test-Path $manifestFile)) { return $null }
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String((Get-Content $manifestFile -Raw).Trim()), $null, 'CurrentUser')
    return ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
}
function Save-Manifest($obj) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 5))
    [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect($bytes, $null, 'CurrentUser')) | Set-Content $manifestFile -Encoding ascii
}
# Returns $null when no manifest is pinned yet; otherwise the (possibly empty)
# list of relative paths that are changed, new, or deleted vs. the manifest.
function Get-Drift {
    $manifest = Read-Manifest
    if (-not $manifest) { return $null }
    $known = @{}
    foreach ($p in $manifest.files.PSObject.Properties) { $known[$p.Name] = $p.Value }
    $current = Get-SkillHashes
    $drift = @($current.Keys | Where-Object { -not $known.ContainsKey($_) -or $known[$_] -ne $current[$_] }) +
             @($known.Keys | Where-Object { -not $current.ContainsKey($_) })
    return ,@($drift | Sort-Object -Unique)
}
function Get-DiffText($drift) {
    $manifest = Read-Manifest
    $git = Get-Command git -ErrorAction SilentlyContinue
    $lines = @()
    foreach ($rel in $drift) {
        $good = Join-Path $goodDir $rel
        $cur  = Join-Path $skillDir $rel
        $lines += ''
        $lines += "===== $rel ====="
        $pinned = $manifest.files.PSObject.Properties[$rel]
        if (-not $pinned) {
            $lines += "NEW FILE dropped into the skill folder (not in the pinned manifest): $cur"
            if (Test-Path $cur) { $lines += @(Get-Content $cur | ForEach-Object { "+ $_" }) }
            continue
        }
        if (-not (Test-Path $cur)) { $lines += 'FILE DELETED (was present at last approval)'; continue }
        if (-not (Test-Path $good) -or (Get-FileHash $good -Algorithm SHA256).Hash -ne $pinned.Value) {
            $lines += 'WARNING: the known-good copy itself is missing or does not match the sealed manifest - cannot diff. Re-fetch the version you originally reviewed before trusting anything.'
            continue
        }
        if ($git) {
            $lines += @(& git diff --no-color --no-index -- $good $cur | ForEach-Object { $_ })
        } else {
            $lines += @(Compare-Object (Get-Content $good) (Get-Content $cur) | ForEach-Object {
                if ($_.SideIndicator -eq '=>') { "+ $($_.InputObject)" } else { "- $($_.InputObject)" }
            })
        }
    }
    return ,$lines
}
function Invoke-Alarm($drift) {
    $lines = @(
        '!!! vet-skill INTEGRITY FAILURE !!!',
        "Files in $skillDir differ from what was pinned at the last human approval:"
    ) + @($drift | ForEach-Object { "  - $_" }) + (Get-DiffText $drift) + @(
        '',
        'NO vet-skill script (drift check, scanner, guard) will run until this is resolved.',
        'If YOU made or reviewed this change, re-pin it:',
        "  powershell -File `"$PSCommandPath`" -ApproveSelf",
        'If you did NOT, treat it as a compromise and roll back to the pinned copies:',
        "  powershell -File `"$PSCommandPath`" -Restore"
    )
    $alertDir = Join-Path $trustDir 'alerts'
    New-Item -ItemType Directory -Force $alertDir | Out-Null
    $alert = Join-Path $alertDir ("alert_" + (Get-Date -Format 'yyyy-MM-dd_HHmm') + '.txt')
    $lines | Set-Content $alert -Encoding utf8
    $lines | ForEach-Object { Write-Host $_ }
    Write-Host "`nAlarm saved: $alert"
}

if ($ApproveSelf) {
    if (-not (Test-Path $skillDir)) { Write-Error "Nothing to pin: $skillDir does not exist." }
    $drift = Get-Drift
    if ($null -eq $drift) {
        Write-Host 'No trust store pinned yet - this will be the first baseline (trust-on-first-use: it is only as good as your review of these files).'
    } elseif ($drift.Count) {
        Write-Host 'You are about to TRUST the following changes to vet-skill:'
        (Get-DiffText $drift) | ForEach-Object { Write-Host $_ }
    } else {
        Write-Host 'Files already match the pinned trust store (re-pinning refreshes the timestamp/commit).'
    }
    $ans = Read-Host 'Type APPROVE to pin the current vet-skill files as trusted'
    if ($ans -cne 'APPROVE') { Write-Host 'Not approved - nothing pinned.'; exit 1 }
    New-Item -ItemType Directory -Force -Path $trustDir, $goodDir | Out-Null
    Get-ChildItem $goodDir -Recurse -File -ErrorAction SilentlyContinue | Remove-Item -Force
    $hashes = Get-SkillHashes
    foreach ($rel in $hashes.Keys) {
        $dst = Join-Path $goodDir $rel
        New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
        Copy-Item (Join-Path $skillDir $rel) $dst -Force
    }
    Save-Manifest ([pscustomobject]@{
        approvedAt   = (Get-Date -Format o)
        pinnedCommit = $(if ($PinnedCommit) { $PinnedCommit } else { $null })
        files        = $hashes
    })
    # Keep baseline.json's vet-skill entry in sync so the weekly unit check agrees.
    $baselineFile = Join-Path $skillDir 'baseline.json'
    $bl = if (Test-Path $baselineFile) { Get-Content $baselineFile -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
    $entry = [pscustomobject]@{}
    foreach ($k in $hashes.Keys) { $entry | Add-Member -NotePropertyName $k -NotePropertyValue $hashes[$k] }
    if ($bl.PSObject.Properties.Name -contains 'vet-skill') { $bl.'vet-skill' = $entry }
    else { $bl | Add-Member -NotePropertyName 'vet-skill' -NotePropertyValue $entry }
    $bl | ConvertTo-Json -Depth 5 | Set-Content $baselineFile -Encoding utf8
    Write-Host "Pinned $($hashes.Count) files. Trust store: $trustDir"
    exit 0
}

if ($Restore) {
    $manifest = Read-Manifest
    if (-not $manifest) { Write-Error 'No trust store to restore from - run -ApproveSelf on a reviewed checkout first.' }
    foreach ($p in $manifest.files.PSObject.Properties) {
        $good = Join-Path $goodDir $p.Name
        if (-not (Test-Path $good) -or (Get-FileHash $good -Algorithm SHA256).Hash -ne $p.Value) {
            Write-Error "Known-good copy for $($p.Name) is missing or does not match the sealed manifest - cannot restore safely. Re-install from a git clone pinned to your reviewed commit instead."
        }
    }
    $ans = Read-Host "Type RESTORE to overwrite $skillDir with the pinned known-good files"
    if ($ans -cne 'RESTORE') { Write-Host 'Cancelled.'; exit 1 }
    Get-SkillFiles | Where-Object { $manifest.files.PSObject.Properties.Name -notcontains $_.FullName.Substring($skillDir.Length + 1) } | Remove-Item -Force
    foreach ($p in $manifest.files.PSObject.Properties) {
        $dst = Join-Path $skillDir $p.Name
        New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
        Copy-Item (Join-Path $goodDir $p.Name) $dst -Force
    }
    Write-Host 'Restored from known-good copies. Re-run this script with no arguments - it should report OK.'
    exit 0
}

if ($Hook) {
    # PreToolUse hook entry point. Fail CLOSED for skills-dir writes: any unexpected
    # error blocks the write rather than letting an unverified guard run.
    $stdin = [Console]::In.ReadToEnd()
    try { $payload = $stdin | ConvertFrom-Json } catch { exit 0 }
    $filePath = $payload.tool_input.file_path
    if (-not $filePath) { exit 0 }
    $norm = $filePath.Replace('/', '\').ToLower()
    if (-not $norm.StartsWith($skillsRoot.ToLower() + '\')) { exit 0 }
    try {
        if ($norm.StartsWith($skillDir.ToLower() + '\')) {
            [Console]::Error.WriteLine("BLOCKED: vet-skill's own folder is locked against agent edits. Legitimate updates go through the pinned installer (install-vet-skill.ps1 -AllowUpdate <reviewed commit sha>) and are re-pinned by the user with verify-vet-skill.ps1 -ApproveSelf.")
            exit 2
        }
        $drift = Get-Drift
        if ($null -eq $drift) {
            [Console]::Error.WriteLine("BLOCKED: vet-skill has no pinned trust store yet. The user must run: powershell -File `"$PSCommandPath`" -ApproveSelf (after reviewing the install). Skill-folder writes are blocked until then.")
            exit 2
        }
        if ($drift.Count) {
            [Console]::Error.WriteLine("BLOCKED: vet-skill failed its own integrity check ($($drift -join ', ') changed since the last approval). The guard pipeline may be compromised, so ALL skill-folder writes are blocked. The user must run: powershell -File `"$PSCommandPath`" outside Claude to see the diff and resolve it.")
            exit 2
        }
    } catch {
        [Console]::Error.WriteLine("BLOCKED: vet-skill integrity verifier errored ($($_.Exception.Message)) - failing closed for skill-folder writes.")
        exit 2
    }
    # vet-skill verified - safe to run the real (repo-shipped) guard logic.
    $stdin | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $skillDir 'guard-skills.ps1')
    exit $LASTEXITCODE
}

if ($Task) {
    $drift = Get-Drift
    if ($null -eq $drift) {
        Write-Host "No trust store pinned yet - the drift check will not run. After reviewing the files in $skillDir, run:"
        Write-Host "  powershell -File `"$PSCommandPath`" -ApproveSelf"
        exit 1
    }
    if ($drift.Count) { Invoke-Alarm $drift; exit 1 }
    # Integrity confirmed - hand off to the repo-shipped weekly drift check.
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $skillDir 'check-skills.ps1')
    exit $LASTEXITCODE
}

# Default: plain integrity check.
$drift = Get-Drift
if ($null -eq $drift) {
    Write-Host "No trust store pinned yet. After reviewing the files in $skillDir, run:"
    Write-Host "  powershell -File `"$PSCommandPath`" -ApproveSelf"
    exit 1
}
if (-not $drift.Count) {
    $m = Read-Manifest
    Write-Host "OK: vet-skill matches the pinned trust store (approved $($m.approvedAt), commit $(if ($m.pinnedCommit) { $m.pinnedCommit } else { 'unpinned' }))."
    exit 0
}
Invoke-Alarm $drift
exit 1
