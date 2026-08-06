<#
.SYNOPSIS
    Watches the Downloads folder for `files.zip` (Claude "Download All"), timestamps it, and
    extracts it flat into Downloads.

.DESCRIPTION
    Long-running watcher. For every completed download named `files.zip` (or Chrome's dedupe
    variants `files (1).zip`, `files (2).zip`, ...):

        1. Waits until the download is genuinely finished (see Test-DownloadComplete).
        2. Renames it to  files-<timestamp>.zip   (default: files-2026-08-05-18-42.zip)
        3. Extracts the archive contents into the watch folder itself -- NOT into a subfolder.
        4. Overwrites any colliding files.
        5. Keeps the renamed .zip (configurable).

    Everything else in the folder is ignored.

.PARAMETER ConfigPath
    Path to config.json. Defaults to ..\config.json relative to this script.

.PARAMETER Once
    Process anything already sitting in the watch folder, then exit. Used by tests and for
    manual catch-up runs. Without it, the script runs forever.

.NOTES
    Repo    : https://github.com/Mr-Champagne-TCM/files-zip-watcher
    Requires: Windows PowerShell 5.1+ (no external modules)
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Once
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression.FileSystem

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

function Get-WatcherConfig {
    param([string]$Path)

    $defaults = [ordered]@{
        WatchFolder     = (Join-Path $env:USERPROFILE 'Downloads')
        ExtractTo       = (Join-Path $env:USERPROFILE 'Downloads')
        # Matches files.zip and Chrome's dedupe variants: "files (1).zip"
        MatchPattern    = '^files(?: \(\d+\))?\.zip$'
        # NOTE: yyyy-MM-dd-HH-mm. The original request said YYYY-DD-HH-MM (no month),
        # which collides across months -- see README "Timestamp format".
        TimestampFormat = 'yyyy-MM-dd-HH-mm'
        RenamePrefix    = 'files-'
        KeepZipAfterExtract = $true
        Overwrite       = $true
        StableSeconds   = 2      # size must hold steady this long
        StableChecks    = 3      # ...across this many consecutive samples
        PollSeconds     = 5      # safety-net sweep interval
        SettleTimeoutSeconds = 900   # give up waiting on a stalled download
        LogDir          = (Join-Path $env:LOCALAPPDATA 'FilesZipWatcher\logs')
        LogRetentionDays = 30
    }

    if ($Path -and (Test-Path $Path)) {
        $json = Get-Content $Path -Raw | ConvertFrom-Json
        foreach ($k in @($defaults.Keys)) {
            if ($json.PSObject.Properties.Name -contains $k) {
                $v = $json.$k
                if ($null -ne $v -and "$v" -ne '') { $defaults[$k] = $v }
            }
        }
    }

    # Expand any environment variables used in path settings
    foreach ($k in 'WatchFolder','ExtractTo','LogDir') {
        $defaults[$k] = [Environment]::ExpandEnvironmentVariables([string]$defaults[$k])
    }
    return $defaults
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

$script:LogFile = $null

function Initialize-Log {
    param($Config)
    if (-not (Test-Path $Config.LogDir)) {
        New-Item -ItemType Directory -Force -Path $Config.LogDir | Out-Null
    }
    $script:LogFile = Join-Path $Config.LogDir ("watcher-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))

    # Prune old logs
    Get-ChildItem $Config.LogDir -Filter 'watcher-*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1 * [int]$Config.LogRetentionDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO'
    )
    $line = "{0} [{1,-5}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    if ($script:LogFile) {
        try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 } catch { }
    }
}

# ---------------------------------------------------------------------------
# Download-completion detection
# ---------------------------------------------------------------------------

function Test-FileLocked {
    <# Returns $true while another process (Chrome) still holds the file open. #>
    param([string]$Path)
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'None')   # exclusive
        $fs.Close(); $fs.Dispose()
        return $false
    } catch { return $true }
}

function Test-ValidZip {
    param([string]$Path)
    try {
        $z = [IO.Compression.ZipFile]::OpenRead($Path)
        $null = @($z.Entries).Count      # force central-directory read
        $z.Dispose()
        return $true
    } catch { return $false }
}

