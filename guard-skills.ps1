# PreToolUse hook: blocks Claude from writing files into a NEW (unvetted) skill folder.
# Skills already in baseline.json may be edited freely - the weekly drift check catches changes.
# Exception: vet-skill's OWN folder is hard-locked even though it is baselined - otherwise a
# prompt-injected session could edit this very script (or the checker) and neuter the system.
# Normally invoked THROUGH verify-vet-skill.ps1 -Hook, which confirms this file is unmodified first.
$stdin = [Console]::In.ReadToEnd()
try { $payload = $stdin | ConvertFrom-Json } catch { exit 0 }
$filePath = $payload.tool_input.file_path
if (-not $filePath) { exit 0 }

$skillsDir = (Join-Path $HOME '.claude\skills').ToLower()
$normalized = $filePath.Replace('/', '\').ToLower()
if (-not $normalized.StartsWith($skillsDir + '\')) { exit 0 }

$skillName = ($normalized.Substring($skillsDir.Length + 1) -split '\\')[0]
if (-not $skillName) { exit 0 }

if ($skillName -eq 'vet-skill') {
    [Console]::Error.WriteLine("BLOCKED: vet-skill's own folder is locked against agent edits. Legitimate updates go through the installer (install-vet-skill.ps1 -Update fetches from GitHub over HTTPS; no git needed), then the user reviews the changes and re-pins by typing APPROVE.")
    exit 2
}

$baselineFile = Join-Path $HOME '.claude\skills\vet-skill\baseline.json'
if (Test-Path $baselineFile) {
    $baseline = Get-Content $baselineFile -Raw | ConvertFrom-Json
    if ($baseline.PSObject.Properties.Name -contains $skillName) { exit 0 }
}

[Console]::Error.WriteLine("BLOCKED: '$skillName' is not in the vetted-skill baseline. Run /vet-skill on it first; after the user approves, run: powershell -File `"$HOME\.claude\skills\vet-skill\check-skills.ps1`" -Approve $skillName - then retry this write.")
exit 2
