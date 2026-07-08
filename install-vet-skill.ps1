# Installs the vet-skill Claude Code skill and the Cisco skill-scanner CLI.
# Run from anywhere: right-click > Run with PowerShell, or:
#   powershell -ExecutionPolicy Bypass -File install-vet-skill.ps1
$ErrorActionPreference = 'Stop'

# 1. Copy the skill into this user's Claude Code skills directory
$dest = Join-Path $HOME '.claude\skills\vet-skill'
if ($PSScriptRoot -ieq $dest) {
    Write-Host "Already running from $dest - skill is in place."
} else {
    New-Item -ItemType Directory -Force $dest | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'SKILL.md') $dest -Force
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

Write-Host ''
Write-Host 'Done. In Claude Code, vet any skill BEFORE installing it with:'
Write-Host '  /vet-skill <path or URL>'
