# Tests the three check-skills.ps1 fixes against a scratch HOME. No framework.
$ErrorActionPreference = 'Stop'
$work   = Join-Path $env:TEMP 'vet-skill-test'
$script = Join-Path $PSScriptRoot 'check-skills.ps1'
$fake   = Join-Path $work 'fakehome'
$fails  = 0
function Check($name, $cond, $detail) {
    if ($cond) { Write-Host "PASS  $name" }
    else { Write-Host "FAIL  $name -- $detail"; $script:fails++ }
}

# --- syntax ---
$errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$errs)
Check 'parses without syntax errors' (-not $errs) "$($errs | Select-Object -First 3)"
if ($errs) { exit 1 }

# --- fixture ---
if (Test-Path $fake) { Remove-Item $fake -Recurse -Force }
$skills = Join-Path $fake '.claude\skills'
New-Item -ItemType Directory -Force (Join-Path $skills 'vet-skill') | Out-Null
Copy-Item $script (Join-Path $skills 'vet-skill\check-skills.ps1')
'# fixture' | Set-Content (Join-Path $skills 'vet-skill\SKILL.md')
$plug = Join-Path $fake '.claude\plugins\cache\mp\realplug\1.0'
New-Item -ItemType Directory -Force (Join-Path $plug 'skills\alpha') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $plug '.in_use') | Out-Null
"---`nname: alpha`ndescription: does alpha things`n---`nSummarise a file." | Set-Content (Join-Path $plug 'skills\alpha\SKILL.md')
'1111' | Set-Content (Join-Path $plug '.in_use\1111')

# $HOME is read-only inside a PS session, but it is derived from the environment at
# session start - so point the env at the fixture and let the child compute $HOME itself.
$env:USERPROFILE = $fake; $env:HOMEDRIVE = $fake.Substring(0,2); $env:HOMEPATH = $fake.Substring(2)

# A real `claude -p` can't authenticate against a redirected HOME, which would leave the
# SAFE-verdict branch untested - the exact branch these fixes change. Shim it to always
# return SAFE so the test isolates what the SCANNER layer did, which is the thing at issue.
$shim = Join-Path $work 'shim'
New-Item -ItemType Directory -Force $shim | Out-Null
"@echo off`r`necho VERDICT_SAFE`r`nexit /b 0" | Set-Content (Join-Path $shim 'claude.cmd') -Encoding ascii
$env:PATH = "$shim;$env:PATH"
function Run-Checker { & powershell -NoProfile -File $script 2>&1 | Out-String }

# --- 1. baseline everything ---
& powershell -NoProfile -File $script -Baseline | Out-Null
$baseline = Get-Content (Join-Path $skills 'vet-skill\baseline.json') -Raw
Check 'baseline excludes .in_use runtime state' ($baseline -notmatch 'in_use') 'baseline.json contains an .in_use entry'

# --- 2. new runtime-state file must NOT count as drift ---
'2222' | Set-Content (Join-Path $plug '.in_use\2222')
'3333' | Set-Content (Join-Path $plug '.in_use\3333')
$out2 = Run-Checker
Check 'new .in_use files do not flag the plugin' ($out2 -match 'OK: all') "checker output was: $($out2.Trim())"

# --- 3. real code change still flags ---
'# tampered' | Add-Content (Join-Path $plug 'skills\alpha\SKILL.md')
$out3 = Run-Checker
Check 'a real file change still flags CHANGED' ($out3 -match 'need review') "checker output was: $($out3.Trim())"
$rpt = Get-ChildItem (Join-Path $skills 'vet-skill\reports') | Sort-Object LastWriteTime -Desc | Select-Object -First 1
$body = Get-Content $rpt.FullName -Raw
Check 'plugin scan walked to skills/alpha, not the plugin root' ($body -match 'skill-scanner: .*skills\\alpha') 'no per-skill scanner section in report'
Check 'scanner produced a real findings summary' ($body -match 'Total Findings') 'scanner output had no summary'

# --- 4. a unit with no SKILL.md anywhere must be INCOMPLETE, not SAFE ---
$noskill = Join-Path $fake '.claude\plugins\cache\mp\noskill\1.0'
New-Item -ItemType Directory -Force $noskill | Out-Null
'just a readme, no skill manifest' | Set-Content (Join-Path $noskill 'README.md')
$out4 = Run-Checker
$rpt4 = Get-ChildItem (Join-Path $skills 'vet-skill\reports') | Sort-Object LastWriteTime -Desc | Select-Object -First 1
$body4 = Get-Content $rpt4.FullName -Raw
Check 'unscannable unit marked INCOMPLETE' ($body4 -match 'INCOMPLETE') 'no INCOMPLETE marker in report'
# Both units get a SAFE verdict from the shim. The scanned one earns an approve command;
# the unscannable one must not - that discrimination is the whole point of the fix.
$approveBlock = if ($body4 -match '(?s)approve each with:(.*?)(?:INCOMPLETE REVIEW|$)') { $Matches[1] } else { '' }
Check 'SAFE + scanned unit IS offered an approve command' ($approveBlock -match 'realplug') "approve block was: $($approveBlock.Trim())"
Check 'SAFE + unscannable unit is NOT offered an approve command' ($approveBlock -notmatch 'noskill') 'noskill appeared in the approve list despite an unrun scanner'
Check 'unscannable unit listed under INCOMPLETE REVIEW' ($body4 -match '(?s)INCOMPLETE REVIEW.*noskill') 'noskill missing from the INCOMPLETE block'
Check 'incomplete count surfaced on the console line' ($out4 -match 'INCOMPLETE') "console said: $($out4.Trim())"

Write-Host ''
if ($fails) { Write-Host "$fails FAILED"; exit 1 } else { Write-Host 'all checks passed'; exit 0 }