function Wait-DownloadComplete {
    <#
        A download is "complete" when ALL of these hold:
          * no sibling .crdownload part file for it
          * byte size unchanged across N consecutive samples
          * the file can be opened exclusively (Chrome has released its handle)
          * it parses as a valid zip archive
        Returns $true on success, $false on timeout/abandonment.
    #>
    param([string]$Path, $Config)

    $deadline = (Get-Date).AddSeconds([int]$Config.SettleTimeoutSeconds)
    $lastSize = -1
    $stable   = 0

    while ((Get-Date) -lt $deadline) {
        if (-not (Test-Path $Path)) {
            Write-Log "Vanished before completion (user moved/deleted?): $Path" 'WARN'
            return $false
        }

        # Chrome's in-progress part file sits next to the target.
        $part = "$Path.crdownload"
        if (Test-Path $part) { $stable = 0; Start-Sleep -Seconds ([int]$Config.StableSeconds); continue }

        try { $size = (Get-Item $Path -Force).Length } catch { Start-Sleep -Seconds 1; continue }

        if ($size -eq $lastSize -and $size -gt 0) { $stable++ } else { $stable = 0; $lastSize = $size }

        if ($stable -ge [int]$Config.StableChecks) {
            if (Test-FileLocked $Path) { $stable = 0 }
            elseif (Test-ValidZip $Path) { return $true }
            else { $stable = 0 }   # size settled but not a readable zip yet
        }
        Start-Sleep -Seconds ([int]$Config.StableSeconds)
    }

    Write-Log "Timed out after $($Config.SettleTimeoutSeconds)s waiting for: $Path" 'ERROR'
    return $false
}

# ---------------------------------------------------------------------------
# Rename + extract
# ---------------------------------------------------------------------------

function Get-TimestampedName {
    <# files-<stamp>.zip, with -1/-2 suffixes if that name is already taken. #>
    param([string]$Folder, $Config)

    $stamp = Get-Date -Format $Config.TimestampFormat
    $base  = "{0}{1}" -f $Config.RenamePrefix, $stamp
    $candidate = Join-Path $Folder "$base.zip"
    $n = 1
    while (Test-Path $candidate) {
        $candidate = Join-Path $Folder ("{0}-{1}.zip" -f $base, $n)
        $n++
    }
    return $candidate
}

function Expand-ArchiveFlat {
    <#
        Extracts into $Destination, preserving the archive's internal folder structure but
        NOT creating a wrapper folder. Overwrites collisions when configured.
        Refuses entries that would escape the destination (zip-slip protection).
    #>
    param([string]$ZipPath, [string]$Destination, $Config)

    $result = [ordered]@{ Extracted = 0; Overwritten = 0; Skipped = 0; Errors = 0 }
    $destFull = [IO.Path]::GetFullPath($Destination.TrimEnd('\') + '\')

    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $zip.Entries) {
            # Directory entries have empty Name
            if ([string]::IsNullOrEmpty($entry.Name)) { continue }

            $rel = $entry.FullName -replace '/', '\'
            if ($rel -match '^[\\/]' -or $rel -match '^[A-Za-z]:' -or $rel -split '\\' -contains '..') {
                Write-Log "  ! zip-slip entry refused: $($entry.FullName)" 'WARN'
                $result.Skipped++; continue
            }

            $target = [IO.Path]::GetFullPath((Join-Path $destFull $rel))
            if (-not $target.StartsWith($destFull, [StringComparison]::OrdinalIgnoreCase)) {
                Write-Log "  ! entry escapes destination, refused: $($entry.FullName)" 'WARN'
                $result.Skipped++; continue
            }

            $existed = Test-Path $target
            if ($existed -and -not $Config.Overwrite) {
                Write-Log "  - exists, overwrite disabled: $rel" 'WARN'
                $result.Skipped++; continue
            }

            $dir = Split-Path $target -Parent
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

            try {
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
                if ($existed) { $result.Overwritten++ } else { $result.Extracted++ }
            } catch {
                Write-Log "  ! extract failed for '$rel': $($_.Exception.Message)" 'ERROR'
                $result.Errors++
            }
        }
    } finally { $zip.Dispose() }

    return $result
}

