<#
.SYNOPSIS
    Stops and removes the FilesZipWatcher scheduled task.

.PARAMETER KeepLogs
    Leave %LOCALAPPDATA%\FilesZipWatcher\logs in place (default is to keep them; pass
    -PurgeLogs to delete).

.PARAMETER PurgeLogs
    Also delete the log directory.
#>
[CmdletBinding()]
param([switch]$PurgeLogs)

$ErrorActionPreference = 'Stop'
$TaskName = 'FilesZipWatcher'

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed scheduled task '$TaskName'." -ForegroundColor Green
} else {
    Write-Host "Task '$TaskName' was not registered -- nothing to remove." -ForegroundColor Yellow
}

# Belt and braces: kill any watcher process still holding the single-instance mutex.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'FilesZipWatcher\.ps1' } |
    ForEach-Object {
        Write-Host "  stopping stray watcher process PID $($_.ProcessId)"
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

if ($PurgeLogs) {
    $logDir = [Environment]::ExpandEnvironmentVariables('%LOCALAPPDATA%\FilesZipWatcher')
    if (Test-Path $logDir) {
        Remove-Item $logDir -Recurse -Force
        Write-Host "Purged logs: $logDir" -ForegroundColor Green
    }
} else {
    Write-Host "Logs retained. Pass -PurgeLogs to delete them."
}

Write-Host ""
Write-Host "Nothing else was changed -- this tool only ever created a scheduled task and log files."
