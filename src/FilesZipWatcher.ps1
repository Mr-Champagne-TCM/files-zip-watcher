<#
.SYNOPSIS
    Watches the Downloads folder for `files.zip` (Claude "Download All"), timestamps it, and
    extracts it flat into Downloads.

.DESCRIPTION
    Long-running, low-power watcher. For a completed download named exactly `files.zip`:

        1. Waits until the download is genuinely finished (see Wait-DownloadComplete).
        2. Renames it to  files-<timestamp>.zip   (default: files-2026-08-05-19-32.zip)
        3. Extracts the archive contents into the watch folder itself -- NOT into a subfolder.
        4. Overwrites any colliding files.
        5. Keeps the renamed .zip (configurable).

    Everything else in the folder is ignored.

    LOW-POWER DESIGN: detection is event-driven (FileSystemWatcher filtered to the single
    filename). The safety-net sweep is an O(1) Test-Path on one known path -- it never
    enumerates the directory -- and runs infrequently (default every 5 minutes). Idle CPU is
    effectively zero and the working set is trimmed after every wake.

.PARAMETER ConfigPath
    Path to config.json. Defaults to ..\config.json relative to this script.

.PARAMETER Once
    Process anything already present, then exit. Used by tests and manual catch-up runs.

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

# Working-set trimmer: returns pages to the OS after each wake so an idle watcher
# holds ~10-15 MB instead of the ~60 MB PowerShell startup footprint.
if (-not ('FZW.Native' -as [type])) {
    Add-Type -Namespace FZW -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("psapi.dll")]
