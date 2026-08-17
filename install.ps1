<#
.SYNOPSIS
    Registers FilesZipWatcher as an always-running Scheduled Task.

.DESCRIPTION
    Default (NO admin required): a task that starts at logon, ALSO retries every
    -RepeatMinutes, runs continuously in your user session, and restarts itself if it ever
    dies. This is the right scope for watching a Downloads folder -- Chrome only downloads
    while you are logged in.

    WHY THE REPEATING TRIGGER (v1.3.0): a logon-only trigger means any mid-session death is
    permanent until the next sign-in. On 2026-08-14 the watcher was killed by an external
    console-close (exit 0xC000013A) and stayed dead for three days across no reboot, silently
    missing a download. Task Scheduler's RestartOnFailure did NOT cover it -- Windows recorded
    the task as *completed with an error code*, not *failed to start*. The repeating trigger
    is the actual fix: a dead watcher revives itself within one interval. Redundant starts are
    free -- the script's per-folder mutex makes a second instance exit 0 immediately.

    -AtBoot (REQUIRES an elevated shell): adds an AtStartup trigger and runs the task as
    SYSTEM. Read the guard below before using it -- SYSTEM expands %USERPROFILE% to the
    service profile, so a config using %USERPROFILE% would silently watch the WRONG folder.

.PARAMETER Restart
    Re-register and restart the task (use after editing config.json).

.PARAMETER RepeatMinutes
    How often the task re-triggers as a self-heal. Default 15. Set 0 to disable (logon only --
    NOT recommended; that is the exact configuration that failed on 2026-08-14).

.PARAMETER AtBoot
    Also trigger at system startup, running as SYSTEM whether logged on or not. Needs elevation.

.EXAMPLE
    .\install.ps1
    .\install.ps1 -Restart
    .\install.ps1 -RepeatMinutes 30
    .\install.ps1 -AtBoot        # from an elevated PowerShell; absolute paths in config required
#>
[CmdletBinding()]
param(
    [switch]$Restart,
    [ValidateRange(0,1440)][int]$RepeatMinutes = 15,
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

# -AtBoot runs the task as SYSTEM, and there is only ONE task -- so the logon trigger would run
# as SYSTEM too. Under SYSTEM, %USERPROFILE% expands to
# C:\Windows\system32\config\systemprofile, i.e. the watcher would sit watching an empty folder
# that no browser ever writes to and report itself perfectly healthy while catching nothing.
# Refuse rather than install a watcher that silently does nothing.
if ($AtBoot -and (Test-Path $ConfigPath)) {
    $raw = Get-Content $ConfigPath -Raw
    $cfg = $raw | ConvertFrom-Json
    $bad = @()
    foreach ($k in 'WatchFolder','ExtractTo') {
        if ($cfg.PSObject.Properties.Name -contains $k -and "$($cfg.$k)" -match '%\w+%') {
            $bad += "$k = $($cfg.$k)"
        }
    }
    if ($bad.Count -gt 0) {
        throw ("-AtBoot runs as SYSTEM, where %USERPROFILE% resolves to the service profile -- " +
               "the watcher would silently watch the wrong folder. Make these absolute in config.json first:`n  " +
               ($bad -join "`n  "))
    }
}

Write-Host "Installing scheduled task '$TaskName'..." -ForegroundColor Cyan
Write-Host "  script : $Script"
Write-Host "  config : $ConfigPath"

# -WindowStyle Hidden keeps it out of the way; -ExecutionPolicy Bypass avoids policy surprises.
$psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$args   = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -ConfigPath "{1}"' -f $Script, $ConfigPath
$action = New-ScheduledTaskAction -Execute $psExe -Argument $args -WorkingDirectory $Root

$triggers = @( New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME" )

# Self-heal trigger. A daily trigger carrying a repetition is the form that survives
# Register-ScheduledTask round-tripping on PS 5.1; building repetition directly onto a -Once
# trigger is the variant that intermittently comes back empty, so we lift .Repetition off a
# throwaway -Once trigger and graft it onto the daily one.
if ($RepeatMinutes -gt 0) {
    try {
        $selfHeal = New-ScheduledTaskTrigger -Daily -At ([datetime]::Today)
        $selfHeal.Repetition = (New-ScheduledTaskTrigger -Once -At ([datetime]::Today) `
                                  -RepetitionInterval (New-TimeSpan -Minutes $RepeatMinutes) `
                                  -RepetitionDuration (New-TimeSpan -Days 1)).Repetition
        $triggers += $selfHeal
        Write-Host ("  self-heal: re-trigger every {0} min" -f $RepeatMinutes) -ForegroundColor Cyan
    } catch {
        Write-Warning ("Could not build the {0}-minute self-heal trigger: {1}" -f $RepeatMinutes, $_.Exception.Message)
        Write-Warning "Installing with the logon trigger ONLY -- a mid-session death will not self-recover."
    }
}

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

# Verify the self-heal repetition actually round-tripped into the registered task. It is the
# one setting that silently comes back empty, and it is the whole reason for v1.3.0 -- so
# assert it rather than trusting that the install "looked fine".
if ($RepeatMinutes -gt 0) {
    $rep = $t.Triggers | Where-Object { $_.Repetition -and $_.Repetition.Interval } | Select-Object -First 1
    if ($rep) {
        Write-Host ("  Self-heal  : {0} (duration {1})" -f $rep.Repetition.Interval, $rep.Repetition.Duration) -ForegroundColor Green
    } else {
        Write-Warning "SELF-HEAL DID NOT REGISTER - the task has no repetition interval. A mid-session death will NOT self-recover."
    }
}
Write-Host ""
Write-Host "Logs: $([Environment]::ExpandEnvironmentVariables('%LOCALAPPDATA%\FilesZipWatcher\logs'))"
Write-Host "Stop/remove with: .\uninstall.ps1"
