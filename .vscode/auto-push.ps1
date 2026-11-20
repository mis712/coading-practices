$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location -LiteralPath $repoRoot

$branch = (& git branch --show-current).Trim()
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to determine the current Git branch.'
}
if ($branch -ne 'main') {
    throw "Auto-push is configured for main, but the current branch is '$branch'."
}

& git remote get-url origin *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Git remote 'origin' is not configured."
}

$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $repoRoot
$watcher.Filter = '*'
$watcher.IncludeSubdirectories = $true
$watcher.NotifyFilter = [IO.NotifyFilters]::FileName -bor [IO.NotifyFilters]::LastWrite -bor [IO.NotifyFilters]::DirectoryName
$watcher.InternalBufferSize = 65536

$sourcePrefix = 'AutoPushWatcher'
$eventNames = @('Changed', 'Created', 'Deleted', 'Renamed', 'Error')
foreach ($eventName in $eventNames) {
    Register-ObjectEvent -InputObject $watcher -EventName $eventName -SourceIdentifier "$sourcePrefix.$eventName" | Out-Null
}

$watcher.EnableRaisingEvents = $true
Write-Output "Auto-push watcher starting for $repoRoot"
Write-Output 'Auto-push watcher ready'

$pendingCommit = $false
$lastChange = [DateTime]::MinValue
$pushPending = $true
$retryAt = [DateTime]::MinValue

try {
    while ($true) {
        foreach ($watchEvent in @(Get-Event)) {
            if ($watchEvent.SourceIdentifier -notlike "$sourcePrefix.*") {
                continue
            }

            if ($watchEvent.SourceIdentifier -eq "$sourcePrefix.Error") {
                Write-Host '[ERROR] File watcher reported an error; checking the workspace for changes.'
                Remove-Event -EventIdentifier $watchEvent.EventIdentifier
                $pendingCommit = $true
                $lastChange = Get-Date
                continue
            }

            $fullPath = $watchEvent.SourceEventArgs.FullPath
            Remove-Event -EventIdentifier $watchEvent.EventIdentifier

            if ([string]::IsNullOrWhiteSpace($fullPath)) {
                continue
            }

            $relativePath = $fullPath.Substring($repoRoot.Length).TrimStart([char[]]@(92, 47))
            if ($relativePath -match '(^|[\\/])\.git([\\/]|$)') {
                continue
            }

            $pendingCommit = $true
            $lastChange = Get-Date
        }

        if ($pendingCommit -and ((Get-Date) - $lastChange).TotalSeconds -ge 2) {
            $pendingCommit = $false
            & git add --all
            if ($LASTEXITCODE -ne 0) {
                Write-Host '[ERROR] git add failed; the watcher will check again after another file change.'
            }
            else {
                & git diff --cached --quiet
                $diffExitCode = $LASTEXITCODE

                if ($diffExitCode -eq 1) {
                    $message = 'Auto-save: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                    & git commit -m $message
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host '[INFO] Changes committed; pushing to origin/main.'
                        $pushPending = $true
                        $retryAt = Get-Date
                    }
                    else {
                        Write-Host '[ERROR] Automatic commit failed. Review the terminal output and save a file again to retry.'
                    }
                }
                elseif ($diffExitCode -gt 1) {
                    Write-Host '[ERROR] Unable to inspect staged changes.'
                }
                else {
                    Write-Host '[INFO] No Git changes to commit.'
                }
            }
        }

        if ($pushPending -and (Get-Date) -ge $retryAt) {
            & git push origin main
            if ($LASTEXITCODE -eq 0) {
                Write-Host '[INFO] origin/main is up to date.'
                $pushPending = $false
            }
            else {
                Write-Host '[ERROR] Push failed; GitHub was not updated. Retrying in 30 seconds.'
                $retryAt = (Get-Date).AddSeconds(30)
            }
        }

        Start-Sleep -Milliseconds 250
    }
}
finally {
    $watcher.EnableRaisingEvents = $false
    foreach ($eventName in $eventNames) {
        Unregister-Event -SourceIdentifier "$sourcePrefix.$eventName" -ErrorAction SilentlyContinue
    }
    $watcher.Dispose()
}