public static extern bool EmptyWorkingSet(System.IntPtr hProcess);
'@
}
function Compress-Footprint {
    try {
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        [void][FZW.Native]::EmptyWorkingSet([Diagnostics.Process]::GetCurrentProcess().Handle)
    } catch { }
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

function Get-WatcherConfig {
    param([string]$Path)

    $defaults = [ordered]@{
        WatchFolder     = (Join-Path $env:USERPROFILE 'Downloads')
        ExtractTo       = (Join-Path $env:USERPROFILE 'Downloads')
        # EXACT filename only. Chrome dedupe variants are deliberately NOT processed --
        # if the watcher is healthy the archive is renamed within seconds, so Chrome never
        # needs to create "files (1).zip". Seeing one means we were down; we warn instead.
        WatchFileName   = 'files.zip'
        OrphanWarnPattern = '^files \(\d+\)\.zip$'
        # yyyy-MM-dd-HH-mm  ->  files-2026-08-05-19-32.zip
        TimestampFormat = 'yyyy-MM-dd-HH-mm'
        RenamePrefix    = 'files-'
        KeepZipAfterExtract = $true
        Overwrite       = $true
        StableSeconds   = 2      # size must hold steady this long
        StableChecks    = 3      # ...across this many consecutive samples
        PollSeconds     = 300    # safety-net only; FileSystemWatcher does the real work
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
        $null = @($z.Entries).Count
        $z.Dispose()
        return $true
    } catch { return $false }
}

function Wait-DownloadComplete {
    <#
        Complete when ALL hold: no .crdownload sibling; byte size unchanged across N samples;
        file opens exclusively (Chrome released its handle); parses as a valid zip.
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

        if (Test-Path "$Path.crdownload") { $stable = 0; Start-Sleep -Seconds ([int]$Config.StableSeconds); continue }

        try { $size = (Get-Item $Path -Force).Length } catch { Start-Sleep -Seconds 1; continue }

        if ($size -eq $lastSize -and $size -gt 0) { $stable++ } else { $stable = 0; $lastSize = $size }

        if ($stable -ge [int]$Config.StableChecks) {
            if (Test-FileLocked $Path) { $stable = 0 }
            elseif (Test-ValidZip $Path) { return $true }
            else { $stable = 0 }
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
        Extract into $Destination preserving the archive's internal folder structure but with
        NO wrapper folder. Overwrites when configured. Refuses zip-slip entries.
    #>
    param([string]$ZipPath, [string]$Destination, $Config)

    $result = [ordered]@{ Extracted = 0; Overwritten = 0; Skipped = 0; Errors = 0 }
    $destFull = [IO.Path]::GetFullPath($Destination.TrimEnd('\') + '\')

    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $zip.Entries) {
            if ([string]::IsNullOrEmpty($entry.Name)) { continue }   # directory entry

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

    Write-Log "Detected: $(Split-Path $Path -Leaf)"

    if (-not (Wait-DownloadComplete -Path $Path -Config $Config)) { return }

    $sizeMB = [math]::Round((Get-Item $Path -Force).Length / 1MB, 2)
    Write-Log "Download complete ($sizeMB MB). Processing."

    $newPath = Get-TimestampedName -Folder (Split-Path $Path -Parent) -Config $Config
    try {
        Move-Item -LiteralPath $Path -Destination $newPath -Force
        Write-Log "Renamed  -> $(Split-Path $newPath -Leaf)" 'OK'
    } catch {
        Write-Log "Rename failed: $($_.Exception.Message)" 'ERROR'; return
    }

    try {
        $r = Expand-ArchiveFlat -ZipPath $newPath -Destination $Config.ExtractTo -Config $Config
        Write-Log ("Extracted-> {0}  (new {1}, overwritten {2}, skipped {3}, errors {4})" -f `
                   $Config.ExtractTo, $r.Extracted, $r.Overwritten, $r.Skipped, $r.Errors) 'OK'
    } catch {
        Write-Log "Extract failed: $($_.Exception.Message)" 'ERROR'; return
    }

    if (-not $Config.KeepZipAfterExtract) {
        try { Remove-Item -LiteralPath $newPath -Force; Write-Log 'Removed archive (KeepZipAfterExtract=false)' }
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

# Single-instance guard, scoped PER WATCH FOLDER.
# A global name would (and did) block the sandboxed self-test and any manual -Once catch-up
# run whenever the installed service was live. Two watchers on *different* folders are fine;
# two on the *same* folder would double-process.
$folderKey = ([Security.Cryptography.MD5]::Create().ComputeHash(
                [Text.Encoding]::UTF8.GetBytes($Config.WatchFolder.ToLowerInvariant().TrimEnd('\'))
             ) | ForEach-Object { $_.ToString('x2') }) -join ''
$mutexName = "Global\FilesZipWatcher_$($folderKey.Substring(0,16))"
try   { $mutex = New-Object System.Threading.Mutex($false, $mutexName) }
catch { $mutex = New-Object System.Threading.Mutex($false, "Local\FilesZipWatcher_$($folderKey.Substring(0,16))") }

if (-not $mutex.WaitOne(0)) {
    Write-Log "Another watcher is already running for '$($Config.WatchFolder)'. Exiting." 'WARN'
    exit 0
}

# The single path we care about. O(1) checks -- never a directory enumeration.
$script:TargetPath = Join-Path $Config.WatchFolder $Config.WatchFileName
$script:Busy = $false

Write-Log '=== FilesZipWatcher starting ==='
Write-Log ("Watching  : {0}" -f $script:TargetPath)
Write-Log ("Extract to: {0}" -f $Config.ExtractTo)
Write-Log ("Stamp fmt : {0}  (e.g. {1})" -f $Config.TimestampFormat, (Get-Date -Format $Config.TimestampFormat))
Write-Log ("Power     : event-driven; safety sweep every {0}s" -f $Config.PollSeconds)

function Invoke-Check {
    param($Config)
    if ($script:Busy) { return }
    if (-not (Test-Path -LiteralPath $script:TargetPath)) { return }
    $script:Busy = $true
    try     { Invoke-ProcessZip -Path $script:TargetPath -Config $Config }
    catch   { Write-Log "Unhandled error: $($_.Exception.Message)" 'ERROR' }
    finally { $script:Busy = $false; Compress-Footprint }
}

function Write-OrphanWarning {
    <#
        A "files (1).zip" means Chrome had to dedupe -- i.e. the watcher was NOT running when
        that download landed. We deliberately do not process it (exact-name-only policy), but
        we say so loudly instead of letting it rot unnoticed.
    #>
    param($Config)
    try {
        $orphans = Get-ChildItem -LiteralPath $Config.WatchFolder -Filter 'files (*.zip' -File -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -match $Config.OrphanWarnPattern }
        foreach ($o in $orphans) {
            Write-Log ("Orphan found (watcher was down when it arrived): '{0}'. Not processed -- exact-name policy. Rename it to '{1}' to have it handled." -f $o.Name, $Config.WatchFileName) 'WARN'
        }
    } catch { }
}

try {
    Write-OrphanWarning -Config $Config     # startup only: one directory read, then never again
    Invoke-Check -Config $Config            # catch up on anything already sitting there

    if ($Once) { Write-Log 'ONCE mode complete.'; exit 0 }

    # Filtered to the single filename -- the OS only signals us for this exact name.
    $fsw = New-Object IO.FileSystemWatcher $Config.WatchFolder, $Config.WatchFileName
    $fsw.IncludeSubdirectories = $false
    $fsw.NotifyFilter = [IO.NotifyFilters]::FileName -bor [IO.NotifyFilters]::Size
    $fsw.EnableRaisingEvents = $true

    Register-ObjectEvent $fsw Created -SourceIdentifier FZW_Created | Out-Null
    Register-ObjectEvent $fsw Renamed -SourceIdentifier FZW_Renamed | Out-Null

    Compress-Footprint
    Write-Log 'Watching. Idle until files.zip appears.' 'OK'

    while ($true) {
        # Blocks (no CPU) until an event fires or the long safety timeout elapses.
        $evt = Wait-Event -Timeout ([int]$Config.PollSeconds)
        if ($evt) { Remove-Event -EventIdentifier $evt.EventIdentifier -ErrorAction SilentlyContinue }
        Invoke-Check -Config $Config
        if (-not $evt) { Compress-Footprint }   # periodic trim on the quiet path
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
