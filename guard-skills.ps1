# PreToolUse hook: blocks Claude from writing files into a NEW (unvetted) skill folder.
# Skills already in baseline.json may be edited freely - the weekly drift check catches changes.
$stdin = [Console]::In.ReadToEnd()
try { $payload = $stdin | ConvertFrom-Json } catch { exit 0 }
$filePath = $payload.tool_input.file_path
if (-not $filePath) { exit 0 }

$skillsDir = (Join-Path $HOME '.claude\skills').ToLower()
$normalized = $filePath.Replace('/', '\').ToLower()
if (-not $normalized.StartsWith($skillsDir + '\')) { exit 0 }

$skillName = ($normalized.Substring($skillsDir.Length + 1) -split '\\')[0]
if (-not $skillName) { exit 0 }

$baselineFile = Join-Path $HOME '.claude\skills\vet-skill\baseline.json'
if (Test-Path $baselineFile) {
    $baseline = Get-Content $baselineFile -Raw | ConvertFrom-Json
    if ($baseline.PSObject.Properties.Name -contains $skillName) { exit 0 }
}

[Console]::Error.WriteLine("BLOCKED: '$skillName' is not in the vetted-skill baseline. Run /vet-skill on it first; after the user approves, run: powershell -File `"$HOME\.claude\skills\vet-skill\check-skills.ps1`" -Approve $skillName - then retry this write.")
exit 2
