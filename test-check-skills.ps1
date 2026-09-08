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

# --- 5. guard hook asks (does not hard-block) ------------------------------------
# The hook's contract is stdin JSON in, decision JSON out. Pipe-test it directly.
$guard = Join-Path $PSScriptRoot 'guard-skills.ps1'
$errs5 = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($guard, [ref]$null, [ref]$errs5)
Check 'guard-skills.ps1 parses' (-not $errs5) "$($errs5 | Select-Object -First 3)"

function Invoke-Guard($path) {
    $payload = @{ tool_input = @{ file_path = $path } } | ConvertTo-Json -Compress
    $out = $payload | & powershell -NoProfile -File $guard 2>&1 | Out-String
    [pscustomobject]@{ Out = $out; Code = $LASTEXITCODE }
}

$g1 = Invoke-Guard (Join-Path $skills 'brand-new-skill\SKILL.md')
Check 'guard exits 0 for an unvetted skill (no hard block)' ($g1.Code -eq 0) "exit code was $($g1.Code)"
Check 'guard asks rather than denies' ($g1.Out -match '"permissionDecision"\s*:\s*"ask"') "guard emitted: $($g1.Out.Trim())"
Check 'guard names the offending skill' ($g1.Out -match 'brand-new-skill') "guard emitted: $($g1.Out.Trim())"

$g2 = Invoke-Guard (Join-Path $skills 'vet-skill\SKILL.md')
Check 'guard stays silent for a baselined skill' ($g2.Out -notmatch 'permissionDecision') "guard emitted: $($g2.Out.Trim())"

$g3 = Invoke-Guard (Join-Path $fake 'some\other\project\file.txt')
Check 'guard ignores paths outside the skills dir' ($g3.Out -notmatch 'permissionDecision') "guard emitted: $($g3.Out.Trim())"

# --- 6. self-check and self-update over a real git remote ------------------------
# Rebuild the vet-skill fixture as a clone of a local bare repo, so the fast-forward
# path runs for real rather than being mocked.
# git chatters on stderr (CRLF notices, "cloned an empty repository"), and under
# $ErrorActionPreference='Stop' PS 5.1 promotes native stderr to a terminating error.
# Run git through a wrapper that swallows it; real failures still show up as bad state.
function Git-Quiet {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & git @args 2>&1 | Out-Null } finally { $ErrorActionPreference = $old }
}

$vetFix = Join-Path $skills 'vet-skill'
$bare   = Join-Path $work 'origin.git'
$seed   = Join-Path $work 'seed'
foreach ($p in $bare, $seed) { if (Test-Path $p) { Remove-Item $p -Recurse -Force } }
Git-Quiet init --quiet --bare $bare
Git-Quiet clone --quiet $bare $seed
Copy-Item $script (Join-Path $seed 'check-skills.ps1')
# Real frontmatter: the scanner rejects a SKILL.md with no 'name' field, which would
# make this fixture INCOMPLETE for a reason that has nothing to do with what is tested.
"---`nname: vet-skill`ndescription: fixture skill for tests`n---`nFixture." | Set-Content (Join-Path $seed 'SKILL.md')
"baseline.json`nreports/" | Set-Content (Join-Path $seed '.gitignore')
Git-Quiet -C $seed add -A
Git-Quiet -C $seed -c user.email=t@t -c user.name=t commit --quiet -m 'seed'
Git-Quiet -C $seed push --quiet origin HEAD:refs/heads/master

$oldBaseline = Get-Content (Join-Path $vetFix 'baseline.json') -Raw
Remove-Item $vetFix -Recurse -Force
Git-Quiet clone --quiet -b master $bare $vetFix
$oldBaseline | Set-Content (Join-Path $vetFix 'baseline.json')

$out6 = Run-Checker
Check 'clean checkout reports its version' ($out6 -notmatch 'LOCAL EDITS') "checker said: $($out6.Trim())"

# a commit lands upstream -> the monthly run should fast-forward onto it
'Upstream change.' | Add-Content (Join-Path $seed 'SKILL.md')
Git-Quiet -C $seed add -A
Git-Quiet -C $seed -c user.email=t@t -c user.name=t commit --quiet -m 'upstream fix'
Git-Quiet -C $seed push --quiet origin master
$out7 = Run-Checker
Check 'self-update fast-forwards from origin' ($out7 -match 'UPDATED: vet-skill') "checker said: $($out7.Trim())"
$head = (& git -C $vetFix log -1 --pretty=%s).Trim()
Check 'the update actually landed on disk' ($head -eq 'upstream fix') "HEAD subject was '$head'"
# and must not then flag itself as drifted on the very next run
$out8 = Run-Checker
Check 'updated tool does not flag itself as CHANGED' ($out8 -notmatch 'vet-skill - CHANGED') "checker said: $($out8.Trim())"

# local edits are reported but must NOT stop the audit (the old halt is gone)
'# tampered locally' | Add-Content (Join-Path $vetFix 'SKILL.md')
'# drift' | Add-Content (Join-Path $plug 'skills\alpha\SKILL.md')
$out9 = Run-Checker
Check 'local edits to vet-skill are reported' ($out9 -match 'LOCAL EDITS') "checker said: $($out9.Trim())"
Check 'audit still runs despite local edits (no halt)' ($out9 -match 'need review') "checker said: $($out9.Trim())"
$rpt9 = Get-ChildItem (Join-Path $vetFix 'reports') | Sort-Object LastWriteTime -Desc | Select-Object -First 1
Check 'other units still scanned despite local edits' ((Get-Content $rpt9.FullName -Raw) -match 'skill-scanner:') 'no scanner section - the run halted early'

Write-Host ''
if ($fails) { Write-Host "$fails FAILED"; exit 1 } else { Write-Host 'all checks passed'; exit 0 }
