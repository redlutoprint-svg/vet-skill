# PreToolUse hook: intercepts Claude writing files into a skill folder that was never vetted.
# Skills already in baseline.json may be edited freely - the monthly drift check catches changes.
#
# This ASKS, it does not block. It used to `exit 2` (hard block), which meant every legitimate
# "help me write a new skill" session died and sent you to another terminal to run -Approve
# before you could continue. permissionDecision:"ask" gets the same interception - nothing is
# written without you seeing it - while letting you say yes inline.
#
# vet-skill's OWN folder is no longer special-cased here. It is protected by the
# permissions.deny rule in settings.json, which Claude Code enforces before any hook runs,
# cannot be re-allowed by a session, and does not depend on this script existing.
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

$reason = "'$skillName' is not in the vetted-skill baseline. If you are authoring it yourself, allow this. If Claude is installing something you did not vet, deny and run /vet-skill on it first. Once you are happy with it: check-skills.ps1 -Approve $skillName"
@{
    hookSpecificOutput = @{
        hookEventName            = 'PreToolUse'
        permissionDecision       = 'ask'
        permissionDecisionReason = $reason
    }
} | ConvertTo-Json -Depth 5 -Compress
exit 0