function Invoke-ProcessZip {
    param([string]$Path, $Config)

    $name = Split-Path $Path -Leaf
    Write-Log "Detected: $name"

    if (-not (Wait-DownloadComplete -Path $Path -Config $Config)) { return }

    $sizeMB = [math]::Round((Get-Item $Path -Force).Length / 1MB, 2)
    Write-Log "Download complete ($sizeMB MB). Processing."

    # 1) Rename with timestamp
    $newPath = Get-TimestampedName -Folder (Split-Path $Path -Parent) -Config $Config
    try {
        Move-Item -LiteralPath $Path -Destination $newPath -Force
        Write-Log "Renamed  -> $(Split-Path $newPath -Leaf)" 'OK'
    } catch {
        Write-Log "Rename failed: $($_.Exception.Message)" 'ERROR'
        return
    }

    # 2) Extract flat into the target folder
    try {
        $r = Expand-ArchiveFlat -ZipPath $newPath -Destination $Config.ExtractTo -Config $Config
        Write-Log ("Extracted-> {0}  (new {1}, overwritten {2}, skipped {3}, errors {4})" -f `
                   $Config.ExtractTo, $r.Extracted, $r.Overwritten, $r.Skipped, $r.Errors) 'OK'
    } catch {
        Write-Log "Extract failed: $($_.Exception.Message)" 'ERROR'
        return
    }

    # 3) Optionally discard the archive
    if (-not $Config.KeepZipAfterExtract) {
        try { Remove-Item -LiteralPath $newPath -Force; Write-Log "Removed archive (KeepZipAfterExtract=false)" }
        catch { Write-Log "Could not remove archive: $($_.Exception.Message)" 'WARN' }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if (-not $ConfigPath) {
    $ConfigPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'config.json'
}
$Config = Get-WatcherConfig -Path $ConfigPath
Initialize-Log -Config $Config

if (-not (Test-Path $Config.WatchFolder)) {
    Write-Log "Watch folder does not exist: $($Config.WatchFolder)" 'ERROR'; exit 1
}
if (-not (Test-Path $Config.ExtractTo)) {
    New-Item -ItemType Directory -Force -Path $Config.ExtractTo | Out-Null
}

# Single-instance guard -- a second copy would double-process the same archive.
$mutex = New-Object System.Threading.Mutex($false, 'Global\FilesZipWatcher_SingleInstance')
if (-not $mutex.WaitOne(0)) {
    Write-Log 'Another instance is already running. Exiting.' 'WARN'
    exit 0
}

Write-Log ("=== FilesZipWatcher starting ===")
Write-Log ("Watch     : {0}" -f $Config.WatchFolder)
Write-Log ("Extract to: {0}" -f $Config.ExtractTo)
Write-Log ("Pattern   : {0}" -f $Config.MatchPattern)
Write-Log ("Stamp fmt : {0}  (e.g. {1})" -f $Config.TimestampFormat, (Get-Date -Format $Config.TimestampFormat))
Write-Log ("Mode      : {0}" -f $(if ($Once) { 'ONCE (sweep then exit)' } else { 'CONTINUOUS' }))

$script:InFlight = New-Object 'System.Collections.Generic.HashSet[string]'

function Invoke-Sweep {
    param($Config)
    Get-ChildItem -LiteralPath $Config.WatchFolder -Filter '*.zip' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $Config.MatchPattern } |
        ForEach-Object {
            $full = $_.FullName
            if ($script:InFlight.Contains($full)) { return }
            [void]$script:InFlight.Add($full)
            try { Invoke-ProcessZip -Path $full -Config $Config }
            catch { Write-Log "Unhandled error on '$($_.Exception.Message)'" 'ERROR' }
            finally { [void]$script:InFlight.Remove($full) }
        }
}

try {
    # Catch anything that landed while we were not running.
    Invoke-Sweep -Config $Config

    if ($Once) { Write-Log 'ONCE mode complete.'; exit 0 }

    # FileSystemWatcher gives instant reaction; the poll loop is the safety net for
    # missed/coalesced events and for files that appear during a restart.
    $fsw = New-Object IO.FileSystemWatcher $Config.WatchFolder, '*.zip'
    $fsw.IncludeSubdirectories = $false
    $fsw.NotifyFilter = [IO.NotifyFilters]::FileName -bor [IO.NotifyFilters]::LastWrite -bor [IO.NotifyFilters]::Size
    $fsw.EnableRaisingEvents = $true

    Register-ObjectEvent $fsw Created -SourceIdentifier FZW_Created | Out-Null
    Register-ObjectEvent $fsw Renamed -SourceIdentifier FZW_Renamed | Out-Null

    Write-Log 'Watching. (Ctrl+C to stop when run interactively.)' 'OK'

    while ($true) {
        # Wait for an event, but wake up regularly to run the safety-net sweep.
        $evt = Wait-Event -Timeout ([int]$Config.PollSeconds)
        if ($evt) { Remove-Event -EventIdentifier $evt.EventIdentifier -ErrorAction SilentlyContinue }
        Invoke-Sweep -Config $Config
    }
}
catch {
    Write-Log "FATAL: $($_.Exception.Message)" 'ERROR'
    exit 1
}
finally {
    Unregister-Event -SourceIdentifier FZW_Created -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier FZW_Renamed -ErrorAction SilentlyContinue
    if ($mutex) { try { $mutex.ReleaseMutex() } catch { }; $mutex.Dispose() }
    Write-Log '=== FilesZipWatcher stopped ==='
}
