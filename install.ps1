<#
.SYNOPSIS
    Registers FilesZipWatcher as an always-running Scheduled Task.

.DESCRIPTION
    Default (NO admin required): a task that starts at logon, runs continuously in your user
    session, and restarts itself if it ever dies. This is the right scope for watching a
    Downloads folder -- Chrome only downloads while you are logged in.

    -AtBoot (REQUIRES an elevated shell): adds an AtStartup trigger and runs whether or not
    you are logged on. Only useful if something other than your interactive session drops
    files into the watch folder.

.PARAMETER Restart
    Re-register and restart the task (use after editing config.json).

.PARAMETER AtBoot
    Also trigger at system startup, running whether logged on or not. Needs elevation.

.EXAMPLE
    .\install.ps1
    .\install.ps1 -Restart
    .\install.ps1 -AtBoot        # from an elevated PowerShell
#>
[CmdletBinding()]
param(
    [switch]$Restart,
    [switch]$AtBoot
)

$ErrorActionPreference = 'Stop'

$TaskName   = 'FilesZipWatcher'
$Root       = $PSScriptRoot
$Script     = Join-Path $Root 'src\FilesZipWatcher.ps1'
$ConfigPath = Join-Path $Root 'config.json'

if (-not (Test-Path $Script)) { throw "Watcher script not found: $Script" }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($AtBoot -and -not $isAdmin) {
    throw "-AtBoot requires an elevated PowerShell. Re-run as Administrator, or omit -AtBoot for the logon-scoped task."
}

Write-Host "Installing scheduled task '$TaskName'..." -ForegroundColor Cyan
Write-Host "  script : $Script"
Write-Host "  config : $ConfigPath"

# -WindowStyle Hidden keeps it out of the way; -ExecutionPolicy Bypass avoids policy surprises.
$psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$args   = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -ConfigPath "{1}"' -f $Script, $ConfigPath
$action = New-ScheduledTaskAction -Execute $psExe -Argument $args -WorkingDirectory $Root

$triggers = @( New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME" )
if ($AtBoot) { $triggers += New-ScheduledTaskTrigger -AtStartup }

# Keep it alive: no time limit, restart on failure, don't stop for power/idle reasons.
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -DontStopOnIdleEnd `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew `
    -StartWhenAvailable

if ($AtBoot) {
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
} else {
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
}

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Write-Host "  existing task found -- replacing" -ForegroundColor Yellow
    Stop-ScheduledTask   -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers `
    -Settings $settings -Principal $principal `
    -Description 'Watches Downloads for files.zip (Claude "Download All"), timestamps it, and extracts it in place. https://github.com/Mr-Champagne-TCM/files-zip-watcher' | Out-Null

Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 2

$t = Get-ScheduledTask -TaskName $TaskName
$i = Get-ScheduledTaskInfo -TaskName $TaskName
Write-Host ""
Write-Host "Installed." -ForegroundColor Green
Write-Host ("  State      : {0}" -f $t.State)
Write-Host ("  Last run   : {0}  (result {1})" -f $i.LastRunTime, $i.LastTaskResult)
Write-Host ("  Triggers   : {0}" -f (($t.Triggers | ForEach-Object { $_.CimClass.CimClassName }) -join ', '))
Write-Host ""
Write-Host "Logs: $([Environment]::ExpandEnvironmentVariables('%LOCALAPPDATA%\FilesZipWatcher\logs'))"
Write-Host "Stop/remove with: .\uninstall.ps1"
