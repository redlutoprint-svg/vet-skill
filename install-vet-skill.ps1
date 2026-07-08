# Installs the vet-skill Claude Code skill, the Cisco skill-scanner CLI,
# the unvetted-skill guard hook, and the weekly drift-check scheduled task.
# Run from anywhere: right-click > Run with PowerShell, or:
#   powershell -ExecutionPolicy Bypass -File install-vet-skill.ps1
$ErrorActionPreference = 'Stop'

# 1. Copy the skill into this user's Claude Code skills directory
$dest = Join-Path $HOME '.claude\skills\vet-skill'
if ($PSScriptRoot -ieq $dest) {
    Write-Host "Already running from $dest - skill is in place."
} else {
    New-Item -ItemType Directory -Force $dest | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'SKILL.md'), (Join-Path $PSScriptRoot 'check-skills.ps1'), (Join-Path $PSScriptRoot 'guard-skills.ps1') $dest -Force
    Write-Host "Skill installed to $dest"
}

# 2. Install the automated scanner (needs Python 3.10+)
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

# 3. Full audit - nothing is trusted blindly. Runs on first install AND on updates,
# so newly covered surfaces (plugins, cowork skills) get audited immediately.
# Every unvetted unit gets the scanner + Claude review. NOTHING is auto-approved:
# the report lists ready-to-paste approve commands for units with SAFE verdicts,
# and a human runs them after reading.
$baseline = Join-Path $dest 'baseline.json'
if (-not (Test-Path $baseline)) {
    # vet-skill itself is the trust anchor - you just reviewed and ran it
    & (Join-Path $dest 'check-skills.ps1') -Approve 'vet-skill'
}
if (Get-Command claude -ErrorAction SilentlyContinue) {
    Write-Host 'Auditing unvetted skills/plugins (scanner + Claude review per unit - first run can take a while)...'
    & (Join-Path $dest 'check-skills.ps1')
    Write-Host 'Read the report, then approve units you accept (approve commands are listed in it). To skip auditing and trust everything instead: check-skills.ps1 -Baseline'
} else {
    Write-Warning 'claude CLI not found - existing skills are NOT vetted. Ask Claude to "audit my skills" in a Claude Code session, then approve them, or run: check-skills.ps1 -Baseline to trust them as-is.'
}

# 4. Guard hook: block Claude from writing into unvetted skill folders
$settingsFile = Join-Path $HOME '.claude\settings.json'
$hookCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$dest\guard-skills.ps1`""
$settings = if (Test-Path $settingsFile) { Get-Content $settingsFile -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
$alreadyHooked = $false
if ($settings.hooks -and $settings.hooks.PreToolUse) {
    foreach ($entry in $settings.hooks.PreToolUse) {
        foreach ($h in $entry.hooks) { if ($h.command -like '*guard-skills.ps1*') { $alreadyHooked = $true } }
    }
}
if ($alreadyHooked) {
    Write-Host 'Guard hook already configured.'
} else {
    if (Test-Path $settingsFile) { Copy-Item $settingsFile "$settingsFile.bak" -Force }
    $hookEntry = [pscustomobject]@{
        matcher = 'Write|Edit'
        hooks   = @([pscustomobject]@{ type = 'command'; command = $hookCmd; timeout = 15; statusMessage = 'Checking vetted-skill baseline' })
    }
    if (-not $settings.hooks) { $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) }
    if (-not $settings.hooks.PreToolUse) { $settings.hooks | Add-Member -NotePropertyName PreToolUse -NotePropertyValue @() }
    $settings.hooks.PreToolUse = @($settings.hooks.PreToolUse) + $hookEntry
    $settings | ConvertTo-Json -Depth 20 | Set-Content $settingsFile -Encoding utf8
    Write-Host "Guard hook added to $settingsFile (backup at $settingsFile.bak). Restart Claude Code sessions to activate."
}

# 5. Weekly drift check: flags skills installed or changed without vetting
schtasks /Create /TN "vet-skill-weekly-check" /TR "powershell -NoProfile -ExecutionPolicy Bypass -File \`"$dest\check-skills.ps1\`"" /SC WEEKLY /D MON /ST 09:00 /F | Out-Null
Write-Host 'Weekly drift check scheduled (Mondays 9:00). Reports land in skills\vet-skill\reports\.'

Write-Host ''
Write-Host 'Done. In Claude Code, vet any skill BEFORE installing it with:'
Write-Host '  /vet-skill <path or URL>'
