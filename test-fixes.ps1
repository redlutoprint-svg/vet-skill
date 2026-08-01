# End-to-end test of the report writer, the -AllowUpdate guard, and the manifest seal.
# Everything runs against a throwaway HOME/LOCALAPPDATA/APPDATA under %TEMP%: this touches
# nothing in the real ~\.claude or %LOCALAPPDATA%\vet-skill-trust, so it is safe to run from
# a clone before installing. Run it from the checkout: powershell -File test-fixes.ps1
$ErrorActionPreference = 'Stop'
$src     = $PSScriptRoot
$sandbox = Join-Path $env:TEMP 'vet-skill-selftest'
$fakeHome  = Join-Path $sandbox 'home'
$fakeLocal = Join-Path $sandbox 'local'
# APPDATA too: Get-Units reads cowork skills from %APPDATA%, and the real one has 17 of them -
# left unfaked, check-skills.ps1 flags every one and fires the scanner + headless claude at them.
$fakeApp   = Join-Path $sandbox 'appdata'
$fakeSkill = Join-Path $fakeHome '.claude\skills\vet-skill'

if (Test-Path $sandbox) { Remove-Item $sandbox -Recurse -Force }
New-Item -ItemType Directory -Force -Path $fakeSkill, $fakeLocal, $fakeApp | Out-Null
Copy-Item (Join-Path $src '*.ps1') $fakeSkill
Copy-Item (Join-Path $src '*.md')  $fakeSkill

$pass = 0; $fail = 0
function Check($name, $cond, $detail) {
    if ($cond) { Write-Host "  PASS  $name"; $script:pass++ }
    else { Write-Host "  FAIL  $name"; if ($detail) { Write-Host "        $detail" }; $script:fail++ }
}
# Run a script in a child powershell with the fake environment, optionally feeding stdin.
function Run($file, $argList, $stdin) {
    $ps = "`$env:USERPROFILE='$fakeHome'; `$env:LOCALAPPDATA='$fakeLocal'; `$env:APPDATA='$fakeApp'; " +
          "& powershell -NoProfile -ExecutionPolicy Bypass -File '$file' $argList 2>&1 | Out-String"
    if ($stdin) { return ($stdin | powershell -NoProfile -Command $ps | Out-String) }
    return (powershell -NoProfile -Command $ps | Out-String)
}

Write-Host "`n=== #2: -AllowUpdate from the installed path must hard-error ==="
$out = Run (Join-Path $fakeSkill 'install-vet-skill.ps1') '-AllowUpdate 7d0a6255d45de07a1e9a5abaa1f041d8fd78020a'
Check 'errors instead of silently no-opping' ($out -match 'requires running from a git clone') $out.Trim()
Check 'does NOT print the old "not copied" no-op line' ($out -notmatch 'skill files not copied') $out.Trim()
Check 'never reached the trust-pin step' (-not (Test-Path (Join-Path $fakeLocal 'vet-skill-trust'))) 'trust dir was created - it should not have been'

Write-Host "`n=== #2 control: -Status still works read-only ==="
$out = Run (Join-Path $fakeSkill 'install-vet-skill.ps1') '-Status'
Check '-Status reports INSTALLED' ($out -match 'Skill folder : INSTALLED') $out.Trim()

Write-Host "`n=== #3: -ApproveSelf seals the manifest via temp+rename ==="
$verifier = Join-Path $fakeSkill 'verify-vet-skill.ps1'
$out = Run $verifier '-ApproveSelf' 'APPROVE'
$manifest = Join-Path $fakeLocal 'vet-skill-trust\manifest.bin'
Check 'approve succeeded' ($out -match 'Pinned \d+ files') $out.Trim()
Check 'manifest.bin exists' (Test-Path $manifest)
Check 'no .tmp left behind' (-not (Test-Path "$manifest.tmp"))
Check 'baseline.json got the vet-skill entry' (Test-Path (Join-Path $fakeSkill 'baseline.json'))

Write-Host "`n=== #3: clean integrity check reads OK ==="
$out = Run $verifier ''
Check 'reports OK against the pinned store' ($out -match 'OK: vet-skill matches the pinned trust store') $out.Trim()

Write-Host "`n=== #3: real drift still alarms with a diff (unchanged behaviour) ==="
Add-Content (Join-Path $fakeSkill 'guard-skills.ps1') "`n# tampered"
$out = Run $verifier ''
Check 'alarm fires' ($out -match 'INTEGRITY FAILURE') $out.Trim()
Check 'shows a real diff, not the cannot-diff warning' ($out -match '(?m)^\+# tampered' -and $out -notmatch 'cannot diff') $out.Trim()

Write-Host "`n=== #3: interrupted -ApproveSelf is named, not reported as tampering ==="
# Simulate: known-good repopulated with the new file, manifest never re-sealed.
Copy-Item (Join-Path $fakeSkill 'guard-skills.ps1') (Join-Path $fakeLocal 'vet-skill-trust\known-good\guard-skills.ps1') -Force
$out = Run $verifier ''
Check 'says interrupted approve' ($out -match 'interrupted before the manifest was written') $out.Trim()
Check 'does NOT print the tamper-style warning' ($out -notmatch 'Re-fetch the version you originally reviewed') $out.Trim()

Write-Host "`n=== #3: genuinely stale known-good still warns ==="
Set-Content (Join-Path $fakeLocal 'vet-skill-trust\known-good\guard-skills.ps1') 'something else entirely'
$out = Run $verifier ''
Check 'keeps the suspicious-case warning' ($out -match 'Re-fetch the version you originally reviewed') $out.Trim()

Write-Host "`n=== #1: check-skills.ps1 writes a complete report in one pass ==="
# Fake home has one unit (vet-skill), already baselined by -ApproveSelf above. Restore it
# first so the self-check passes and we exercise the clean OK exit path.
Copy-Item (Join-Path $src 'guard-skills.ps1') (Join-Path $fakeSkill 'guard-skills.ps1') -Force
$out = Run (Join-Path $fakeSkill 'check-skills.ps1') ''
$reports = @(Get-ChildItem (Join-Path $fakeSkill 'reports') -Filter 'check_*.txt' -ErrorAction SilentlyContinue)
Check 'clean run reports OK' ($out -match 'OK: all \d+ units match baseline') $out.Trim()
Check 'exactly one report written' ($reports.Count -eq 1) "found $($reports.Count)"
if ($reports.Count) {
    $body = Get-Content $reports[0].FullName -Raw
    Check 'report has the header line' ($body -match 'vet-skill drift check - ')
    Check 'report has the OK line' ($body -match 'units match the vetted baseline')
}

Write-Host "`n=== #1: repeated runs never hit the Add-Content flakiness ==="
$errs = 0
1..8 | ForEach-Object {
    $o = Run (Join-Path $fakeSkill 'check-skills.ps1') ''
    if ($o -match 'Add-Content|Stream was not readable|being used by another process') { $errs++; Write-Host $o }
}
Check '8 consecutive runs, no writer errors' ($errs -eq 0) "$errs run(s) errored"

Write-Host "`n--------------------------------"
Write-Host "PASS: $pass   FAIL: $fail"
if ($fail) { exit 1 }
