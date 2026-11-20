$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location -LiteralPath $repoRoot

$branch = (& git branch --show-current).Trim()
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to determine the current Git branch.'
}
if ($branch -ne 'main') {
    throw "Push is configured for main, but the current branch is '$branch'."
}

& git remote get-url origin *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Git remote 'origin' is not configured."
}

& git add --all
if ($LASTEXITCODE -ne 0) {
    throw 'git add failed; changes were not pushed.'
}

& git diff --cached --quiet
$diffExitCode = $LASTEXITCODE
if ($diffExitCode -eq 1) {
    $message = 'Auto-push: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    & git commit -m $message
    if ($LASTEXITCODE -ne 0) {
        throw 'Automatic commit failed; changes were not pushed.'
    }
}
elseif ($diffExitCode -gt 1) {
    throw 'Unable to inspect staged changes; changes were not pushed.'
}
else {
    Write-Output 'No uncommitted changes to commit.'
}

& git push origin main
if ($LASTEXITCODE -ne 0) {
    throw 'Push failed; GitHub was not updated.'
}
