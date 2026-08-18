<#
.SYNOPSIS
    Watch FilesZipWatcher live, in a window that is SAFE TO CLOSE.

.DESCRIPTION
    The installed watcher runs windowless (Task Scheduler, S4U logon) precisely so that no
    console window exists to be closed -- closing one sends CTRL_CLOSE_EVENT and kills the
    process with exit 0xC000013A, which is how the 2026-08-14 three-day outage began.

    This script gives you the live view back without that hazard:

      * If the watcher IS running (normal case) it ATTACHES to its log and streams it.
        Purely a reader -- no mutex, no file locks, no writes. Close it whenever you like;
        the watcher neither notices nor cares.

      * If the watcher is NOT running, it runs one in the foreground with visible output so
        you can watch a full cycle. Closing that window stops only that instance, and the
        scheduled task's self-heal trigger restores the background watcher within 15 minutes.

    Either way, closing this window cannot leave you without a watcher.

.EXAMPLE
    .\watch-live.ps1
#>
[CmdletBinding()]
param(
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

$Root   = $PSScriptRoot
$Script = Join-Path $Root 'src\FilesZipWatcher.ps1'
if (-not $ConfigPath) { $ConfigPath = Join-Path $Root 'config.json' }

if (-not (Test-Path $Script))     { throw "Watcher script not found: $Script" }
if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }

& $Script -ConfigPath $ConfigPath -Live
